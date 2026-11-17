"""Fetches every Mojo repository's issues and pull requests into mojo.issues.

Daily partitions from 2026-11-11, each filled at 08:00 UTC for that day
(`fire=Current`), two hours after mojo_stats so the two don't share an
hour of GitHub's rate limit. For each repository in `mojo.repos` the step
asks GitHub for what changed since the newest `updated_at` it has for it
(`GET /repos/{owner}/{repo}/issues?state=all&since=…`, which lists pull
requests too), or for everything on its first run: one request per
repository and day, more for a busy one. A day's run merges the changes
into the table and rewrites it (`replace.replace_files`): one row per issue
or pull request, as GitHub had it last.

A first run over all of them is about 1,300 requests and the long histories
(modular/modular) add pages, at most MOJO_ISSUES_MAX_PAGES (100) of 100 a
repository and run; what's left comes the next day. A rate limit is waited
out for at most MOJO_ISSUES_MAX_WAIT seconds (3900) in all.

    GITHUB_TOKEN=... ./build/mojo_issues run --partitions 2026-11-11
"""

from std.os import getenv, setenv

from morca import Cron, Ctx, Current, Daily, Day, Mapped, Pipeline, Step, morca_main
from morca.tables import ensure_table, scan, table

from cols import str_at
from issues import IssueRow, issue_rows, issues_batch, issues_of, merge_issues
from lake import ISSUES, REPOS, issues_schema
from replace import replace_files


def _repos(mut ctx: Ctx) raises -> List[String]:
    """Every repository of `mojo.repos` (at the step's pinned snapshot), once,
    sorted by name."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    var t = table(ctx, REPOS)
    for b in scan(ctx, t).select(["repo"]).to_batches():
        for r in range(b.num_rows):
            var repo = str_at(b.column(0), r)
            if repo not in seen:
                seen[repo] = True
                out.append(repo)
    sort(out)
    return out^


def fetch(mut ctx: Ctx, d: Day) raises -> Int:
    """Asks GitHub what changed in each repository's issues and pull
    requests since the newest it has, merges it into mojo.issues and
    rewrites the table. Returns the rows fetched."""
    var repos = _repos(ctx)
    var t = ensure_table(ctx, ISSUES, issues_schema())
    var max_wait = Int(getenv("MOJO_ISSUES_MAX_WAIT", "3900"))
    var max_pages = Int(getenv("MOJO_ISSUES_MAX_PAGES", "100"))

    # The current rows, and the files they are in: the commit below removes
    # every file, so the rows read must add up to what the files hold.
    var old = List[IssueRow]()
    var files = List[String]()
    var file_rows = Int64(0)
    if t.metadata.has_current_snapshot:
        for task in scan(ctx, t).plan_files():
            files.append(task.data_file.file_path)
            file_rows += task.data_file.record_count
        for b in scan(ctx, t).to_batches():
            for ref r in issue_rows(b):
                old.append(r.copy())
        if Int64(len(old)) != file_rows:
            raise Error(ISSUES, ": read ", len(old), " rows but its files hold ", file_rows)
    var newest = Dict[String, Int64]()
    for ref r in old:
        if r.updated_at > newest.get(r.repo, 0):
            newest[r.repo] = r.updated_at

    var fetched = List[IssueRow]()
    var calls = 0
    var waited = 0
    var remaining = -1
    var states = Dict[String, Int]()
    for ref repo in repos:
        var f = issues_of(repo, newest.get(repo, 0), max_wait - waited, max_pages)
        calls += f.calls
        waited += f.waited_s
        remaining = f.remaining
        states[f.state] = states.get(f.state, 0) + 1
        if f.state != "ok":
            ctx.log(String(repo, ": ", f.state))
        # `since` includes the newest row already stored: keep only newer.
        var after = newest.get(repo, 0)
        for ref r in f.rows:
            if r.updated_at > after:
                fetched.append(r.copy())
    var summary = String()
    for e in states.items():
        summary += String(" ", e.key, "=", e.value)
    ctx.log(String(
        String(d), ": ", len(repos), " repositories in ", calls, " requests (",
        waited, " s waiting on the rate limit; ", remaining, " left):", summary,
        "; ", len(fetched), " issues and pull requests changed",
    ))
    if len(fetched) == 0 and t.metadata.has_current_snapshot:
        ctx.log("nothing changed; nothing to commit")
        return 0
    var before = len(old)
    var rows = merge_issues(old^, fetched)
    # One `overwrite` snapshot removing `files` and adding `rows`; safe
    # because one run writes the table at a time (max_runs 1).
    var id = replace_files(ctx, t, files, [issues_batch(rows)])
    ctx.log(String(ISSUES, " ", before, " -> ", len(rows), " rows; snapshot ", id))
    return len(fetched)


# `Mapped`: once per partition, here a `Day`. No dista task: the requests
# are made one at a time by the step itself, within GitHub's rate limit.
comptime Fetch = Step[
    "fetch",
    Day,
    Int,
    fetch,
    Mapped,
    retries=1,
    reads=[REPOS, ISSUES],
    # replaces=: a rerun rewrites the table (replace.replace_files) rather
    # than adding rows again, so `morca backfill --rerun` needs no
    # --allow-append.
    replaces=[ISSUES],
]
# A day's run fetches what changed since the last, so a missed day needs no
# catch-up.
comptime MojoIssues = Pipeline[
    "mojo_issues",
    Fetch,
    partitions=Daily["2026-11-11"],
    schedule=Cron["0 8 * * *"],
    fire=Current,
    catchup=False,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoIssues]()
