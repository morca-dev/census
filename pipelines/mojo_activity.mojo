"""Counts each Mojo repository's daily activity and releases from GH Archive,
without calling the GitHub API.

Daily from 2023-01-01 and a sensor on `gharchive.repo_hour`, `gharchive.releases`, `mojo.repos`
and `mojo.repo_stats`: each day gharchive loads starts a run for that day,
and so does each snapshot mojo_repos adds repositories in and mojo_stats's
daily one, which can name a repository's new name after a rename or a
transfer. A run's one step reads the day's
counts (`gharchive.repo_hour`, which gharchive wrote per repository, actor
and hour while it parsed the events) for every repository in `mojo.repos`, and writes `mojo.activity`
(counts per repository and day) and `mojo.releases` (published releases).
A repository renamed or transferred is counted under each of its names
(`names.mojo`), the events having the name it had that day.

**Repositories found later get their whole history.** A repository isn't
caught up until it is in `mojo.activity_repos`. A run that finds members
of `mojo.repos` that aren't also reads, for them, every other day
`gharchive.repo_hour` has (from the day each was created; a few row
groups of each hour's files, not the day's events), and records them
there; from then on every day's run includes them as members. Each day's
scan is a dista task, so a run that catches up reads its days in parallel.

**Reruns don't duplicate rows.** A run replaces, in the month partitions it
touches, the rows of the (repository, day) pairs it computed and keeps the
others (`replace.replace_files`: one overwrite snapshot a table, none for
a table whose rows came out the same). It reads only those months' files. The
pipeline runs one run at a time (`max_runs=1`), so no two runs replace the
same partition at once.

    ./build/mojo_activity run --partitions 2026-11-03
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task
from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import Table
from iceberg.values import Datum
from morca import Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, morca_main
from morca.civil import now
from morca.tables import append, ensure_table, scan, table
from parquet import RecordBatch

from activity import (
    ActivityRow,
    DayActivity,
    ReleaseRow,
    activity_batch,
    activity_rows,
    day_activity,
    encode_job,
    release_rows,
    releases_batch,
)
from cols import col, i64_at, str_at
from days import day_text, days_of, month_of
from lake import (
    ACTIVITY,
    ACTIVITY_REPOS,
    GH_RELEASES,
    RELEASES,
    REPO_HOUR,
    REPO_STATS,
    REPOS,
    activity_repos_schema,
    activity_schema,
    activity_spec,
    releases_schema,
    releases_spec,
    ts,
)
from names import NameRow, name_columns, name_rows, names_from
from replace import partition_files, read_partition_files, replace_files


# A dista `Task` runs on a worker process. `day_activity` takes a job string
# (`encode_job`: a day, the pinned snapshots, the repositories to read) and
# returns that day's counts, so the step process never holds the scanned
# rows. `Tasks[...]` lists the tasks a run's runtime is started for; the step
# gets the runtime from `ctx.runtime`.
comptime DayTask = Task[String, DayActivity, day_activity]
comptime ActivityTasks = Tasks[DayTask]


def _members(mut ctx: Ctx) raises -> Dict[String, Int64]:
    """The repositories of mojo.repos at the step's pinned snapshot, under
    each name they had (mojo.repo_stats), with the day each was created (0
    if GitHub didn't say)."""
    # `scan(ctx, ...)` is morca's pinned scan: a retry of the step sees the
    # same members even if mojo_repos has committed since.
    var out = Dict[String, Int64]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo", "created_at"]).to_batches():
        var ir = col(b, "repo")
        var ic = col(b, "created_at")
        for r in range(b.num_rows):
            var at = i64_at(b.column(ic), r)
            out[str_at(b.column(ir), r)] = at // 86_400_000_000 if at > 0 else 0
    # A renamed or transferred repository's events come under its new name
    # from then on, and before under its old ones: every name it had is a
    # member, with its rows under that name, which the console adds up
    # (#181). A name new to the members is caught up like a new repository.
    var rows = List[NameRow]()
    var stats: Optional[Table] = None
    try:
        stats = table(ctx, REPO_STATS)
    except e:
        ctx.log(String(REPO_STATS, " not read (", e, "); members by their names in ", REPOS))
    if stats and stats.value().metadata.has_current_snapshot:
        for b in scan(ctx, stats.value()).select(name_columns(stats.value())).to_batches():
            rows.extend(name_rows(b))
    if len(rows) == 0:
        return out^
    var keys = List[String]()
    for k in out.keys():
        keys.append(k)
    var names = names_from(keys, rows)
    for ref k in keys:
        var created = out[k]
        for n in names.names_of(k):
            if n not in out:
                out[n] = created
    return out^


@fieldwise_init
struct _CaughtUp(Movable):
    """What `_caught_up` read of `mojo.activity_repos`: the repositories, and
    the rows and files, for a run that adds some to write the table again
    as one file."""

    var repos: Dict[String, Bool]
    var added_at: List[Int64]
    """The rows' `added_at`, `days` and `repo`, in the order read."""
    var days: List[Int64]
    var order: List[String]
    var paths: List[String]
    var whole: Bool
    """Whether these are all the rows of `paths`, so that replacing those
    files with them (and the new ones) loses none."""


def _caught_up(t: Table) -> _CaughtUp:
    """The repositories already in `mojo.activity_repos`, which means their
    whole history has been read (see the module docstring). Unreadable or
    empty means none are: the run then catches everything up, which is safe
    since a run replaces rows rather than appending them."""
    var out = _CaughtUp(
        Dict[String, Bool](),
        List[Int64](),
        List[Int64](),
        List[String](),
        List[String](),
        True,
    )
    if not t.metadata.has_current_snapshot:
        return out^
    out.whole = False
    try:
        var tasks = t.scan().plan_files()
        var held = Int64(0)
        for ref task in tasks:
            out.paths.append(task.data_file.file_path)
            held += task.data_file.record_count
        var read = Int64(0)
        for b in t.scan().to_batches_for_tasks(tasks^):
            var ir = col(b, "repo")
            var ia = col(b, "added_at")
            var id = col(b, "days")
            for r in range(b.num_rows):
                var repo = str_at(b.column(ir), r)
                out.repos[repo] = True
                out.order.append(repo^)
                out.added_at.append(i64_at(b.column(ia), r))
                out.days.append(i64_at(b.column(id), r))
            read += Int64(b.num_rows)
        out.whole = read == held
    except:
        pass
    return out^


def _loaded_days(hours: Table, pinned: Int64) raises -> List[String]:
    """The days gharchive.repo_hour holds at the pinned snapshot, from its
    data files' day partitions, sorted.

    This used to walk the table's snapshots for their `morca.partition`,
    which expiry takes away (the table keeps a week of them); the files a
    snapshot reads are what it holds whatever history is left."""
    var seen = Dict[Int64, Bool]()
    if pinned < 0:
        return List[String]()
    for task in hours.scan().use_snapshot(pinned).plan_files():
        ref f = task.data_file
        if len(f.partition) > 0 and f.partition[0].valid:
            seen[f.partition[0].i] = True
    var days = List[Int64]()
    for e in seen.items():
        days.append(e.key)
    for i in range(1, len(days)):
        var j = i
        while j > 0 and days[j - 1] > days[j]:
            days.swap_elements(j - 1, j)
            j -= 1
    var out = List[String]()
    for d in days:
        out.append(day_text(d))
    return out^


def _months_filter(months: Dict[Int, Bool]) -> String:
    """A row filter on `day` for the months `months` (as `month_of` numbers
    them), so planning reads only those months' manifests and files."""
    var out = String('["or",["false"]')
    for e in months.items():
        out += String(',["and",[">=","day","', _month_start(e.key), '"],')
        out += String('["<","day","', _month_start(e.key + 1), '"]]')
    return out + "]"


def _month_start(m: Int) -> String:
    """The first day of month `m` (months since 1970-01), `YYYY-MM-01`."""
    var mm = m % 12 + 1
    return String(1970 + m // 12, "-", "0" if mm < 10 else "", mm, "-01")


def _ms(t0: Int) -> Int:
    """Milliseconds since `perf_counter_ns()` was `t0`."""
    return Int((perf_counter_ns() - t0) // 1_000_000)


def _pair(repo: String, day: Int64) -> String:
    """The key of a (repository, day) pair, which is the unit a run replaces."""
    return String(repo, "|", day)


def _act_key(r: ActivityRow) -> String:
    """Every value of an activity row, for comparing rows."""
    return String(
        r.repo, "|", r.day, "|", r.events, "|", r.stars, "|", r.forks, "|",
        r.releases, "|", r.issues_opened, "|", r.prs_opened, "|", r.pushes,
        "|", r.actors,
    )


def _rel_key(r: ReleaseRow) -> String:
    """Every value of a release row, for comparing rows."""
    return String(
        r.repo, "|", r.day, "|", r.tag, "|", r.name, "|", r.published_at,
        "|", r.prerelease, "|", r.actor,
    )


def _count(mut counts: Dict[String, Int], key: String):
    """Adds one row to a multiset of rows."""
    counts[key] = counts.get(key, 0) + 1


def _written(dataset: String, id: Int64) -> String:
    """`dataset`'s snapshot for the log, or that it wasn't written."""
    if id < 0:
        return String(dataset, " unchanged")
    return String(dataset, " snapshot ", id)


def _same(a: Dict[String, Int], b: Dict[String, Int]) -> Bool:
    """Whether two multisets of rows (row key to count) are equal."""
    if len(a) != len(b):
        return False
    for e in a.items():
        if b.get(e.key, -1) != e.value:
            return False
    return True


def activity(mut ctx: Ctx, d: Day) raises -> Int:
    """Computes the day's activity for every Mojo repository and catches up new
    repositories over all earlier days.
    The repositories are the members of `mojo.repos`; those not seen before
    are computed over all the other days loaded. It replaces those
    (repository, day) rows in `mojo.activity` and `mojo.releases`. Returns
    the number of activity rows computed."""
    var t0 = perf_counter_ns()
    var day = String(d)
    var members = _members(ctx)
    var hours_t = table(ctx, REPO_HOUR)
    var rels_t = table(ctx, GH_RELEASES)
    # Every task reads at these snapshots, so all the days of the run see the
    # same data, and a retry sees it again.
    var pinned = scan(ctx, hours_t).snapshot().snapshot_id
    var pinned_rels = scan(ctx, rels_t).snapshot().snapshot_id
    var act_t = ensure_table(ctx, ACTIVITY, activity_schema(), activity_spec())
    var rel_t = ensure_table(ctx, RELEASES, releases_schema(), releases_spec())
    var cau_t = ensure_table(ctx, ACTIVITY_REPOS, activity_repos_schema())
    var caught = _caught_up(cau_t)
    var setup_ms = _ms(t0)

    # Which repositories each day's task reads: every member on the run's
    # own day, and the members not caught up yet on every loaded day from
    # the day they were created. `jobs` maps a day to its repositories, so a
    # run that adds one repository reads every loaded day for it, but only
    # for it. Days before a repository's creation are skipped; a creation
    # day of 0 (GitHub didn't say) counts as before every day, so all are read.
    var jobs = Dict[String, List[String]]()
    var all = List[String]()
    for e in members.items():
        all.append(e.key)
    jobs[day] = all^
    var fresh = List[String]()
    for e in members.items():
        if e.key not in caught.repos:
            fresh.append(e.key)
    # Only a run with repositories to catch up needs the loaded days: listing
    # them plans every file of gharchive.repo_hour.
    var loaded = List[String]()
    if len(fresh) > 0:
        loaded = _loaded_days(hours_t, pinned)
        for ref ld in loaded:
            if ld == day:
                continue
            var ldd = days_of(ld)
            var want = List[String]()
            for ref r in fresh:
                if members[r] <= ldd:
                    want.append(r)
            if len(want) > 0:
                jobs[ld] = want^
        ctx.log(String(
            len(fresh), " repositories to catch up over ", len(loaded),
            " loaded days; ", len(jobs), " days to read",
        ))

    # One task a day, at most `MOJO_ACTIVITY_PARALLEL` at once: a sliding
    # window of `ObjectRef` futures (`rt.remote` starts a task, `rt.get` waits
    # for its result and `rt.release` frees it on the worker), consumed in
    # order, each consumed ref making room to start the next day. This
    # bounds how many days' results and scans are in flight.
    var t1 = perf_counter_ns()
    ref rt = ctx.runtime[ActivityTasks]()
    var window = max(1, Int(getenv("MOJO_ACTIVITY_PARALLEL", "8")))
    var order = List[String]()
    for e in jobs.items():
        order.append(e.key)
    var refs = List[ObjectRef[DayActivity]]()
    var next = 0
    while next < len(order) and next < window:
        refs.append(rt.remote[DayTask](encode_job(order[next], pinned, pinned_rels, jobs[order[next]])))
        next += 1
    var new_rows = List[ActivityRow]()
    var new_rels = List[ReleaseRow]()
    # `computed` is every (repository, day) pair this run produced rows (or
    # none) for, and `months` the month partitions they fall in; together they
    # say which existing rows are superseded.
    var computed = Dict[String, Bool]()
    var months = Dict[Int, Bool]()
    var scanned = 0
    for i in range(len(order)):
        var got = rt.get(refs[i])
        rt.release(refs[i])
        if next < len(order):
            refs.append(rt.remote[DayTask](encode_job(order[next], pinned, pinned_rels, jobs[order[next]])))
            next += 1
        var gd = days_of(order[i])
        months[month_of(gd)] = True
        for ref r in jobs[order[i]]:
            computed[_pair(r, gd)] = True
        var stars = Int64(0)
        for ref r in got.rows.items:
            stars += r.stars
            new_rows.append(r.copy())
        for ref r in got.releases.items:
            new_rels.append(r.copy())
        scanned += got.scanned
        ctx.log(String(
            order[i], ": ", got.scanned, " repo-hour rows, ", len(got.rows),
            " repositories active, ", stars, " stars, ", len(got.releases),
            " releases (", got.ms, " ms)",
        ))

    # Replace the computed pairs in the months they fall in. The tables are
    # partitioned by month, so replacing means rewriting those months' files:
    # read the existing rows, keep the ones for pairs this run did not
    # compute, and commit them together with the new rows as one `overwrite`
    # that removes the old files. A pair with no activity today has no new row
    # and its old one (if any) is dropped, which is what "recomputed" means.
    # Only those months' files are planned and read (the filter prunes the
    # other months' manifests), not the whole table.
    var t2 = perf_counter_ns()
    var in_months = _months_filter(months)
    # `old_*` and `new_*` are the computed pairs' rows before and after: a
    # table whose rows didn't change (a day computed again from the same
    # data, as in a backfill) isn't written again.
    var kept_rows = List[ActivityRow]()
    var old_act = Dict[String, Int]()
    var new_act = Dict[String, Int]()
    for ref r in new_rows:
        _count(new_act, _act_key(r))
    var read_rows = Int64(0)
    var act_files = partition_files(act_t, months, in_months)
    if act_t.metadata.has_current_snapshot:
        for b in read_partition_files(act_t, act_files, in_months):
            for ref r in activity_rows(b):
                if month_of(r.day) not in months:
                    continue
                read_rows += 1
                if _pair(r.repo, r.day) not in computed:
                    kept_rows.append(r.copy())
                else:
                    _count(old_act, _act_key(r))
    # The rows read must equal the rows in the files about to be removed;
    # otherwise the overwrite below would silently lose some.
    if read_rows != act_files.rows:
        raise Error(
            ACTIVITY, ": read ", read_rows, " rows of the months replaced, but",
            " their files hold ", act_files.rows,
        )
    var kept_rels = List[ReleaseRow]()
    var old_rel = Dict[String, Int]()
    var new_rel = Dict[String, Int]()
    for ref r in new_rels:
        _count(new_rel, _rel_key(r))
    var rel_files = partition_files(rel_t, months, in_months)
    read_rows = 0
    if rel_t.metadata.has_current_snapshot:
        for b in read_partition_files(rel_t, rel_files, in_months):
            for ref r in release_rows(b):
                if month_of(r.day) not in months:
                    continue
                read_rows += 1
                if _pair(r.repo, r.day) not in computed:
                    kept_rels.append(r.copy())
                else:
                    _count(old_rel, _rel_key(r))
    if read_rows != rel_files.rows:
        raise Error(
            RELEASES, ": read ", read_rows, " rows of the months replaced, but",
            " their files hold ", rel_files.rows,
        )
    var n_rows = len(new_rows)
    var n_rels = len(new_rels)
    for ref r in kept_rows:
        new_rows.append(r.copy())
    for ref r in kept_rels:
        new_rels.append(r.copy())
    # Two overwrite snapshots, one a table, each only if its rows changed.
    # `replace_files` returns the existing snapshot if a retry's first
    # attempt already made it.
    var t3 = perf_counter_ns()
    var id = Int64(-1)
    var rel_id = Int64(-1)
    if not _same(old_act, new_act):
        id = replace_files(ctx, act_t, act_files.paths, [activity_batch(new_rows)])
    if not _same(old_rel, new_rel):
        rel_id = replace_files(ctx, rel_t, rel_files.paths, [releases_batch(new_rels)])

    # Only after the rows are in: record the caught-up repositories, so a
    # run that failed earlier catches them up again. `days` is how many
    # loaded days were read for them. The table is written again as one file
    # with the rows it had, so the next runs read one file, not one for
    # every run that caught some up (an append if it couldn't all be read).
    if len(fresh) > 0:
        var s = activity_repos_schema()
        var c_repo = ColumnBuilder.of(s, 1)
        var c_at = ColumnBuilder.of(s, 2)
        var c_days = ColumnBuilder.of(s, 3)
        if caught.whole:
            for i in range(len(caught.order)):
                c_repo.add(Datum.string_(caught.order[i]))
                c_at.add(ts(caught.added_at[i]))
                c_days.add(Datum.long_(caught.days[i]))
        var at = now() * 1_000_000
        for ref r in fresh:
            c_repo.add(Datum.string_(r))
            c_at.add(ts(at))
            c_days.add(Datum.long_(Int64(len(loaded))))
        var rows = batch_of([c_repo^, c_at^, c_days^])
        if caught.whole:
            _ = replace_files(ctx, cau_t, caught.paths, [rows^])
        else:
            _ = append(ctx, cau_t, [rows^])
    ctx.log(String(
        day, ": ", scanned, " repo-hour rows read over ", len(order), " days; ",
        n_rows, " activity rows and ", n_rels, " releases computed (",
        len(kept_rows), " and ", len(kept_rels), " kept); ",
        _written(ACTIVITY, id), ", ", _written(RELEASES, rel_id),
    ))
    ctx.log(String(
        day, ": ", _ms(t0), " ms: ", setup_ms, " loading the tables, ",
        Int((t1 - t0) // 1_000_000) - setup_ms, " planning, ",
        Int((t2 - t1) // 1_000_000), " reading the days, ",
        Int((t3 - t2) // 1_000_000), " reading the months replaced, ",
        _ms(t3), " committing",
    ))
    return n_rows


# `Mapped` runs the step once per partition (a `Day`). `reads`/`writes` are
# enforced by `morca.tables` and drawn as lineage in the UI. All three reads
# are datasets this pipeline doesn't write, which is what makes it a sensor
# on them.
comptime Activity = Step[
    "activity",
    Day,
    Int,
    activity,
    Mapped,
    retries=1,
    reads=[REPO_HOUR, GH_RELEASES, REPOS, REPO_STATS],
    writes=[ACTIVITY, RELEASES, ACTIVITY_REPOS],
]
# `sensor=True`: the scheduler starts a run when a run of another pipeline
# commits a snapshot of any dataset the step reads and doesn't write, for the
# days that snapshot holds. `max_runs=1`: the replace above assumes a single
# writer.
comptime MojoActivity = Pipeline[
    "mojo_activity",
    Activity,
    tasks=ActivityTasks,
    partitions=Daily["2023-01-01"],
    sensor=True,
    max_runs=1,
    workers=4,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoActivity]()
