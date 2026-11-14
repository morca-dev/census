"""Polls every census repository's default branch every 20 minutes and
records new commits in mojo.live_commits, for the console's Live page.

Hourly partitions from 2026-11-11T00, one run an hour at :00
(`fills=Current`) that keeps polling until the hour ends: every
MOJO_LIVE_POLL_S seconds (1200) it asks GitHub's GraphQL API for the heads
of all of `mojo.repos` (`live.heads_query`, 100 a query, 1 rate-limit point
each), and for each repository whose head moved, its latest commits
(`live.history_query`). The commits newer than the head seen before are
appended to mojo.live_commits with the time the poll saw them, and
mojo.live_heads is rewritten with the heads. A repository seen for the
first time records its head only. A run for an hour that is over (a
backfill) polls once.

When a newer census is deployed (`morca.outdated`), the run stops between
polls and succeeds with what it recorded; the new code polls from the next
hour, and nothing is lost, as the heads are stored.

A poll that fails is logged and the next one tries again; the step has no
retries, as a retry would skip the commits its first attempt made
(`morca.tables.find_commit`) and lose those polls' rows.

    GITHUB_TOKEN=... ./build/mojo_live run --partitions 2026-11-11T07
"""

from std.os import getenv, setenv
from std.time import sleep

from morca import (
    Cron,
    Ctx,
    Current,
    Hour,
    Hourly,
    Mapped,
    Pipeline,
    Step,
    morca_main,
    outdated,
    outdated_why,
)
from morca.civil import now
from morca.tables import BatchBuilder, append, ensure_table, scan, table
from parquet import RecordBatch

from cols import col, i64_at, str_at
from fetch import github_graphql
from jscan import days_from_civil
from lake import (
    LIVE_COMMITS,
    LIVE_HEADS,
    REPOS,
    live_commits_schema,
    add_str_or_null,
    live_heads_schema,
)
from live import (
    HEADS_BATCH,
    Asked,
    ask_heads,
    LiveCommit,
    heads_query,
    history_query,
    new_since,
    parse_heads,
    parse_history,
)
from replace import replace_files


def _repos(mut ctx: Ctx) raises -> List[String]:
    var seen = Dict[String, Bool]()
    var out = List[String]()
    for b in scan(ctx, table(ctx, REPOS)).select(["repo"]).to_batches():
        for r in range(b.num_rows):
            var repo = str_at(b.column(0), r)
            if repo not in seen:
                seen[repo] = True
                out.append(repo)
    sort(out)
    return out^


def _heads(mut ctx: Ctx) raises -> Tuple[Dict[String, String], List[String]]:
    """mojo.live_heads as repo -> head, and its files (for the rewrite)."""
    var out = Dict[String, String]()
    var files = List[String]()
    var t = ensure_table(ctx, LIVE_HEADS, live_heads_schema())
    if not t.metadata.has_current_snapshot:
        return (out^, files^)
    for task in scan(ctx, t).plan_files():
        files.append(task.data_file.file_path)
    for b in scan(ctx, t).to_batches():
        var c_repo = col(b, "repo")
        var c_head = col(b, "head")
        for r in range(b.num_rows):
            out[str_at(b.column(c_repo), r)] = str_at(b.column(c_head), r)
    return (out^, files^)


def _commits_batch(rows: List[LiveCommit]) raises -> RecordBatch:
    var b = BatchBuilder(live_commits_schema())
    var cs = b.roots.copy()
    for ref c in rows:
        b.add_str(cs[0], c.repo)
        b.add_str(cs[1], c.sha)
        add_str_or_null(b, cs[2], c.subject)
        b.add_int(cs[3], c.committed_at)
        b.add_int(cs[4], c.seen_at)
    return b^.build()


def _heads_batch(heads: Dict[String, String], at: Int64) raises -> RecordBatch:
    var b = BatchBuilder(live_heads_schema())
    var cs = b.roots.copy()
    var names = List[String]()
    for e in heads.items():
        names.append(e.key)
    sort(names)
    for ref n in names:
        b.add_str(cs[0], n)
        add_str_or_null(b, cs[1], heads[n])
        b.add_int(cs[2], at)
    return b^.build()


def _graphql(body: String) raises -> Tuple[Int, String]:
    var r = github_graphql(body)
    return (r.status, r.body)


@fieldwise_init
struct Poll(Movable):
    var commits: List[LiveCommit]
    var moved: Int
    var first_seen: Int
    var cost: Int
    var remaining: Int
    var cut: Int
    """Repos whose new commits were more than a history query returns."""
    var skipped: Int
    """Repos not asked this time: their heads batch failed."""
    var error: String


def poll(repos: List[String], mut heads: Dict[String, String]) raises -> Poll:
    """One look at every repo of `repos`: updates `heads` and returns the
    commits that moved them."""
    var out = List[LiveCommit]()
    var moved = 0
    var first = 0
    var cut = 0
    var got = Asked()
    var i = 0
    while i < len(repos):
        var batch = List[String]()
        for j in range(i, min(i + HEADS_BATCH, len(repos))):
            batch.append(repos[j])
        i += HEADS_BATCH
        ask_heads[_graphql](batch, got)
    if got.skipped == len(repos):
        raise Error("GraphQL heads: every batch failed, the last: ", got.last_error)
    var cost = got.cost
    var remaining = got.remaining
    for e in got.heads.items():
        var known = heads.get(e.key, String())
        if known == e.value:
            continue
        if known.byte_length() == 0:
            first += 1
            heads[e.key] = e.value
            continue
        moved += 1
        var body: String
        try:
            var hr = github_graphql(history_query(e.key))
            if hr.status != 200:
                # Left as it was: the next poll asks again.
                continue
            body = hr.body
        except:
            continue
        var since = new_since(parse_history(e.key, body, now() * 1_000_000), known)
        if not since[1]:
            cut += 1
        for ref c in since[0]:
            out.append(c.copy())
        heads[e.key] = e.value
        cost += 1
    return Poll(out^, moved, first, cost, remaining, cut, got.skipped, got.last_error)


def live(mut ctx: Ctx, h: Hour) raises -> Int:
    """Polls until the hour `h` ends (once, for an hour that's over).
    Returns the commits recorded."""
    var every = Int64(Int(getenv("MOJO_LIVE_POLL_S", "1200")))
    var end = (Int64(days_from_civil(h.year, h.month, h.day)) * 86_400 + Int64(h.hour + 1) * 3_600)
    var repos = _repos(ctx)
    var hf = _heads(ctx)
    var heads = hf[0].copy()
    var files = hf[1].copy()
    var commits_t = ensure_table(ctx, LIVE_COMMITS, live_commits_schema())
    var heads_t = ensure_table(ctx, LIVE_HEADS, live_heads_schema())
    var total = 0
    var polls = 0
    var failed = 0
    while True:
        var started = now()
        polls += 1
        try:
            var before = len(heads)
            var p = poll(repos, heads)
            if len(p.commits) > 0:
                _ = append(ctx, commits_t, [_commits_batch(p.commits)])
                total += len(p.commits)
            if len(p.commits) > 0 or p.moved > 0 or len(heads) != before:
                _ = replace_files(ctx, heads_t, files, [_heads_batch(heads, started * 1_000_000)])
                files.clear()
                for task in scan(ctx, heads_t).plan_files():
                    files.append(task.data_file.file_path)
            ctx.log(String(
                "poll ", polls, ": ", len(repos), " repos in ", now() - started, " s, ",
                p.moved, " moved, ", p.first_seen, " seen for the first time, ",
                len(p.commits), " new commits", String(" (", p.cut, " cut)") if p.cut > 0 else String(),
                String(", ", p.skipped, " not asked (", p.error, ")") if p.skipped > 0 else String(),
                "; ", p.cost, " points, ", p.remaining, " left",
            ))
        except e:
            failed += 1
            ctx.log(String("poll ", polls, " failed: ", e))
        var next = started + every
        if next >= end:
            break
        # A deploy of a newer census: stop between polls and let the new
        # code poll the rest (morca.outdated, #406).
        if outdated():
            ctx.log(String("outdated (", outdated_why(), "): stopping after poll ", polls))
            break
        while now() < next and not outdated():
            sleep(Float64(min(Int64(5), next - now())))
        if outdated():
            ctx.log(String("outdated (", outdated_why(), "): stopping after poll ", polls))
            break
    ctx.log(String(String(h), ": ", polls, " polls (", failed, " failed), ", total, " commits"))
    if failed == polls:
        raise Error("every poll failed")
    return total


comptime Live = Step[
    "poll",
    Hour,
    Int,
    live,
    Mapped,
    retries=0,
    reads=[REPOS, LIVE_HEADS],
    writes=[LIVE_COMMITS],
    replaces=[LIVE_HEADS],
]
comptime MojoLive = Pipeline[
    "mojo_live",
    Live,
    partitions=Hourly["2026-11-11T00"],
    schedule=Cron["0 * * * *"],
    fills=Current,
    catchup=False,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoLive]()
