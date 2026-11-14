"""Clones each newly found Mojo repository and records its commits, tooling,
packaging and Mojo version changes, tags, and contributors by month (commit
authors and co-authors as hashed emails, bots left out); repositories it has
read before are skipped (mojo_retool reads them again).

Keyed by the `repo` column of `mojo.repos` (`owner/name`), 50 repositories
a run, and a sensor, so each snapshot mojo_repos commits starts runs for the
repositories it adds. The run's one step is a gather over
its keys: it sends every repository to a dista task (`read_history`: a
bare clone, one `git log` of the first-parent history and one of every
commit's authors), then appends what comes back to `mojo.commits`,
`mojo.migrations` and `mojo.contributors` as one snapshot each.

Each repository's git tags go to `mojo.tags`, with the tooling, packaging
and Mojo version at the tagged commit when it is on the first-parent
history. A repository read before tags were takes them from its rows in
`mojo.commits`, so it has the values of its first read until mojo_retool
reads it again.

A rerun doesn't duplicate rows: a repository already in `mojo.commits` gets
no commits or migrations again, one already in `mojo.tags` no tags, and one
already in `mojo.contributors` no contributors. A repository with a history
but no tags or no contributors yet (read before they were) is cloned
without file contents and only its tags and contributors read
(`read_tags_and_authors`), so
`morca backfill --rerun --allow-append mojo_history @all` (safe here, as
nothing is appended twice) fills `mojo.tags` and `mojo.contributors` for
every repository and leaves the other tables as they are.
`MOJO_HISTORY_MAX_KB` skips repositories GitHub says are bigger than that
(for local runs; modular/modular is gigabytes).
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task
from morca import Ctx, Gather, Name, Pipeline, Step, Tasks, morca_main
from morca.keyed import Keyed
from morca.tables import BatchBuilder, append, ensure_table, scan, table

from cols import col, i64_at, str_at
from contributors import AuthorMonth, contributors_batch
from history import History, TagRow, join_tags, read_history, read_tags_and_authors
from lake import (
    COMMITS,
    CONTRIBUTORS,
    MIGRATIONS,
    REPOS,
    TAGS,
    add_str_or_null,
    add_ts_or_null,
    commits_schema,
    contributors_schema,
    migrations_schema,
    tags_schema,
)


# The dista tasks of this pipeline: functions that run on a worker process.
# Both take the repository name and return a `History` (errors included, so
# a task never fails the run); `Tasks[...]` lists them for the runtime morca
# starts at the beginning of a run, which a step reaches through
# `ctx.runtime`. A worker does the clone, so the step process never holds a
# repository.
comptime ReadHistory = Task[String, History, read_history]
comptime ReadTags = Task[String, History, read_tags_and_authors]
comptime HistoryTasks = Tasks[ReadHistory, ReadTags]


def _sizes(mut ctx: Ctx) raises -> Dict[String, Int64]:
    """`size_kb` of every repository in mojo.repos, at the step's pinned
    snapshot (a declared read, so lineage runs back to gharchive.events)."""
    # `table` and `scan` (unlike a plain `t.scan()`) go through morca: the
    # scan is pinned to the snapshot the step first read, so a retry sees the
    # same repositories, and the dataset is checked against `reads=`.
    var out = Dict[String, Int64]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo", "size_kb"]).to_batches():
        var ir = col(b, "repo")
        var isz = col(b, "size_kb")
        for r in range(b.num_rows):
            out[str_at(b.column(ir), r)] = i64_at(b.column(isz), r)
    return out^


def _commits_of(
    mut ctx: Ctx, repos: List[String]
) raises -> Dict[String, Tuple[String, String, String]]:
    """sha -> (tooling, Mojo version, packaging) of the commits mojo.commits
    has for `repos`, for the tags of repositories read before tags were."""
    # Only needed when some repository has commits but no tags: the tags'
    # tooling and version are looked up by sha instead of re-reading history.
    var out = Dict[String, Tuple[String, String, String]]()
    if len(repos) == 0:
        return out^
    var want = Dict[String, Bool]()
    for r in repos:
        want[r] = True
    var t = table(ctx, COMMITS)
    if not t.metadata.has_current_snapshot:
        return out^
    # `histories` has run `ensure_table` first, so `packaging` is a column
    # (null in rows from before it).
    for b in t.scan().select(["repo", "sha", "tooling", "mojo_version", "packaging"]).to_batches():
        var ir = col(b, "repo")
        var isha = col(b, "sha")
        var it = col(b, "tooling")
        var iv = col(b, "mojo_version")
        var ip = col(b, "packaging")
        for r in range(b.num_rows):
            if str_at(b.column(ir), r) in want:
                out[str_at(b.column(isha), r)] = (
                    str_at(b.column(it), r),
                    str_at(b.column(iv), r),
                    str_at(b.column(ip), r),
                )
    return out^


def _done(mut ctx: Ctx, dataset: String = COMMITS) raises -> Dict[String, Bool]:
    """Repositories mojo.commits (or `dataset`) already has. This reads the
    table's current snapshot: it is how a rerun knows what not to write
    again, since appending a repository twice would duplicate its rows."""
    var out = Dict[String, Bool]()
    var t = table(ctx, dataset)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in t.scan().select(["repo"]).to_batches():
        for r in range(b.num_rows):
            out[str_at(b.column(0), r)] = True
    return out^


def histories(mut ctx: Ctx, keys: Seq[Name]) raises -> Int:
    """Reads the git history of up to 50 repositories and appends their new
    commits, migrations, tags and contributors.
    The repositories are the run's `keys`, and each table gets one snapshot.
    Returns the number of commits appended.

    A repository falls in one of three groups, decided by what the tables
    already hold: commits, tags and contributors (skipped); commits but no
    tags or no contributors (`tags_only`, read by the cheaper
    `read_tags_and_authors`); no commits (a full `read_history`). A
    repository that failed has no rows, so the next run over it tries it
    again."""
    var commits_t = ensure_table(ctx, COMMITS, commits_schema())
    var migrations_t = ensure_table(ctx, MIGRATIONS, migrations_schema())
    var tags_t = ensure_table(ctx, TAGS, tags_schema())
    var contributors_t = ensure_table(ctx, CONTRIBUTORS, contributors_schema())
    var sizes = _sizes(ctx)
    var done = _done(ctx)
    var tagged = _done(ctx, TAGS)
    var counted = _done(ctx, CONTRIBUTORS)
    # 0 means no limit; local runs set it to skip modular/modular.
    var max_kb = Int64(Int(getenv("MOJO_HISTORY_MAX_KB", "0")))
    ref rt = ctx.runtime[HistoryTasks]()
    # Every task is started before any result is read. Only as many clones
    # run at once as there are dista workers; the rest wait for a free
    # worker. `refs[i]` stays aligned with `names[i]`.
    var names = List[String]()
    var refs = List[ObjectRef[History]]()
    var tags_only = List[String]()
    for i in range(len(keys)):
        var repo = keys.items[i].text
        if repo in done and repo in tagged and repo in counted:
            ctx.log(String(repo, ": already in mojo.commits, mojo.tags and mojo.contributors, skipped"))
            continue
        var kb = sizes.get(repo, Int64(0))
        if max_kb > 0 and kb > max_kb:
            ctx.log(String(repo, ": ", kb, " KB is over MOJO_HISTORY_MAX_KB, skipped"))
            continue
        names.append(repo)
        if repo in done:
            tags_only.append(repo)
            refs.append(rt.remote[ReadTags](repo))
        else:
            refs.append(rt.remote[ReadHistory](repo))
    var known_commits = _commits_of(ctx, tags_only)
    # Batches for all three tables, filled as results arrive and appended
    # once below: a run is one snapshot per table, however many repositories
    # it read. (`roots` are the schema's top-level columns, in order.)
    var tb = BatchBuilder(tags_schema())
    var tc = tb.roots.copy()
    var cb = BatchBuilder(commits_schema())
    var cc = cb.roots.copy()
    var mb = BatchBuilder(migrations_schema())
    var mc = mb.roots.copy()
    var authors = List[AuthorMonth]()
    var failed = 0
    var first_error = String()
    for i in range(len(refs)):
        # `get` waits for the task; `release` frees its result on the worker.
        var h = rt.get(refs[i])
        rt.release(refs[i])
        # A repository that is gone, private or unparseable is logged and
        # left out; it doesn't fail the run (see the end of the step).
        if h.error.byte_length() > 0:
            ctx.log(String(names[i], ": ", h.error))
            if not first_error:
                first_error = String(names[i], ": ", h.error)
            failed += 1
            continue
        var tags = List[TagRow]()
        for ref t in h.tags.items:
            tags.append(t.copy())
        # A history read earlier isn't read again, so its tags have no commit
        # rows from this task to take tooling and version from: use the ones
        # already in mojo.commits.
        if names[i] in done:
            join_tags(tags, known_commits)
        if names[i] not in tagged:
            for ref t in tags:
                tb.add_str(tc[0], t.repo)
                tb.add_str(tc[1], t.tag)
                tb.add_str(tc[2], t.commit)
                tb.add_bool(tc[3], t.annotated)
                add_ts_or_null(tb, tc[4], t.tagged_at)
                add_str_or_null(tb, tc[5], t.tooling)
                add_str_or_null(tb, tc[6], t.mojo_version)
                add_str_or_null(tb, tc[7], t.packaging)
        if names[i] not in counted:
            for ref a in h.authors.items:
                authors.append(a.copy())
        if names[i] in done:
            ctx.log(String(
                names[i], ": ", len(tags), " tags, ", len(h.authors),
                " contributor-months (history already read)",
            ))
            continue
        var last_lines = Int64(0)
        if len(h.commits) > 0:
            last_lines = h.commits.items[len(h.commits) - 1].mojo_lines
        ctx.log(String(
            names[i], ": ", len(h.commits), " commits, ", len(h.migrations),
            " migrations, ", len(tags), " tags, ", len(h.authors), " contributor-months, ",
            last_lines, " lines of Mojo now",
        ))
        for ref c in h.commits.items:
            cb.add_str(cc[0], c.repo)
            cb.add_str(cc[1], c.sha)
            cb.add_int(cc[2], c.committed_at)
            cb.add_int(cc[3], c.seq)
            cb.add_int(cc[4], c.mojo_lines)
            cb.add_int(cc[5], c.mojo_files)
            cb.add_str(cc[6], c.tooling)
            add_str_or_null(cb, cc[7], c.mojo_version)
            add_str_or_null(cb, cc[8], c.version_source)
            add_str_or_null(cb, cc[9], c.packaging)
            add_str_or_null(cb, cc[10], c.subject)
            cb.add_null(cc[11])  # `changes`: mojo_retool fills it
        for ref m in h.migrations.items:
            mb.add_str(mc[0], m.repo)
            mb.add_str(mc[1], m.sha)
            mb.add_int(mc[2], m.committed_at)
            mb.add_str(mc[3], m.kind)
            add_str_or_null(mb, mc[4], m.from_value)
            add_str_or_null(mb, mc[5], m.to_value)
    # `append` is morca's: it records the step, run and attempt in the
    # snapshot's summary, and a retry that finds its own earlier commit
    # returns it instead of appending again.
    var n = cb.rows()
    if n > 0:
        _ = append(ctx, commits_t, [cb^.build()])
    if mb.rows() > 0:
        _ = append(ctx, migrations_t, [mb^.build()])
    var n_tags = tb.rows()
    if n_tags > 0:
        _ = append(ctx, tags_t, [tb^.build()])
    if len(authors) > 0:
        _ = append(ctx, contributors_t, [contributors_batch(authors)])
    ctx.log(String(
        len(refs), " repositories read (", len(tags_only), " for tags and contributors only, ",
        failed, " failed), ", n, " commits, ", n_tags, " tags, ", len(authors),
        " contributor-months",
    ))
    # Some failures are normal (a deleted repository, a clone timeout). All of
    # them is not: that points at something shared (git, the network, the
    # disk), so fail the run and let `retries` and the scheduler try again.
    if failed > 0 and failed == len(refs):
        raise Error(
            "every repository in this run failed (", failed, "); the first, ",
            first_error,
        )
    return n


# `Gather` runs the step once per run with all the run's keys as a `Seq`
# (a `Mapped` step runs once per partition). Here the keys are repository
# names, and one run reads up to `keys_per_run` of them. `reads` and `writes`
# are enforced by `morca.tables` and give the lineage the UI draws: REPOS is
# read only, which is what makes this a sensor on it.
comptime Histories = Step[
    "histories",
    Seq[Name],
    Int,
    histories,
    Gather,
    retries=1,
    reads=[REPOS],
    writes=[COMMITS, MIGRATIONS, TAGS, CONTRIBUTORS],
]
# `Keyed` partitions are names read from a column of a dataset (the distinct
# `repo` values of the current `mojo.repos`), not a calendar. `sensor=True`:
# when a run of another pipeline commits a snapshot of a dataset this one
# reads and doesn't write (mojo.repos), the scheduler starts a run over the
# keys that snapshot added. `workers=4` sizes the dista cluster a run gets on
# Kubernetes (locally morca forks `MORCA_WORKERS`); how many clones run at once
# on the Hetzner server is `DISTA_WORKER_SLOTS` in morca.toml. `max_runs` stays
# at its default of 1: one run at a time.
comptime MojoHistory = Pipeline[
    "mojo_history",
    Histories,
    tasks=HistoryTasks,
    partitions=Keyed[REPOS, "repo"],  # owner/name
    keys_per_run=50,
    sensor=True,
    workers=4,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoHistory]()
