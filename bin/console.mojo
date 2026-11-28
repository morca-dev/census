"""The console: a flare app over mojo.repos, mojo.commits, mojo.migrations,
mojo.repo_stats, mojo.activity, mojo.releases, mojo.tags, mojo.repo_versions,
mojo.repo_deps, mojo.dep_forks and mojo.dep_names.

    PORT=8080 pixi run ./build/console

Pages: `/` the overview (cards, repos per Mojo version, growth curves),
`/repos` the repos by size and age (`?sort=lines|files|stars|forks|used_by&dir=asc|desc`,
`?version=1.x`, `?active=1y`), `/search?q=` finds repos by name, GitHub topic
or description, then by meaning (the query embedded with mojo_embed's model,
which the console downloads on its first start; CONSOLE_SEMANTIC=0 turns it off), `/migrations` the migrations to each Mojo version over time,
`/how`, `/how/optimizations` and `/how/changelog` how the census is built,
`/repos/<owner>/<name>` one repo. The data pages have JSON at `/api/...`;
`/llms.txt`, `/llms-full.txt`, `/sitemap.xml` and `/robots.txt` are for
crawlers and language models (`console_ai`), and `POST /mcp` is an MCP server
over the same data for agents (`console_mcp`). The routes are in `console_routes`.

The repos and the overview are computed and kept (`Cache`), and a background
thread keeps them fresh: every `CONSOLE_REFRESH_SECONDS` (default 1800) it
looks at the tables' current snapshots and, only when one moved or the UTC day
changed, builds a new `Cache` beside the old one and swaps it in. Requests
always read the current one and never wait for a build; until the first build
finishes they get a "warming up" page (503). A new build goes in only when its
data checks pass (`checks`); else the previous one stays, the failing checks
are logged and the footer says so. `/checks` shows the last run.
The per-repo data (commits, migrations, releases, activity) and the
Migrations page are read and rendered at the same time.

The look follows mlake.dev: its warm-ash neutrals, ember accent and lake
links, on the system font stack (no external fonts or scripts).
"""

from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.time import sleep

from flare.http import HttpServer, ServerConfig
from flare.net import SocketAddr
from morca.civil import now
from threads import OpaquePtr, ThreadHandle

from checks import CheckRun, RepoFacts, Tops, page_facts, publish, run_checks, when
from days import day_text
from model import Point, read_days, read_sources
from swap import Swap, check_due, needs_build
from querymodel import QueryModel, load_model, semantic_on

from console_cache import RETRY_SECS, Cache, refresh_secs
from console_live import LiveData, live_refresher
from console_routes import console_router
from console_mcp import McpState, new_mcp_state
from mcp_events import posthog_flusher


def _check(c: Cache, t: Int64) raises -> CheckRun:
    """The data checks on a new build, from what it read: each repo's numbers
    in the tables beside the ones its page shows."""
    var cut30 = Int64(c.built_day - 30) * 86_400_000_000
    var none = List[Point]()
    var repos = List[RepoFacts]()
    for i in range(len(c.libs)):
        ref l = c.libs[i]
        var page = page_facts(none, cut30)
        if l.repo in c.details:
            page = page_facts(c.details[l.repo].pts, cut30)
        repos.append(
            RepoFacts(
                l.repo, l.commits, c.commits30[i], c.history[i], l.mojo_lines, l.stars,
                Int64(len(l.used_by)), page^,
            )
        )
    var tops = Tops()
    tops.active = c.active_repos.copy()
    tops.active_commits = c.active_commits.copy()
    tops.active_lines = c.active_lines.copy()
    tops.rising = c.rising.copy()
    tops.rising_gain = c.rising_gain.copy()
    tops.rising_forks = c.rising_forks.copy()
    tops.rising_used_by = c.rising_used_by.copy()
    tops.rising_score = c.rising_score.copy()
    tops.rising_stars = c.rising_stars.copy()
    # An owner/* row is checked by its repos.
    for ref d in c.depended:
        for m in d.members:
            tops.depended.append(c.libs[m].repo)
            tops.depended_used_by.append(Int64(len(c.libs[m].used_by)))
    return CheckRun(t, c.built_at, run_checks(c.repo_rows, repos, tops))


def _look(mut sw: Swap[Cache], mut runs: Swap[CheckRun], cur: Cache, t: Int64) raises:
    """Look at the tables' snapshots and, if one moved or the day changed,
    build a new `Cache`, check it and swap it in. Raises with the old one
    still in place; a build that fails its checks is dropped (unless there is
    no other)."""
    var src = read_sources()
    var today = Int(t // 86400)
    if not needs_build(cur.ready, cur.built_day, today, src.same_as(cur.sources)):
        return
    read_days(src, day_text(Int64(today - 1)))
    var next = Cache()
    next._build(today, src^)
    next.built_at = t
    var run = _check(next, t)
    var bad = run.failed()
    if not publish(sw, next^, runs, run^, cur.built_at if cur.ready else 0):
        print(String("console: data checks failed; still serving the build from ", when(cur.built_at), "\n", bad), end="")
    elif bad.byte_length() > 0:
        print(String("console: data checks failed on the first build; serving it anyway\n", bad), end="")


@fieldwise_init
struct Shared(ImplicitlyCopyable):
    """The addresses of what the refresher and the handlers share, which live
    as long as the process."""

    var cache: Int
    """The `Swap[Cache]`."""
    var checks: Int
    """The `Swap[CheckRun]`: the last data checks."""
    var model: Int
    """The `Swap[QueryModel]`: the search-query encoder, once loaded."""


comptime MODEL_RETRY_SECS = 3600


def _refresher(arg: OpaquePtr) -> OpaquePtr:
    """The refresher thread: the only one that reads the lake or builds a
    `Cache`, one build at a time. It uses nothing a request handler holds: each
    read opens its own catalog and S3 client, and the only thing shared with
    the handlers is the `Swap`."""
    var sh = Pointer[Shared, MutUntrackedOrigin](unsafe_from_address=Int(arg))[]
    ref sw = Pointer[Swap[Cache], MutUntrackedOrigin](unsafe_from_address=sh.cache)[]
    ref runs = Pointer[Swap[CheckRun], MutUntrackedOrigin](unsafe_from_address=sh.checks)[]
    ref models = Pointer[Swap[QueryModel], MutUntrackedOrigin](unsafe_from_address=sh.model)[]
    var interval = refresh_secs()
    var checked = Int64(0)
    var model_tried = Int64(0)
    while True:
        try:
            var t = now()
            var cur = sw.get()
            if check_due(cur[].ready, t, checked, cur[].built_day, Int(t // 86400), interval):
                checked = t
                var started = t
                try:
                    _look(sw, runs, cur[], t)
                    if not cur[].ready:
                        print("console: first build in", now() - started, "s")
                    else:
                        print("console: looked at the tables;", now() - started, "s")
                except e:
                    # Keep serving what there is; look again soon.
                    print("console: refresh failed:", e)
                    checked = t - Int64(interval) + Int64(min(interval, RETRY_SECS))
        except e:
            print("console: refresher:", e)
        # The search-query model, once there is a build to serve: it downloads
        # (once) and loads beside the pages, which search without it until then.
        try:
            var t = now()
            if (
                semantic_on() and not models.get()[].ready() and sw.get()[].ready
                and t - model_tried >= MODEL_RETRY_SECS
            ):
                model_tried = t
                models.put(load_model())
                print("console: search model loaded in", now() - t, "s")
        except e:
            print("console: search model:", e, "; searching by text only, trying again in an hour")
        sleep(1.0)


def main() raises:
    var p = unsafe_alloc[Swap[Cache]](1)
    p.unsafe_write(Swap[Cache](Cache()))
    var cache = Int(p)
    var pc = unsafe_alloc[Swap[CheckRun]](1)
    pc.unsafe_write(Swap[CheckRun](CheckRun()))
    var checks = Int(pc)
    var pm = unsafe_alloc[Swap[QueryModel]](1)
    pm.unsafe_write(Swap[QueryModel](QueryModel()))
    var model = Int(pm)
    var sh = unsafe_alloc[Shared](1)
    sh.unsafe_write(Shared(cache, checks, model))
    var refresher = ThreadHandle.spawn[_refresher](OpaquePtr(unsafe_from_address=Int(sh)))
    refresher.detach()
    # The Live page reads its own small table every minute, apart from the rest.
    var pl = unsafe_alloc[Swap[LiveData]](1)
    pl.unsafe_write(Swap[LiveData](LiveData()))
    var live = Int(pl)
    var live_thread = ThreadHandle.spawn[live_refresher](OpaquePtr(unsafe_from_address=live))
    live_thread.detach()
    # /mcp's shared state; with a PostHog key, a thread sends its events.
    var mcp = new_mcp_state(getenv("POSTHOG_KEY"))
    ref st = Pointer[McpState, MutUntrackedOrigin](unsafe_from_address=mcp)[]
    if st.events.on():
        var flusher = ThreadHandle.spawn[posthog_flusher](OpaquePtr(unsafe_from_address=Int(Pointer(to=st.events))))
        flusher.detach()
    var r = console_router(cache, checks, model, live, mcp)
    var addr = String("0.0.0.0:", getenv("PORT", "8080"))
    var server = HttpServer.bind(SocketAddr.parse(addr), ServerConfig())
    print("console on http://", addr, sep="")
    server.serve(r^)
