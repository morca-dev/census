"""The console's routes against `console_pages`: every link in /llms.txt
answers 200 through the console's own router, every route is either listed
or deliberately left out, and the text files, sitemap and meta tags are as
the pages say."""

from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from flare.http import Request, Response, Router

from checks import CheckRun
from console_ai import html_text, llms_txt
from console_cache import Cache
from console_layout import SITE_URL
from console_live import LiveData
from console_pages import api_pages, site_pages
from console_routes import console_router
from model import Library
from querymodel import QueryModel
from search import url_encode
from swap import Swap


def _unlisted() -> List[String]:
    """Routes /llms.txt doesn't list as a page or JSON endpoint."""
    return [
        "/versions",  # a redirect to /migrations
        "/search",  # the search box's page; /api/search is listed
        "/checks",  # the data checks, for the operator
        "/llms.txt",
        "/llms-full.txt",
        "/sitemap.xml",
        "/robots.txt",
    ]


def _lib(
    repo: String, description: String, topics: List[String], aliases: List[String] = List[String]()
) -> Library:
    return Library(
        repo,
        description,
        1_700_000_000_000_000,
        1_700_000_000_000_000,
        "language",
        12,
        3,
        "MIT",
        100,
        4,
        1_700_000_000_000_000,
        1_710_000_000_000_000,
        2_000,
        10,
        "pixi",
        "25.1",
        topics.copy(),
        0,
        1,
        2,
        False,
        "ok",
        "",
        "pixi.lock",
        "",
        "",
        -1,
        List[String](),
        List[String](),
        List[String](),
        List[String](),
        List[String](),
        "rattler",
        aliases[0] if len(aliases) > 0 else repo,
        aliases.copy(),
    )


def _cache() raises -> Cache:
    """A built `Cache` of two repos, enough for every page to render."""
    var c = Cache()
    c.ready = True
    c.built_day = 20_400
    c.libs.append(_lib("acme/tomlkit", "A TOML reader", ["toml", "parser"]))
    # Found as old-owner/mojo-http, which it was called before a transfer
    # and a rename (#181): the tables key it by that name.
    c.libs.append(_lib("acme/http", "HTTP for Mojo", ["web"], ["old-owner/mojo-http"]))
    c.moved["old-owner/mojo-http"] = "acme/http"
    for ref l in c.libs:
        c.lines.append(l.mojo_lines)
        c.files.append(l.mojo_files)
        c.stars.append(l.stars)
        c.forks.append(l.forks)
        c.used_by.append(0)
        c.buckets.append("25.x")
        c.families.append("25.x")
        c.est_buckets.append("25.x")
        c.est_families.append("25.x")
        c.news.append(0)
        c.active.append(True)
        c.commits30.append(1)
        c.categories.append("")
        c.history.append(Int64(l.commits))
    return c^


def _router() raises -> Router:
    var p = unsafe_alloc[Swap[Cache]](1)
    p.unsafe_write(Swap[Cache](_cache()))
    var pc = unsafe_alloc[Swap[CheckRun]](1)
    pc.unsafe_write(Swap[CheckRun](CheckRun()))
    var pm = unsafe_alloc[Swap[QueryModel]](1)
    pm.unsafe_write(Swap[QueryModel](QueryModel()))
    var pl = unsafe_alloc[Swap[LiveData]](1)
    pl.unsafe_write(Swap[LiveData](LiveData()))
    return console_router(Int(p), Int(pc), Int(pm), Int(pl))


def _get(r: Router, url: String) raises -> Response:
    return r.serve(Request("GET", url))


def _body(resp: Response) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(resp.body)))


def _links(text: String) -> List[String]:
    """The site's URLs in `text` (`](https://mojourney.dev/...)` and the
    `JSON: https://...` notes), as paths."""
    var out = List[String]()
    var at = 0
    while True:
        var k = text.find(SITE_URL, at)
        if k < 0:
            break
        var end = k + SITE_URL.byte_length()
        var b = text.as_bytes()
        while end < len(b) and b[end] != UInt8(ord(")")) and b[end] != UInt8(ord(" ")) and b[end] != UInt8(ord("\n")):
            end += 1
        var path = String(text[byte = k + SITE_URL.byte_length() : end])
        out.append(path if path.byte_length() > 0 else String("/"))
        at = end
    return out^


def _template(path: String) -> String:
    """`/repos/:owner/:name` as flare's OpenAPI template, `?q=` dropped."""
    var q = path.find("?")
    var p = String(path[byte=:q]) if q >= 0 else path
    return p.replace(":owner", "{owner}").replace(":name", "{name}")


def test_llms_links_answer_200() raises:
    var r = _router()
    var resp = _get(r, "/llms.txt")
    assert_equal(resp.status, 200)
    var text = _body(resp)
    assert_true(text.startswith("# Mojourney\n\n> "))
    var links = _links(text)
    assert_true(len(links) >= 15, String(len(links)))
    for path in links:
        var got = _get(r, path)
        assert_equal(got.status, 200, path)
    assert_true("/repos/acme/tomlkit" in links)
    assert_true("/api/repos/acme/tomlkit" in links)


def test_every_route_listed() raises:
    var r = _router()
    var apis = List[String]()
    for p in api_pages():
        apis.append(_template(p.path))
    var listed = apis.copy()
    for p in site_pages():
        listed.append(_template(p.path))
        if p.json:
            assert_true(_template(p.json) in apis, p.json)
    var unlisted = _unlisted()
    var routed = List[String]()
    for i in range(r.route_count()):
        var t = r.route_openapi_template(i)
        routed.append(t)
        assert_true(t in listed or t in unlisted, String("route not in console_pages: ", t))
    for t in listed:
        assert_true(t in routed, String("listed but not routed: ", t))


def test_content_types() raises:
    var r = _router()
    var llms = _get(r, "/llms.txt")
    assert_equal(llms.headers.get("Content-Type"), "text/plain; charset=utf-8")
    assert_true("max-age" in llms.headers.get("Cache-Control"))
    var full = _get(r, "/llms-full.txt")
    assert_equal(full.status, 200)
    assert_equal(full.headers.get("Content-Type"), "text/plain; charset=utf-8")
    var map = _get(r, "/sitemap.xml")
    assert_equal(map.status, 200)
    assert_equal(map.headers.get("Content-Type"), "application/xml")
    assert_true("max-age" in map.headers.get("Cache-Control"))
    var robots = _get(r, "/robots.txt")
    assert_equal(robots.status, 200)
    assert_equal(robots.headers.get("Content-Type"), "text/plain; charset=utf-8")
    assert_true("Sitemap: https://mojourney.dev/sitemap.xml" in _body(robots))


def test_sitemap() raises:
    var r = _router()
    var s = _body(_get(r, "/sitemap.xml"))
    assert_true(s.startswith('<?xml version="1.0" encoding="UTF-8"?>'))
    assert_true("<loc>https://mojourney.dev/</loc>" in s)
    assert_true("<loc>https://mojourney.dev/how/optimizations</loc>" in s)
    assert_true("<loc>https://mojourney.dev/repos/acme/tomlkit</loc>" in s)
    assert_true("<loc>https://mojourney.dev/repos/acme/http</loc>" in s)
    assert_false(":owner" in s)
    # Every <loc> answers 200.
    var at = 0
    while True:
        var k = s.find("<loc>", at)
        if k < 0:
            break
        var end = s.find("</loc>", k)
        var path = String(s[byte = k + 5 + SITE_URL.byte_length() : end])
        assert_equal(_get(r, path if path else String("/")).status, 200, path)
        at = end


def test_llms_full() raises:
    var r = _router()
    var s = _body(_get(r, "/llms-full.txt"))
    assert_true("# The numbers" in s)
    assert_true("# How it works (https://mojourney.dev/how)" in s)
    assert_true("# Optimizations (https://mojourney.dev/how/optimizations)" in s)
    # The pages' text, not their markup.
    assert_false("<p" in s)
    assert_false("<script" in s)
    assert_true("Apache Iceberg" in s)


def test_meta_tags() raises:
    var r = _router()
    for p in site_pages():
        var path = p.path.replace(":owner/:name", "acme/tomlkit")
        var html = _body(_get(r, path))
        assert_true("<meta name=description content='" in html, path)
        if p.json:
            var alt = String(
                "<link rel=alternate type=application/json href='", p.json.replace(":owner/:name", "acme/tomlkit"), "'>"
            )
            assert_true(alt in html, path)
    var repo = _body(_get(r, "/repos/acme/tomlkit"))
    assert_true("content='acme/tomlkit: A TOML reader. 2,000 lines of Mojo in 10 files, Mojo 25.1" in repo)
    var search = _body(_get(r, "/search?q=toml"))
    assert_true("<link rel=alternate type=application/json href='/api/search?q=toml'>" in search)


def test_renamed_repo() raises:
    # A repo's old name redirects to its page under the current one, the
    # page says what it was called, and search finds it by either (#181).
    var r = _router()
    var page = _get(r, "/repos/old-owner/mojo-http")
    assert_equal(page.status, 301)
    assert_equal(page.headers.get("Location"), "/repos/acme/http")
    var api = _get(r, "/api/repos/Old-Owner/Mojo-HTTP")
    assert_equal(api.status, 301)
    assert_equal(api.headers.get("Location"), "/api/repos/acme/http")
    assert_equal(_get(r, "/repos/old-owner/nothing").status, 404)
    assert_true("formerly old-owner/mojo-http" in _body(_get(r, "/repos/acme/http")))
    assert_true('"aliases":["old-owner/mojo-http"]' in _body(_get(r, "/api/repos/acme/http")))
    assert_true("acme/http" in _body(_get(r, "/api/repos?q=old-owner")))
    assert_true("acme/http" in _body(_get(r, "/api/search?q=mojo-http")))
    assert_true("acme/http" in _body(_get(r, "/api/repos?q=acme/http")))


def test_api_repos_q_filters() raises:
    var r = _router()
    var all = _body(_get(r, "/api/repos"))
    assert_true("acme/tomlkit" in all and "acme/http" in all)
    var some = _body(_get(r, "/api/repos?q=toml"))
    assert_true("acme/tomlkit" in some)
    assert_false("acme/http" in some)
    assert_equal(some, _body(_get(r, "/api/search?q=toml")))
    # By topic and by description too.
    assert_true("acme/tomlkit" in _body(_get(r, "/api/repos?q=parser")))
    assert_true("acme/http" in _body(_get(r, "/api/repos?q=HTTP+for")))


def test_html_text() raises:
    var t = html_text(
        "<main><div class=wrap><h1>Title</h1><nav>tabs</nav><p>A <a href='/x'>link</a> &amp; <code>c</code>"
        "<span class=hq><button>?</button><span class=pop id=a>help</span></span>.</p>"
        "<ul><li>one</li><li>two&#8599;</li></ul><script>x()</script></div></main>"
    )
    assert_equal(t, "# Title\n\nA [link](https://mojourney.dev/x) & `c`.\n\n- one\n- two↗\n")


def test_url_encode() raises:
    assert_equal(url_encode("a b/c?&ü"), "a%20b%2Fc%3F%26%C3%BC")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
