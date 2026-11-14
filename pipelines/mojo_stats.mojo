"""Fetches every Mojo repository's stars, forks, open issues and other GitHub
numbers each day into mojo.repo_stats, and records which of the other
repositories they depend on are forks, and of what, in mojo.dep_forks.

Daily partitions from 2026-11-08, the first day it ran, each filled at
06:00 UTC for that day (`fills=Current`); GitHub only gives the current
numbers, so days before it can't be filled. The step asks GitHub
about each repository in `mojo.repos` (`GET /repos/{owner}/{repo}`, one
request each) and writes one row per repository to `mojo.repo_stats`,
`as_of` the run's day, partitioned by month. A repository that is gone,
blocked or renamed is a row with that `state`; a renamed or transferred
one's row has its new name (`renamed_to`) and every answer GitHub's id for
it (`repo_id`), from which the census learns its current name (`names.mojo`). A rate limit (403/429) is
waited out by `Retry-After` or `X-RateLimit-Reset`, for at most
`MOJO_STATS_MAX_WAIT` seconds (default 3900) in all.

Then it asks, once each, about the GitHub repositories that mojo.repo_deps
names (`dep_repo`) and mojo.repos doesn't have under any of its names, and keeps GitHub's `fork`,
`parent` and `source` for them in mojo.dep_forks, so the console can count
a project that depends on a fork of a library as one of the library's
dependents. One whose answer was an error is asked again the next day; a
rate limit leaves the rest for the next day, without waiting. This part
never fails the step.

A rerun of a day replaces that day's rows (`replace.replace_files`), so a
day has one row per repository however often it runs.

    GITHUB_TOKEN=... ./build/mojo_stats run --partitions 2026-11-05
"""

from std.os import getenv, setenv

from iceberg.batch import ColumnBuilder, NestedBuilder, batch_of, batch_of_columns
from iceberg.nested import ColumnTree
from iceberg.values import Datum
from morca import Cron, Ctx, Current, Daily, Day, Mapped, Pipeline, Step, morca_main
from morca.civil import now
from morca.tables import append, ensure_table, scan, table
from parquet import RecordBatch

from cols import bool_at, col, has_col, i32_at, i64_at, str_at, strs_at
from days import days_of, month_of
from detect import parse_fork
from fetch import Reply, github
from lake import (
    DEP_FORKS,
    REPOS,
    REPO_DEPS,
    REPO_STATS,
    date,
    dep_forks_schema,
    json_strings,
    repo_stats_schema,
    repo_stats_spec,
    str_or_null,
    ts,
    ts_or_null,
)
from names import NameRow, names_from
from replace import partition_files, replace_files
from stats import StatsRow, limited, state_of, stats_of


@fieldwise_init
struct _Stored(Copyable, Movable):
    """A row of `mojo.repo_stats` as stored: the GitHub numbers (`row`), the
    day they are for (`as_of`, days since the epoch) and when they were
    fetched (microseconds)."""

    var as_of: Int64
    var fetched_at: Int64
    var row: StatsRow


def _name_row(st: _Stored) -> NameRow:
    """What a stored row says about the repository's name."""
    return NameRow(st.row.repo, st.as_of, st.row.state, st.row.renamed_to, st.row.repo_id)


def _repos(mut ctx: Ctx) raises -> List[String]:
    """Every repository of `mojo.repos` (at the step's pinned snapshot), once,
    sorted by name so a run asks about them in a stable order."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo"]).to_batches():
        for r in range(b.num_rows):
            var repo = str_at(b.column(0), r)
            if repo not in seen:
                seen[repo] = True
                out.append(repo)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def stored_rows(b: RecordBatch) raises -> List[_Stored]:
    """The rows of a scanned `mojo.repo_stats` batch. The names are read once
    and the columns are looked up by position below, so the order of the
    list must match the constructor calls."""
    var out = List[_Stored]()
    var c = List[Int]()
    for name in [
        "repo", "as_of", "fetched_at", "state", "stars", "forks",
        "open_issues", "watchers", "topics", "archived", "pushed_at",
        "homepage", "license", "description", "size_kb", "default_branch",
        "renamed_to",
    ]:
        c.append(col(b, name))
    # `repo_id` came later (#181): a month written before reads it as 0.
    var c_id = col(b, "repo_id") if has_col(b, "repo_id") else -1
    for r in range(b.num_rows):
        out.append(
            _Stored(
                i32_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                StatsRow(
                    str_at(b.column(c[0]), r),
                    str_at(b.column(c[3]), r),
                    i64_at(b.column(c[4]), r),
                    i64_at(b.column(c[5]), r),
                    i64_at(b.column(c[6]), r),
                    i64_at(b.column(c[7]), r),
                    strs_at(b, c[8], r),
                    bool_at(b.column(c[9]), r),
                    i64_at(b.column(c[10]), r),
                    str_at(b.column(c[11]), r),
                    str_at(b.column(c[12]), r),
                    str_at(b.column(c[13]), r),
                    i64_at(b.column(c[14]), r),
                    str_at(b.column(c[15]), r),
                    str_at(b.column(c[16]), r),
                    i64_at(b.column(c_id), r) if c_id >= 0 else Int64(0),
                ),
            )
        )
    return out^


def _num(v: Int64, ok: Bool) -> Datum:
    """`v`, or null when GitHub gave no numbers for the repository (gone or
    blocked), so a missing repository isn't plotted as zero stars."""
    return Datum.long_(v) if ok else Datum.none()


def stats_batch(rows: List[_Stored]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.repo_stats`. `topics` is a list column, so
    the batch is built from column trees, with the columns in schema order
    (field ids 1-8, the topics, then 11-19; ids 9 and 10 are the topics'
    list and element)."""
    var s = repo_stats_schema()
    var cs = List[ColumnBuilder]()
    for id in [1, 2, 3, 4, 5, 6, 7, 8]:
        cs.append(ColumnBuilder.of(s, id))
    var topics = NestedBuilder.of(s, 9)
    var rest = List[ColumnBuilder]()
    for id in [11, 12, 13, 14, 15, 16, 17, 18, 19]:
        rest.append(ColumnBuilder.of(s, id))
    for ref st in rows:
        ref r = st.row
        var ok = r.has_numbers()
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(date(st.as_of))
        cs[2].add(ts(st.fetched_at))
        cs[3].add(Datum.string_(r.state))
        cs[4].add(_num(r.stars, ok))
        cs[5].add(_num(r.forks, ok))
        cs[6].add(_num(r.open_issues, ok))
        cs[7].add(_num(r.watchers, ok))
        if ok:
            topics.add(json_strings(r.topics))
            rest[0].add(Datum.bool_(r.archived))
            rest[6].add(Datum.long_(r.size_kb))
        else:
            topics.add_null()
            rest[0].add(Datum.none())
            rest[6].add(Datum.none())
        rest[1].add(ts_or_null(r.pushed_at))
        rest[2].add(str_or_null(r.homepage))
        rest[3].add(str_or_null(r.license))
        rest[4].add(str_or_null(r.description))
        rest[5].add(str_or_null(r.default_branch))
        rest[7].add(str_or_null(r.renamed_to))
        rest[8].add(Datum.long_(r.repo_id) if r.repo_id > 0 else Datum.none())
    var trees = List[ColumnTree]()
    for ref c in cs:
        trees.append(c.build_tree())
    trees.append(topics.build())
    for ref c in rest:
        trees.append(c.build_tree())
    return batch_of_columns(trees^)


@fieldwise_init
struct DepFork(Copyable, Movable):
    """A row of `mojo.dep_forks`."""

    var repo: String
    var fetched_at: Int64
    var state: String
    var fork: Bool
    var parent: String
    var source: String

    def settled(self) -> Bool:
        """Whether it needn't be asked again: GitHub answered, or said the
        repository is gone or blocked."""
        return not self.state.startswith("error")


def dep_targets(census: List[String], relations: List[String], dep_repos: List[String]) -> List[String]:
    """The `dep_repo`s of `depends` rows (`relations[i]`, `dep_repos[i]`
    of mojo.repo_deps) that aren't `census` repositories, compared without
    regard to case, each once as first written, in that order."""
    var seen = Dict[String, Bool]()
    for r in census:
        seen[r.lower()] = True
    var out = List[String]()
    for i in range(len(dep_repos)):
        if relations[i] != "depends" or dep_repos[i].byte_length() == 0:
            continue
        var low = dep_repos[i].lower()
        if low in seen:
            continue
        seen[low] = True
        out.append(dep_repos[i])
    return out^


def dep_forks_batch(rows: List[DepFork]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.dep_forks`."""
    var s = dep_forks_schema()
    var cs = List[ColumnBuilder]()
    for id in range(1, 7):
        cs.append(ColumnBuilder.of(s, id))
    for ref r in rows:
        var ok = r.state == "ok"
        cs[0].add(Datum.string_(r.repo))
        cs[1].add(ts(r.fetched_at))
        cs[2].add(Datum.string_(r.state))
        cs[3].add(Datum.bool_(r.fork) if ok else Datum.none())
        cs[4].add(str_or_null(r.parent))
        cs[5].add(str_or_null(r.source))
    return batch_of(cs)


def _dep_forks(mut ctx: Ctx, repos: List[String], fetched: Int64) raises -> Int:
    """Asks GitHub about the repositories census repositories depend on that
    aren't in the census (`repos`: every name of every census repository) and mojo.dep_forks has no answer for, and rewrites
    mojo.dep_forks with them (the table is in `replaces=`, unpartitioned, so
    the `append` replaces it). Returns how many it asked about."""
    var relations = List[String]()
    var dep_repos = List[String]()
    var deps_t = table(ctx, REPO_DEPS)
    if deps_t.metadata.has_current_snapshot:
        for b in scan(ctx, deps_t).select(["relation", "dep_repo"]).to_batches():
            for r in range(b.num_rows):
                relations.append(str_at(b.column(0), r))
                dep_repos.append(str_at(b.column(1), r))
    var targets = dep_targets(repos, relations, dep_repos)
    var t = ensure_table(ctx, DEP_FORKS, dep_forks_schema())
    var kept = List[DepFork]()
    var done = Dict[String, Bool]()
    if t.metadata.has_current_snapshot:
        for b in t.scan().to_batches():
            var c = List[Int]()
            for name in ["repo", "fetched_at", "state", "fork", "parent", "source"]:
                c.append(col(b, name))
            for r in range(b.num_rows):
                var row = DepFork(
                    str_at(b.column(c[0]), r), i64_at(b.column(c[1]), r),
                    str_at(b.column(c[2]), r), bool_at(b.column(c[3]), r),
                    str_at(b.column(c[4]), r), str_at(b.column(c[5]), r),
                )
                if row.settled():
                    done[row.repo.lower()] = True
                kept.append(row^)
    var asked = List[DepFork]()
    for ref repo in targets:
        if repo.lower() in done:
            continue
        # A network failure ends the asking for today; what was answered
        # is kept.
        var reply: Reply
        try:
            reply = github(String("/repos/", repo))
        except e:
            ctx.log(String("dep_forks: ", repo, ": ", e, "; the rest wait for tomorrow"))
            break
        if limited(reply):
            ctx.log(String("dep_forks: GitHub's rate limit after ", len(asked), "; the rest wait for tomorrow"))
            break
        if reply.status != 200:
            asked.append(DepFork(repo, fetched, state_of(reply.status), False, String(), String()))
            continue
        var f = parse_fork(reply.body)
        asked.append(DepFork(repo, fetched, "ok", f.fork, f.parent, f.source))
    if len(asked) == 0:
        return 0
    # The rows asked again replace their older ones.
    var again = Dict[String, Bool]()
    for ref a in asked:
        again[a.repo.lower()] = True
    var rows = List[DepFork]()
    for ref k in kept:
        if k.repo.lower() not in again:
            rows.append(k.copy())
    var forks = 0
    for ref a in asked:
        if a.fork:
            forks += 1
        rows.append(a.copy())
    var id = append(ctx, t, [dep_forks_batch(rows)])
    ctx.log(String(
        "dep_forks: asked about ", len(asked), " of ", len(targets),
        " repositories depended on outside the census; ", forks, " forks; snapshot ", id,
    ))
    return len(asked)


def refresh(mut ctx: Ctx, d: Day) raises -> Int:
    """Asks GitHub for every Mojo repository's current numbers and replaces the
    day's rows in mojo.repo_stats.
    The repositories are those in `mojo.repos`; the other days of the month
    are kept. Returns the number of repositories."""
    var day = String(d)
    var as_of = days_of(day)
    var repos = _repos(ctx)
    var t = ensure_table(ctx, REPO_STATS, repo_stats_schema(), repo_stats_spec())
    # The most this whole step waits on GitHub's rate limit: a window is an
    # hour, so 3900 s (65 minutes) is one window and a margin. Each repository
    # gets what is left of it (`max_wait - waited`); the step fails when a
    # wait would exceed it, rather than sleeping on indefinitely.
    var max_wait = Int(getenv("MOJO_STATS_MAX_WAIT", "3900"))
    var fetched = now() * 1_000_000
    var rows = List[_Stored]()
    var calls = 0
    var waited = 0
    var remaining = -1
    var states = Dict[String, Int]()
    for ref repo in repos:
        var a = stats_of(repo, max_wait - waited)
        calls += a.calls
        waited += a.waited_s
        remaining = a.remaining
        states[a.row.state] = states.get(a.row.state, 0) + 1
        # Every non-ok state (gone, blocked, renamed, error) is a row too, so
        # the time series records the repository's disappearance instead of
        # silently stopping.
        if a.row.state != "ok":
            ctx.log(String(repo, ": ", a.row.state, " ", a.row.renamed_to))
        rows.append(_Stored(as_of, fetched, a.row.copy()))
    var summary = String()
    for e in states.items():
        summary += String(" ", e.key, "=", e.value)
    ctx.log(String(
        day, ": ", len(repos), " repositories in ", calls, " requests (",
        waited, " s waiting on the rate limit; ", remaining, " left):", summary,
    ))

    # Replace this day's rows; keep the month's other days. The table is
    # partitioned by month of `as_of`, so a day's rows live in a file shared
    # with the month's other days: read the month, keep the rows of other
    # days, and commit them with the new rows as one `overwrite` that removes
    # the month's old files. Rerunning a day therefore gives one row per
    # repository, not two.
    var months = Dict[Int, Bool]()
    months[month_of(as_of)] = True
    var files = partition_files(t, months)
    var read_rows = Int64(0)
    var kept = 0
    # Every row's name, for the repositories' old and new names (#181).
    var named = List[NameRow]()
    for ref st in rows:
        named.append(_name_row(st))
    if t.metadata.has_current_snapshot:
        for b in t.scan().to_batches():
            for ref st in stored_rows(b):
                if st.as_of != as_of:
                    named.append(_name_row(st))
                if month_of(st.as_of) != month_of(as_of):
                    continue
                read_rows += 1
                if st.as_of != as_of:
                    rows.append(st.copy())
                    kept += 1
    # The rows read must equal the rows in the files about to be removed;
    # otherwise the overwrite below would silently lose some.
    if read_rows != files.rows:
        raise Error(
            REPO_STATS, ": read ", read_rows, " rows of the month, but its",
            " files hold ", files.rows,
        )
    var id = replace_files(ctx, t, files.paths, [stats_batch(rows)])
    ctx.log(String(len(repos), " rows as of ", day, " (", kept, " of other days kept), snapshot ", id))
    # The forks among the repositories depended on: a failure here is
    # logged, not raised, so it never costs the day's stats.
    try:
        # A dependency named by a census repository's old or new name is
        # that repository, not one to ask about.
        var names = names_from(repos, named)
        var census = List[String]()
        for e in names.all.values():
            census.extend(e.copy())
        _ = _dep_forks(ctx, census, fetched)
    except e:
        ctx.log(String("dep_forks: ", e))
    return len(repos)


# `Mapped`: the step runs once per partition of a run, here a `Day`. There is
# no dista task: the requests are made one at a time by the step itself, which
# is what keeps them within GitHub's rate limit.
comptime Refresh = Step[
    "refresh",
    Day,
    Int,
    refresh,
    Mapped,
    retries=1,
    reads=[REPOS, REPO_DEPS],
    # replaces=: a rerun rewrites these rows (replace.replace_files) rather than
    # adding them again, so `morca backfill --rerun` needs no --allow-append.
    # Under replaces=, a morca.tables `append` to them would replace whole
    # partitions, other keys' rows included: keep writing REPO_STATS through
    # replace_files. DEP_FORKS is unpartitioned and written whole, so its
    # `append` replaces the table, as meant.
    replaces=[REPO_STATS, DEP_FORKS],
]
# A `Cron` schedule fires on its own. `fills=Current` makes a fire fill the
# partition its time falls in (the day itself, not the day before, which is
# the default), and `catchup=False` starts only the latest fire if the
# scheduler was down for several: GitHub only gives the current numbers, so a
# late run can't recover a missed day's anyway.
comptime MojoStats = Pipeline[
    "mojo_stats",
    Refresh,
    partitions=Daily["2026-11-08"],
    schedule=Cron["0 6 * * *"],  # 06:00 UTC, for that day
    fills=Current,
    catchup=False,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoStats]()
