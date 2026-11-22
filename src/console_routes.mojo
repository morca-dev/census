"""The console's routes: `console_router` maps each path to its page, and
`Site` serves the pages that read the current `Cache`. bin/console.mojo
starts the threads that fill what these read."""

from flare.http import Handler, Request, Response, Router, html_escape, redirect

from checks import CheckRun, notice
from search import url_decode
from swap import Swap
from querymodel import QueryModel

from console_ai import llms_full_response, llms_response, robots, sitemap_response
from console_api import index_json, overview_json, repo_json, search_json, versions_json
from console_cache import Cache
from console_how import HowSite, changelog, optimizations
from console_layout import EDGE_CACHE, _empty, _page
from console_list import repos_page, search
from console_live import LiveSite
from console_mcp import McpSite, new_mcp_state
from console_migrations import migrations_page
from console_overview import overview
from console_repo import repo_page


def _warming_up() raises -> Response:
    var resp = _page(
        "Warming up",
        _empty("Warming up", "The census is reading the lake for the first time; this page reloads itself."),
        "",
    )
    resp.status = 503
    resp.reason = "Service Unavailable"
    resp.headers.set("Retry-After", "5")
    resp.headers.set("Refresh", "5")
    resp.headers.set("Cache-Control", "no-store")
    return resp^


@fieldwise_init
struct Site(Copyable, Handler):
    """One route of the console, with the shared `Swap` of `Cache`s."""

    var page: Int
    var cache: Int
    """The address of the `Swap[Cache]`, which lives as long as the process."""
    var checks: Int
    """The address of the `Swap[CheckRun]`."""
    var model: Int
    """The address of the `Swap[QueryModel]`."""

    def serve(self, req: Request) raises -> Response:
        ref sw = Pointer[Swap[Cache], MutUntrackedOrigin](unsafe_from_address=self.cache)[]
        ref runs = Pointer[Swap[CheckRun], MutUntrackedOrigin](unsafe_from_address=self.checks)[]
        if self.page == 10:
            return _checks_page(runs.get()[])
        # One reference for the whole request: a rebuild that finishes meanwhile
        # doesn't change what this page reads.
        var held = sw.get()
        ref c = held[]
        if not c.ready:
            return _warming_up()
        var resp = self._route(req, c)
        var note = notice(runs.get()[])
        if note.byte_length() > 0:
            resp = _with_notice(resp^, note)
        # A missing repo or a bad query isn't kept at the edge: Cloudflare would
        # otherwise hold it for its default TTL.
        resp.headers.set("Cache-Control", EDGE_CACHE if resp.status == 200 else "no-store")
        return resp^

    def _query_vector(self, req: Request, c: Cache) -> List[Float32]:
        """`?q=` embedded, when the model is loaded and is the revision the
        repos were embedded with; else empty (text search only)."""
        ref models = Pointer[Swap[QueryModel], MutUntrackedOrigin](unsafe_from_address=self.model)[]
        var held = models.get()
        if not held[].ready() or held[].rev() != c.embed_rev:
            return List[Float32]()
        try:
            var q = String(url_decode(req.query_param("q")).strip())
            if q.byte_length() == 0:
                return List[Float32]()
            return held[].embed(q)
        except e:
            print("console: search query:", e)
            return List[Float32]()

    def _route(self, req: Request, c: Cache) raises -> Response:
        if self.page == 0:
            return overview(req, c)
        if self.page == 1:
            return repos_page(req, c)
        if self.page == 2:
            return search(req, c, self._query_vector(req, c))
        if self.page == 3:
            return repo_page(req, c)
        if self.page == 4:
            return overview_json(req, c)
        if self.page == 5:
            return index_json(req, c, self._query_vector(req, c))
        if self.page == 6:
            return search_json(req, c, self._query_vector(req, c))
        if self.page == 8:
            return migrations_page(req, c)
        if self.page == 9:
            return versions_json(req, c)
        if self.page == 11:
            return llms_response(c)
        if self.page == 12:
            return llms_full_response(c)
        if self.page == 13:
            return sitemap_response(c)
        return repo_json(req, c)


def _checks_page(run: CheckRun) raises -> Response:
    """`/checks`: the last data checks, as text."""
    var resp = Response(status=200, reason="OK", body=List[UInt8](run.text().as_bytes()))
    resp.headers.set("Content-Type", "text/plain; charset=utf-8")
    # Never cached: it's where a failing check shows first.
    resp.headers.set("Cache-Control", "no-store")
    return resp^


def _with_notice(var resp: Response, note: String) -> Response:
    """`resp` with `note` atop its footer, when it is one of `_page`'s."""
    comptime FOOTER = "<footer><div class=wrap>"
    var html = String(StringSpan(unsafe_from_utf8=Span(resp.body)))
    var k = html.find(FOOTER).or_else(-1)
    if k < 0:
        return resp^
    k += FOOTER.byte_length()
    var out = String(
        html[byte=:k],
        "<p class=notice role=status>",
        html_escape(note),
        " <a href='/checks'>Details</a></p>",
        html[byte=k:],
    )
    resp.body = List[UInt8](out.as_bytes())
    return resp^


def _moved_to_migrations(req: Request) raises -> Response:
    return redirect("/migrations", 301)


def console_router(cache: Int, checks: Int, model: Int, live: Int, mcp: Int = 0) raises -> Router:
    """Every route of the console. `cache`, `checks`, `model` and `live` are
    the addresses of the `Swap[Cache]`, `Swap[CheckRun]`, `Swap[QueryModel]`
    and `Swap[LiveData]`, which outlive the router; `mcp` is the
    `console_mcp.McpState`'s (0 for a new one that sends no events).
    `console_pages` lists the same pages for /llms.txt and the sitemap;
    test_console_routes checks the two agree."""
    var r = Router()
    r.get("/", Site(0, cache, checks, model))
    r.get("/repos", Site(1, cache, checks, model))
    r.get("/migrations", Site(8, cache, checks, model))
    r.get("/versions", _moved_to_migrations)
    r.get("/live", LiveSite(live, False))
    r.get("/api/live", LiveSite(live, True))
    r.get("/how", HowSite(cache, live))
    r.get("/how/optimizations", optimizations)
    r.get("/how/changelog", changelog)
    r.get("/search", Site(2, cache, checks, model))
    r.get("/repos/:owner/:name", Site(3, cache, checks, model))
    r.get("/api/overview", Site(4, cache, checks, model))
    r.get("/api/repos", Site(5, cache, checks, model))
    r.get("/api/versions", Site(9, cache, checks, model))
    r.get("/api/search", Site(6, cache, checks, model))
    r.get("/api/repos/:owner/:name", Site(7, cache, checks, model))
    r.get("/checks", Site(10, cache, checks, model))
    r.get("/llms.txt", Site(11, cache, checks, model))
    r.get("/llms-full.txt", Site(12, cache, checks, model))
    r.get("/sitemap.xml", Site(13, cache, checks, model))
    r.get("/robots.txt", robots)
    # MCP's Streamable HTTP: POST only, so a GET gets the router's 405.
    r.post("/mcp", McpSite(cache, model, mcp if mcp != 0 else new_mcp_state(String())))
    return r^
