"""Hourly at :30, reads again the census repositories whose default branch
moved since they were last read, up to 60 a run, longest stale first, and
replaces their rows in mojo.commits, mojo.migrations, mojo.tags,
mojo.contributors, mojo.repo_versions and mojo.repo_deps, so a repository's
page follows its head without a backfill by hand.

Hourly partitions from 2026-11-27T00, one run an hour at :30
(`fire=Current`, no catch-up). The heads are mojo_live's
(`mojo.live_heads`, polled every 20 minutes); the head each repository was
last read for is its row of `mojo.refreshed`, or, for one this pipeline
hasn't read yet, its newest commit in mojo.commits and the `head_sha` of
mojo.repo_versions (`refresh.select_due` has the rules: a repository waits 6
hours after a good read, 24 for one over a gigabyte, and after a failed one
6 hours doubling up to a week; one mojo_history hasn't read is left to it,
one over `MOJO_HISTORY_MAX_KB` skipped as there). Each due repository goes to
two dista tasks, mojo_history's `read_history` (a bare clone, its whole
first-parent history, tags and contributors) and mojo_versions'
`read_head_version` (a blobless clone of HEAD), and the step replaces their
rows as mojo_retool and mojo_versions do (`rewrite`): every table read whole
and written back in one `overwrite` snapshot, so no row is duplicated. A
read that failed keeps the repository's old rows, and its row of
`mojo.refreshed` records the failure for the back-off; `mojo.refreshed` is
committed last, so a run that stops before it leaves its repositories due.

The settings, all in the environment (morca.toml's `env`), with their
defaults: MOJO_REFRESH_MAX_REPOS (60), MOJO_REFRESH_MIN_HOURS (6),
MOJO_REFRESH_BIG_KB (1000000) and MOJO_REFRESH_BIG_HOURS (24),
MOJO_REFRESH_RETRY_HOURS (6) and MOJO_REFRESH_MAX_RETRY_HOURS (168).

It shares the `mojo_repo_rows` concurrency key (morca.toml) with
mojo_history, mojo_retool and mojo_versions, which write the same tables:
one of their runs at a time, so no run reads a table between another's read
and its replace. A rerun of an hour picks the repositories due at that time
and replaces their rows again.

    ./build/mojo_refresh run --partitions 2026-11-27T10
"""

from std.os import getenv, setenv

from dista import ObjectRef, Task
from morca import (
    Cron,
    Ctx,
    Current,
    Hour,
    Hourly,
    Mapped,
    Pipeline,
    Step,
    Tasks,
    morca_main,
)
from morca.civil import now
from morca.tables import ensure_table, scan, table, table_exists

from cols import col, i64_at, str_at
from headversion import HeadVersion, read_head_version
from history import History, read_history
from lake import (
    COMMITS,
    CONTRIBUTORS,
    LIVE_HEADS,
    MIGRATIONS,
    REFRESHED,
    REPOS,
    REPO_DEPS,
    REPO_VERSIONS,
    TAGS,
    commits_schema,
    refreshed_schema,
    repo_versions_schema,
)
from refresh import Known, Policy, Refreshed, after_try, refreshed_batch, refreshed_rows, select_due
from replace import replace_files
from rewrite import rewrite_head_versions, rewrite_histories, table_files

# mojo_history's and mojo_versions' dista tasks: each clones one repository
# on a worker and returns what it read, with `error` set rather than raising.
comptime ReadHistory = Task[String, History, read_history]
comptime ReadHead = Task[String, HeadVersion, read_head_version]
comptime RefreshTasks = Tasks[ReadHistory, ReadHead]


def _sizes(mut ctx: Ctx) raises -> Tuple[List[String], Dict[String, Int64]]:
    """The repositories of mojo.repos, and their `size_kb`."""
    var repos = List[String]()
    var sizes = Dict[String, Int64]()
    for b in scan(ctx, table(ctx, REPOS)).select(["repo", "size_kb"]).to_batches():
        var ir = col(b, "repo")
        var isz = col(b, "size_kb")
        for r in range(b.num_rows):
            var repo = str_at(b.column(ir), r)
            if repo not in sizes:
                repos.append(repo)
            sizes[repo] = i64_at(b.column(isz), r)
    return (repos^, sizes^)


def _heads(mut ctx: Ctx) raises -> Dict[String, String]:
    """mojo.live_heads as repo -> head (none before mojo_live's first poll)."""
    var out = Dict[String, String]()
    if not table_exists(LIVE_HEADS):
        return out^
    var t = table(ctx, LIVE_HEADS)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in scan(ctx, t).select(["repo", "head"]).to_batches():
        var ir = col(b, "repo")
        var ih = col(b, "head")
        for r in range(b.num_rows):
            out[str_at(b.column(ir), r)] = str_at(b.column(ih), r)
    return out^


def _known(mut ctx: Ctx) raises -> Dict[String, Known]:
    """For each repository mojo.commits has: its newest commit, and the head
    its mojo.repo_versions row was read at. Both tables at their current
    snapshot (`Table.scan`), as the step writes them without declaring them
    in `reads=` (see the step)."""
    var out = Dict[String, Known]()
    var seqs = Dict[String, Int64]()
    var ct = ensure_table(ctx, COMMITS, commits_schema())
    if ct.metadata.has_current_snapshot:
        for b in ct.scan().select(["repo", "sha", "seq", "committed_at"]).to_batches():
            var ir = col(b, "repo")
            var isha = col(b, "sha")
            var iseq = col(b, "seq")
            var iat = col(b, "committed_at")
            for r in range(b.num_rows):
                var repo = str_at(b.column(ir), r)
                var seq = i64_at(b.column(iseq), r)
                if repo in seqs and seqs[repo] >= seq:
                    continue
                seqs[repo] = seq
                out[repo] = Known(str_at(b.column(isha), r), i64_at(b.column(iat), r), String())
    var vt = ensure_table(ctx, REPO_VERSIONS, repo_versions_schema())
    if vt.metadata.has_current_snapshot:
        for b in vt.scan().select(["repo", "head_sha"]).to_batches():
            var ir = col(b, "repo")
            var ih = col(b, "head_sha")
            for r in range(b.num_rows):
                var repo = str_at(b.column(ir), r)
                if repo in out:
                    out[repo].version_head = str_at(b.column(ih), r)
    return out^


def refresh(mut ctx: Ctx, h: Hour) raises -> Int:
    """Reads again the repositories due at the start of the run (at most
    MOJO_REFRESH_MAX_REPOS) and replaces their rows. Returns the number read
    without an error."""
    var policy = Policy.from_env()
    var started = now() * 1_000_000
    var rec_t = ensure_table(ctx, REFRESHED, refreshed_schema())
    var record_files = table_files(ctx, rec_t)
    var old_records = List[Refreshed]()
    var records = Dict[String, Refreshed]()
    if rec_t.metadata.has_current_snapshot:
        for b in scan(ctx, rec_t).to_batches():
            for ref r in refreshed_rows(b):
                old_records.append(r.copy())
                records[r.repo] = r.copy()
    if Int64(len(old_records)) != record_files.rows:
        raise Error(REFRESHED, ": read ", len(old_records), " rows but its files hold ", record_files.rows)
    var rs = _sizes(ctx)
    var heads = _heads(ctx)
    var known = _known(ctx)
    var sel = select_due(rs[0], rs[1], heads, records, known, started, policy)
    ctx.log(String(
        String(h), ": ", len(rs[0]), " repositories, ", len(heads), " live heads; ",
        len(sel.due), " due now, ", sel.waiting, " due for later runs, ",
        sel.current, " current, ", sel.resting, " read too recently, ",
        sel.backing_off, " backing off after failures, ", sel.unread,
        " not read by mojo_history yet, ", sel.no_head, " with no live head, ",
        sel.too_big, " over MOJO_HISTORY_MAX_KB",
    ))
    if len(sel.due) == 0:
        return 0

    # Every task is started before any result is read; only as many clones
    # run at once as there are dista workers.
    ref rt = ctx.runtime[RefreshTasks]()
    var history_refs = List[ObjectRef[History]]()
    var head_refs = List[ObjectRef[HeadVersion]]()
    for ref d in sel.due:
        history_refs.append(rt.remote[ReadHistory](d.repo))
        head_refs.append(rt.remote[ReadHead](d.repo))
    var histories = List[History]()
    var fresh = Dict[String, HeadVersion]()
    var errors = List[String]()
    var read_at = now() * 1_000_000
    for i in range(len(sel.due)):
        ref d = sel.due[i]
        var error = String()
        var hist = rt.get(history_refs[i])
        rt.release(history_refs[i])
        if hist.error.byte_length() > 0:
            error = hist.error
        elif len(hist.commits) == 0:
            error = "history: no commits"
        else:
            ctx.log(String(
                d.repo, ": ", len(hist.commits), " commits, ", len(hist.migrations),
                " migrations, ", len(hist.tags), " tags, ", len(hist.authors), " contributor-months",
            ))
            histories.append(hist^)
        var hv = rt.get(head_refs[i])
        rt.release(head_refs[i])
        if hv.error.byte_length() > 0:
            error = String(error, "; " if error else "", hv.error)
        else:
            hv.read_at = read_at
            ctx.log(String(
                d.repo, ": HEAD ", hv.head_sha, ", ", hv.version if hv.version else "no version",
                " (", hv.source if hv.source else "-", "), ", hv.declared_deps, " dependencies",
            ))
            fresh[d.repo] = hv^
        if error:
            ctx.log(String(d.repo, ": ", error, " (kept as it was)"))
        errors.append(error)

    ctx.log(rewrite_histories(ctx, histories, contributors=True, pinned=False))
    ctx.log(rewrite_head_versions(ctx, fresh, pinned=False))

    # The record last: a run that stops before it leaves these repositories
    # due, and the rewrites above give the same rows again.
    var tried = Dict[String, Bool]()
    var out = List[Refreshed]()
    var ok = 0
    for i in range(len(sel.due)):
        ref d = sel.due[i]
        tried[d.repo] = True
        var old = Optional[Refreshed]()
        if d.repo in records:
            old = records[d.repo].copy()
        out.append(after_try(old, d, read_at, errors[i]))
        if not errors[i]:
            ok += 1
    var kept = List[Refreshed]()
    for ref r in old_records:
        if r.repo not in tried:
            kept.append(r.copy())
    for ref r in out:
        kept.append(r.copy())
    var id = replace_files(ctx, rec_t, record_files.paths, [refreshed_batch(kept)])
    ctx.log(String(
        len(sel.due), " repositories read again: ", ok, " ok, ", len(sel.due) - ok,
        " failed (tried again after a back-off); ", REFRESHED, " snapshot ", id,
        "; ", (now() * 1_000_000 - started) // 1_000_000, " s",
    ))
    return ok


# `Mapped` over hours: the step runs once for the run's hour. Not a sensor:
# only the schedule starts it. `reads=` has REPOS, LIVE_HEADS and its own
# REFRESHED only. The history tables and REPO_VERSIONS / REPO_DEPS are read
# too, to keep the other repositories' rows, but at their current snapshot
# and without declaring them: mojo_retool reads and writes the history
# tables, and morca refuses to register two pipelines that both read and
# write a dataset (a cycle: "mojo_refresh writes mojo.commits, which
# mojo_retool reads; mojo_retool writes mojo.commits, which mojo_refresh
# reads"). mojo_versions, for the same reason and because it is a keyed
# sensor, no longer declares mojo.repo_versions and mojo.repo_deps either.
# mojo_history reads mojo.commits the same way. The `mojo_repo_rows`
# concurrency key, not pinning, is what keeps those reads safe.
comptime Refresh = Step[
    "refresh",
    Hour,
    Int,
    refresh,
    Mapped,
    retries=1,
    reads=[REPOS, LIVE_HEADS, REFRESHED],
    # replaces=: a rerun rewrites these rows (replace.replace_files) rather
    # than adding them again. Under replaces=, a morca.tables `append` to them
    # would replace whole partitions, other keys' rows included: keep
    # writing through replace_files.
    replaces=[REFRESHED, COMMITS, MIGRATIONS, TAGS, CONTRIBUTORS, REPO_VERSIONS, REPO_DEPS],
]
comptime MojoRefresh = Pipeline[
    "mojo_refresh",
    Refresh,
    tasks=RefreshTasks,
    partitions=Hourly["2026-11-27T00"],
    schedule=Cron["30 * * * *"],
    fire=Current,
    catchup=False,
    workers=4,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoRefresh]()
