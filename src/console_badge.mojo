"""The README badges (#241): `/badge/:owner/:name/used-by.svg` and
`/badge/:owner/:name/mojo.svg`, and the same two as shields.io endpoint JSON
(`.json`). A repo's page has the Markdown to paste (`badges_section`).

A badge is always a 200 with an image, a repo the census doesn't have
included ("not indexed"): GitHub's image proxy shows anything else as a
broken image. It also keeps what it is given, so each answer says how long
(`BADGE_CACHE`) and carries an `ETag`."""

from flare.http import Handler, Request, Response, html_escape

from model import Library
from swap import Swap
from versions import usable

from console_cache import Cache
from console_layout import SITE_URL, _n


comptime BADGE_CACHE = "public, max-age=3600, s-maxage=3600, stale-if-error=86400"
"""An hour, in the browser, at the edge and in GitHub's image proxy: the
numbers change once a day."""
comptime MISSING_CACHE = "public, max-age=300, s-maxage=300"
"""Five minutes for "not indexed", so a repo shows soon after it is found."""

comptime BRAND_COLOR = "#b45309"
comptime GREY = "#9f9f9f"
comptime LABEL_COLOR = "#555"

comptime USED_BY = 0
comptime MOJO = 1


@fieldwise_init
struct Badge(Copyable, Movable):
    """A badge's two halves and the colour of the right one."""

    var label: String
    var message: String
    var color: String
    var indexed: Bool
    """False for a repo the census doesn't have."""


def used_by_badge(l: Library) raises -> Badge:
    """`used by | 12 projects`: every census repo that depends on it,
    directly or through a fork of it, its owner's own repos included. The
    page it links to lists them and says how many are from other owners."""
    var n = len(l.used_by)
    return Badge(
        "used by",
        String(_n(Int64(n)), " project" if n == 1 else " projects"),
        BRAND_COLOR if n > 0 else GREY,
        True,
    )


def version_text(v: String) -> String:
    """A Mojo version as a badge shows it: `1.3.0.dev2026111805` is
    `1.3.0 nightly`, and anything longer than 24 characters is cut."""
    var k = v.find(".dev").or_else(-1)
    var s = String(v[byte=:k], " nightly") if k > 0 else v
    var out = String()
    var n = 0
    for cp in s.codepoint_slices():
        if n == 24:
            break
        out += cp
        n += 1
    return out^


def version_badge(l: Library) -> Badge:
    """`mojo | 1.2.0`: the version the census read; else `~1.2`, the
    estimate by date, in grey; else `unknown`."""
    if usable(l.mojo_version):
        return Badge("mojo", version_text(l.mojo_version), BRAND_COLOR, True)
    if l.version_estimate.byte_length() > 0:
        return Badge("mojo", String("~", version_text(l.version_estimate)), GREY, True)
    return Badge("mojo", "unknown", GREY, True)


def missing_badge(kind: Int) -> Badge:
    return Badge("used by" if kind == USED_BY else "mojo", "not indexed", GREY, False)


def _lower_width(i: Int) -> Int:
    """Verdana's a to z at 11px, in tenths of a pixel."""
    var w = [66, 69, 57, 69, 66, 39, 69, 70, 30, 38, 65, 30, 107, 70, 67, 69, 69, 47, 57, 43, 70, 65, 90, 65, 65, 58]
    return w[i]


def text_width(s: String) -> Int:
    """About how wide `s` is in 11px Verdana, in tenths of a pixel. The SVG
    sets `textLength` to it, so a font that differs is fitted to the box
    rather than overflowing it."""
    var w = 0
    for b in s.as_bytes():
        var c = Int(b)
        if c >= 97 and c <= 122:
            w += _lower_width(c - 97)
        elif c >= 48 and c <= 57:
            w += 70
        elif c == 32 or c == 46 or c == 44:
            w += 39
        elif c == 45 or c == 47:
            w += 50
        elif c == 126 or c == 43:
            w += 90
        elif c >= 65 and c <= 90:
            w += 75
        elif c >= 128 and c < 192:
            # A continuation byte of a character already counted.
            pass
        else:
            w += 70
    return w


def badge_svg(b: Badge) -> String:
    """The badge in shields.io's flat style, 20px high."""
    var lt = text_width(b.label)
    var mt = text_width(b.message)
    var lw = (lt + 5) // 10 + 10
    var mw = (mt + 5) // 10 + 10
    var w = lw + mw
    var label = html_escape(b.label)
    var message = html_escape(b.message)
    var lx = lw * 5
    var mx = lw * 10 + mw * 5
    return String(
        '<svg xmlns="http://www.w3.org/2000/svg" width="', w, '" height="20" role="img" aria-label="',
        label, ": ", message, '"><title>', label, ": ", message, "</title>",
        '<linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/>',
        '<stop offset="1" stop-opacity=".1"/></linearGradient>',
        '<clipPath id="r"><rect width="', w, '" height="20" rx="3" fill="#fff"/></clipPath>',
        '<g clip-path="url(#r)"><rect width="', lw, '" height="20" fill="', LABEL_COLOR, '"/>',
        '<rect x="', lw, '" width="', mw, '" height="20" fill="', b.color, '"/>',
        '<rect width="', w, '" height="20" fill="url(#s)"/></g>',
        '<g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif"',
        ' text-rendering="geometricPrecision" font-size="110">',
        '<text aria-hidden="true" x="', lx, '" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)"',
        ' textLength="', lt, '">', label, "</text>",
        '<text x="', lx, '" y="140" transform="scale(.1)" textLength="', lt, '">', label, "</text>",
        '<text aria-hidden="true" x="', mx, '" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)"',
        ' textLength="', mt, '">', message, "</text>",
        '<text x="', mx, '" y="140" transform="scale(.1)" textLength="', mt, '">', message, "</text>",
        "</g></svg>",
    )


def _json_text(s: String) -> String:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def badge_json(b: Badge) -> String:
    """The badge as shields.io's endpoint schema, for
    `https://img.shields.io/endpoint?url=...`."""
    return String(
        '{"schemaVersion":1,"label":"', _json_text(b.label), '","message":"', _json_text(b.message),
        '","color":"', String(b.color[byte=1:]), '","cacheSeconds":3600}',
    )


def etag_of(body: String) -> String:
    """A weak `ETag` of `body`: its FNV-1a hash, in hex."""
    var h = UInt64(0xCBF29CE484222325)
    for b in body.as_bytes():
        h = (h ^ UInt64(b)) * UInt64(0x100000001B3)
    comptime DIGITS = "0123456789abcdef"
    var out = String('W/"')
    for i in range(16):
        var d = Int((h >> UInt64(60 - 4 * i)) & UInt64(15))
        out += DIGITS[byte=d]
    out += '"'
    return out^


def find_repo(c: Cache, repo: String) -> Optional[Library]:
    """The repo by its name, an old name of it, or either in another case:
    a README's link is whatever its owner typed."""
    var found = c.find(repo)
    if found:
        return found^
    var moved = c.moved_to(repo)
    if moved.byte_length() > 0:
        return c.find(moved)
    var low = repo.lower()
    for ref l in c.libs:
        if l.repo.lower() == low:
            return l.copy()
    return None


def badge_of(c: Cache, repo: String, kind: Int) raises -> Badge:
    var found = find_repo(c, repo)
    if not found:
        return missing_badge(kind)
    if kind == USED_BY:
        return used_by_badge(found.value())
    return version_badge(found.value())


@fieldwise_init
struct BadgeSite(Copyable, Handler):
    """One of the four badge routes, with the shared `Swap` of `Cache`s."""

    var cache: Int
    """The address of the `Swap[Cache]`, which lives as long as the process."""
    var kind: Int
    """`USED_BY` or `MOJO`."""
    var json: Bool

    def serve(self, req: Request) raises -> Response:
        ref sw = Pointer[Swap[Cache], MutUntrackedOrigin](unsafe_from_address=self.cache)[]
        var held = sw.get()
        ref c = held[]
        if not c.ready:
            # Before the first build nothing is known; not kept anywhere.
            var cold = Response(status=503, reason="Service Unavailable", body=List[UInt8]())
            cold.headers.set("Retry-After", "5")
            cold.headers.set("Cache-Control", "no-store")
            return cold^
        var b = badge_of(c, String(req.param("owner"), "/", req.param("name")), self.kind)
        var body = badge_json(b) if self.json else badge_svg(b)
        var tag = etag_of(body)
        var same = String(req.headers.get("If-None-Match").strip()) == tag
        var resp = Response(status=200, reason="OK", body=List[UInt8](body.as_bytes()))
        if same:
            resp = Response(status=304, reason="Not Modified", body=List[UInt8]())
        else:
            resp.headers.set("Content-Type", "application/json" if self.json else "image/svg+xml; charset=utf-8")
        resp.headers.set("ETag", tag)
        resp.headers.set("Cache-Control", BADGE_CACHE if b.indexed else MISSING_CACHE)
        # shields.io fetches the JSON from a browser when a badge is previewed.
        if self.json:
            resp.headers.set("Access-Control-Allow-Origin", "*")
        return resp^


def _snippet(repo: String, file: String, alt: String, anchor: String) -> String:
    return String(
        "[![", alt, "](", SITE_URL, "/badge/", repo, "/", file, ".svg)](", SITE_URL, "/repos/", repo, anchor, ")"
    )


def badge_markdown(repo: String) -> String:
    """The two badges as Markdown, each a link to the repo's page."""
    return String(
        _snippet(repo, "used-by", "Used by", "#used-by"), "\n", _snippet(repo, "mojo", "Mojo version", ""),
    )


def badges_section(repo: String) -> String:
    """The repo page's Badges: the two badges as they look now and the
    Markdown for its README, with a button that copies it."""
    var r = html_escape(repo)
    return String(
        "<h2 id=badges>Badges</h2><div class=prose><p>",
        "<a href='/repos/", r, "#used-by'><img src='/badge/", r, "/used-by.svg' alt='Used by' height=20></a> ",
        "<img src='/badge/", r, "/mojo.svg' alt='Mojo version' height=20></p>",
        "<p>For this repo's README: how many census repos depend on it, directly or",
        " through a fork, and the Mojo version the census read. They update with the census, about an hour",
        " behind.</p><pre class=cmd><code>", html_escape(badge_markdown(repo)), "</code></pre>",
        "<p><button type=button class=copy onclick=\"navigator.clipboard.writeText(",
        "this.parentElement.previousElementSibling.textContent).then(()=>{this.textContent='Copied'})\">",
        "Copy Markdown</button></p>",
        "<p class=mute>Styled through shields.io instead: <code>https://img.shields.io/endpoint?url=", SITE_URL,
        "/badge/", r, "/used-by.json</code> (or <code>mojo.json</code>).</p></div>",
    )
