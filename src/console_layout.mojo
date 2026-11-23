"""The console's page frame and the small HTML helpers every page uses: the
stylesheet, the header and footer around a page's body (`_page`), the "?"
popovers (`_help`), empty states, number and age formatting, and topic
chips."""

from std.os import getenv

from flare.http import Response, html_escape
from morca.civil import now

from analytics import posthog_snippet
from overview import month_label, month_of_days


comptime STYLE = """
.prose{max-width:72ch}pre.cmd{margin:8px 0 16px;padding:10px 12px;background:var(--bg-alt);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text);white-space:pre-wrap;overflow-wrap:anywhere}.prose p,.prose li{line-height:1.6}.prose ul{padding-left:1.2em}.prose li{margin:6px 0}
*{box-sizing:border-box}
:root{color-scheme:light;--bg:#fbf9f7;--bg-alt:#f4f0ec;--surface:#fff;--surface-2:#f8f5f2;--border:#e3dcd4;--border-strong:#cfc5ba;--text:#17151a;--muted:#6b645d;--faint:#948c84;--ember:#c33c10;--ember-wash:#fdefe7;--lake:#0d6a70;--c0:#2b6cb0;--c1:#c33c10;--c2:#0d8a5a;--c3:#8e44ad;--c4:#a16207;--c5:#5b6770;--c6:#0e7490;--c7:#be185d;--c8:#4d7c0f;--c9:#0369a1;--shadow:0 1px 2px rgb(23 21 26 / .04),0 8px 24px -12px rgb(23 21 26 / .12);--radius:10px;--radius-sm:6px;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#0e0d11;--bg-alt:#131218;--surface:#17161d;--surface-2:#1c1b23;--border:#2a2833;--border-strong:#3d3a48;--text:#eeeae4;--muted:#a49d95;--faint:#7b746d;--ember:#ff7a45;--ember-wash:#2a1710;--lake:#4ecdc4;--c0:#6aa9ff;--c1:#ff7a45;--c2:#4ecdc4;--c3:#c39bf0;--c4:#e3b341;--c5:#a9b4bd;--c6:#5ad1e6;--c7:#f472b6;--c8:#a3d95f;--c9:#7dd3fc;--shadow:0 1px 2px rgb(0 0 0 / .4),0 8px 24px -12px rgb(0 0 0 / .6)}}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased;min-height:100vh;display:flex;flex-direction:column}
a{color:var(--lake);text-decoration:none}a:hover{text-decoration:underline;text-underline-offset:.18em}
.wrap{width:100%;max-width:1172px;margin-inline:auto;padding-inline:16px}
.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 86%,transparent);backdrop-filter:blur(12px) saturate(1.4);-webkit-backdrop-filter:blur(12px) saturate(1.4);border-bottom:1px solid var(--border)}
.top .wrap{display:flex;align-items:center;gap:20px;height:56px}
.brand{display:flex;align-items:center;gap:9px;color:var(--text);font-weight:700;font-size:17px;letter-spacing:-.02em;white-space:nowrap}
.brand:hover{text-decoration:none}.brand svg{display:block;flex-shrink:0}
.top nav{display:flex;align-items:center;gap:18px;margin-left:auto;font-size:14px}
.top nav a{color:var(--muted);padding:4px 0;border-bottom:1.5px solid transparent;white-space:nowrap}
.top nav a:hover{color:var(--text);text-decoration:none;border-bottom-color:var(--ember)}
.top nav a[aria-current=page]{color:var(--text);border-bottom-color:var(--ember)}
.top nav .sep{width:1px;height:16px;background:var(--border-strong)}
main{flex:1;padding:32px 0 48px}
h1{font-size:28px;font-weight:700;letter-spacing:-.02em;line-height:1.15;margin:0 0 8px;overflow-wrap:anywhere}
h2{font-size:18px;font-weight:600;letter-spacing:-.01em;margin:36px 0 12px}
.lead{color:var(--muted);max-width:72ch;margin:0 0 20px}
.sub{color:var(--muted);font-size:14px;margin:-4px 0 14px}
.tbl{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow)}
@media (max-width:1200px){.tbl{overflow-x:auto}.tbl th{position:static}}
table{border-collapse:separate;border-spacing:0;width:100%;font-size:14px}
th,td{text-align:left;padding:10px;border-bottom:1px solid var(--border);white-space:nowrap;vertical-align:top}
td.soft{white-space:normal;min-width:14ch;overflow-wrap:anywhere}
th{position:sticky;top:56px;z-index:1;background:var(--surface-2);color:var(--faint);font:500 11px/1.6 var(--mono);letter-spacing:.06em;text-transform:uppercase}
th:first-child{border-top-left-radius:var(--radius)}th:last-child{border-top-right-radius:var(--radius)}
tr:last-child td{border-bottom:0}
tbody tr:hover td{background:var(--surface-2)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
td.month{font-weight:600;background:var(--surface)}
.repo{font-weight:600}
.mono{font-family:var(--mono);font-size:12.5px}
.mute{color:var(--muted)}
.empty{background:var(--surface);border:1px dashed var(--border-strong);border-radius:var(--radius);padding:44px 24px;text-align:center;color:var(--muted)}
.empty strong{display:block;color:var(--text);font-size:17px;margin-bottom:6px}
.empty p{margin:0 auto;max-width:54ch}
.bar{display:flex;align-items:center;gap:10px;min-width:260px}
.bar i{display:block;height:10px;border-radius:3px;background:var(--ember);min-width:2px}
.bar span{font-variant-numeric:tabular-nums;min-width:3ch;text-align:right}
.head{margin-bottom:24px}
.head .owner{color:var(--muted);font-weight:500}
.head .desc{font-size:16px;max-width:72ch;margin:0 0 10px}
.meta{color:var(--muted);font-size:14px;margin:0 0 18px}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:10px}
.stat{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);padding:10px 12px;min-width:0}
.stat b{display:block;color:var(--faint);font:500 11.5px/1.5 var(--mono);letter-spacing:.08em;text-transform:uppercase}
.stat span{display:block;font-size:18px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-.01em;margin-top:2px;overflow-wrap:anywhere}
.stat small{display:block;color:var(--muted);font-size:12.5px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:16px 18px;box-shadow:var(--shadow)}
.card svg{display:block;width:100%;height:auto}
.card p{margin:8px 0 0;font-size:13px}
.early{margin-top:28px}.early>summary{cursor:pointer;font-weight:600;margin-bottom:14px}
.tbl+p{margin:10px 2px 0;font-size:13px}
footer{border-top:1px solid var(--border);background:var(--bg-alt);padding:24px 0;font-size:13px;color:var(--faint)}
footer .wrap{display:flex;flex-wrap:wrap;gap:8px 24px;align-items:center}
footer p{margin:0;max-width:78ch}
footer nav{display:flex;gap:16px;margin-left:auto}
footer .ver{color:var(--muted);font-variant-numeric:tabular-nums}
footer a{color:var(--muted)}footer a:hover{color:var(--text)}
footer .notice{flex-basis:100%;max-width:none;color:var(--ember)}
.search{flex:1;max-width:300px;min-width:0}
.search input{width:100%;font:inherit;font-size:14px;color:var(--text);background:var(--surface);border:1px solid var(--border-strong);border-radius:var(--radius-sm);padding:5px 10px}
.search input:focus{outline:2px solid var(--lake);outline-offset:1px}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--border);margin:0 0 24px;overflow-x:auto}
.tabs a{color:var(--muted);padding:8px 14px;border-bottom:2px solid transparent;margin-bottom:-1px;white-space:nowrap}
.tabs a:hover{color:var(--text);text-decoration:none}
.tabs a[aria-current=page],.tabs a[aria-selected=true]{color:var(--text);border-bottom-color:var(--ember);font-weight:600}
.tabbar{display:flex;align-items:center;gap:8px;margin:0 0 16px}.tabbar .tabs{flex:1;margin:0}
td.what{white-space:normal;min-width:30ch}
.card text{fill:var(--muted);font:11px var(--mono)}
.card .grid{stroke:var(--border);stroke-width:1}
.legend{display:flex;flex-wrap:wrap;gap:4px 18px;list-style:none;padding:0;margin:12px 0 0;font-size:13px}
.legend i{display:inline-block;width:14px;height:3px;border-radius:2px;margin-right:6px;vertical-align:middle}
.sort{margin:-8px 0 14px;font-size:13px}
.note{max-width:72ch}
.chips{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px;white-space:normal;max-width:46ch}
.chip{display:inline-block;font:500 11.5px/1.5 var(--mono);color:var(--muted);background:var(--surface-2);border:1px solid var(--border);border-radius:999px;padding:0 8px}
a.chip:hover{color:var(--text);border-color:var(--border-strong);text-decoration:none}
.head .chips{margin:0 0 14px;max-width:none}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.kpi{display:block;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:12px 14px;min-width:0;color:var(--text);box-shadow:var(--shadow)}
a.kpi:hover{border-color:var(--border-strong);text-decoration:none}
.kpi b{display:block;color:var(--faint);font:500 11.5px/1.5 var(--mono);letter-spacing:.08em;text-transform:uppercase}
.kpi>span{display:block;font-size:26px;font-weight:700;font-variant-numeric:tabular-nums;letter-spacing:-.02em;line-height:1.2;margin-top:2px}
.kpi small{display:block;color:var(--muted);font-size:12.5px}.kpi>span a{color:inherit}.kpi small a{color:var(--lake)}
.kpi .up{color:var(--c2)}.kpi .down{color:var(--ember)}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,330px),1fr));gap:16px}
.cols>div{min-width:0}.cols .tbl{overflow-x:auto}.cols .tbl th{position:static}
.card h3{margin:0 0 4px;font-size:15px;font-weight:600}
.card .donut{max-width:240px;margin:4px auto}
.donut text{fill:var(--muted);font:11px var(--mono)}
.donut text.big{fill:var(--text);font:700 30px ui-sans-serif,system-ui,sans-serif}
.donut a:hover circle{stroke-opacity:.75}
.card svg.lc text{font-size:12.5px}
.legend .sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:baseline}
.legend b{font-variant-numeric:tabular-nums;font-weight:600}
.legend a{color:var(--text)}
.big-stat{font-size:20px;font-weight:600;margin:0 0 4px}
.filters{display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center;margin:0 0 12px;font-size:13px}
.filters .chip{font-size:12.5px;padding:1px 10px}
.filters .on{color:var(--text);background:var(--ember-wash);border-color:var(--ember)}
.filters .label{color:var(--muted)}
th a{color:inherit;display:inline-block}th a:hover{color:var(--text);text-decoration:none}
th[aria-sort] a{color:var(--text)}
.asof{color:var(--muted);font-size:13px;max-width:78ch;margin-top:28px}
.cov{color:var(--muted);font-size:13.5px;max-width:78ch;margin:-8px 0 16px}.cov b{color:var(--text);font-weight:600}.cov a{color:var(--lake)}.cov a,.cov .nw{white-space:nowrap}
.hq{position:relative;display:inline-block;vertical-align:middle;margin-left:6px;line-height:1}
.help{position:relative;display:inline-flex;-webkit-tap-highlight-color:transparent;align-items:center;justify-content:center;width:18px;height:18px;padding:0;border:1px solid var(--border-strong);border-radius:50%;background:transparent;color:var(--muted);font:600 11px/1 ui-sans-serif,system-ui,sans-serif;cursor:pointer}
.help::after{content:"";position:absolute;inset:-8px}
.help:hover,.help[aria-expanded=true]{color:var(--text);border-color:var(--muted)}
.help:focus-visible{outline:2px solid var(--lake);outline-offset:2px}
.pop{position:absolute;z-index:20;top:calc(100% + 8px);left:-8px;width:max-content;max-width:min(340px,calc(100vw - 32px));padding:10px 12px;background:var(--surface);color:var(--text);border:1px solid var(--border-strong);border-radius:var(--radius-sm);box-shadow:var(--shadow);font:400 13px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;letter-spacing:normal;text-transform:none;text-align:left;white-space:normal}
.pop::before{content:"";position:absolute;left:0;right:0;top:-9px;height:9px}
.pop[hidden]{display:none}
.pop a{color:var(--lake)}
.diagram{margin:20px 0 8px;overflow-x:auto;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:16px;box-shadow:var(--shadow)}
.diagram pre{margin:0;font:12px/1.5 var(--mono);color:var(--muted);white-space:pre}
.diagram svg{display:block;margin:0 auto;max-width:none;height:auto}
.diagram .node.pipe rect{fill:var(--ember-wash)!important;stroke:var(--ember)!important}
.diagram .node.ice path{fill:var(--surface-2)!important;stroke:var(--lake)!important}
.diagram .node.ext rect{fill:var(--bg-alt)!important}
.lineage{margin:20px auto 8px;max-width:436px}
.shot{margin:16px 0}.shot img{display:block;width:100%;height:auto;border-radius:var(--radius-sm);border:1px solid var(--border)}.shot figcaption{color:var(--muted);font-size:13px;margin-top:6px}
@media (max-width:640px){.kpi>span{font-size:22px}.top .wrap{gap:12px;flex-wrap:wrap;height:auto;padding-block:8px}.search{order:3;flex-basis:100%;max-width:none}.top nav{gap:12px}.top nav .sep,.top nav .arrow{display:none}.brand{font-size:15px}h1{font-size:24px}th,td{padding:9px 10px}main{padding-top:24px}footer nav{margin-left:0}}
"""


comptime MARK = (
    "<svg width=20 height=20 viewBox='0 0 16 16' fill=none aria-hidden=true>"
    "<rect width=16 height=16 rx=3 fill='#b45309'/>"
    "<rect x=3 y=8 width=2.5 height=5 fill='#fff'/>"
    "<rect x=6.75 y=4 width=2.5 height=9 fill='#fff'/>"
    "<rect x=10.5 y=6 width=2.5 height=7 fill='#fff'/></svg>"
)
"""The tab icon's amber square with three white bars: reads on both themes."""

comptime HELP_JS = (
    "<script>(()=>{const hs=[];"
    "const place=p=>{p.style.left='';const w=document.documentElement.clientWidth,"
    "r=p.getBoundingClientRect();let d=0;if(r.right>w-8)d=r.right-(w-8);if(r.left-d<8)d=r.left-8;"
    "if(d)p.style.left=(parseFloat(getComputedStyle(p).left)-d)+'px'};"
    "document.querySelectorAll('.hq').forEach(q=>{const b=q.querySelector('.help'),p=q.querySelector('.pop');"
    "const s={pin:false,hov:false,foc:false};"
    "const set=()=>{const o=s.pin||s.hov||s.foc;if(o!==p.hidden)return;p.hidden=!o;"
    "b.setAttribute('aria-expanded',String(o));if(o)place(p)};"
    "const close=()=>{s.pin=s.hov=s.foc=false;set()};hs.push({q,close});"
    "q.addEventListener('pointerenter',e=>{if(e.pointerType==='mouse'){s.hov=true;set()}});"
    "q.addEventListener('pointerleave',e=>{if(e.pointerType==='mouse'){s.hov=false;set()}});"
    "b.addEventListener('focus',()=>{if(b.matches(':focus-visible')){s.foc=true;set()}});"
    "b.addEventListener('blur',()=>{s.foc=false;s.pin=false;set()});"
    "b.addEventListener('click',()=>{const pin=!s.pin;hs.forEach(h=>{if(h.q!==q)h.close()});"
    "s.pin=pin;if(!pin){s.hov=false;s.foc=false}set()})});"
    "document.addEventListener('pointerdown',e=>hs.forEach(h=>{if(!h.q.contains(e.target))h.close()}));"
    "document.addEventListener('keydown',e=>{if(e.key==='Escape')hs.forEach(h=>h.close())})"
    "})()</script>"
)
"""Opens and closes the `_help` popovers: on hover with a mouse, on keyboard
focus, and pinned by a click or tap; a click or tap elsewhere or Escape closes
them. No-op on pages without one."""


def _help(id: String, label: String, text: String) -> String:
    """A small "?" button after a title that shows `text` (HTML, phrasing
    content only) in a popover; `label` names what it explains for screen
    readers, and `id` must be unique on the page."""
    return String(
        "<span class=hq><button type=button class=help aria-expanded=false aria-controls='",
        id,
        "' aria-describedby='",
        id,
        "' aria-label='About ",
        html_escape(label),
        "'>?</button>",
        "<span class=pop id='",
        id,
        "' role=tooltip hidden>",
        text,
        "</span></span>",
    )


def _nav(href: String, label: String, current: Bool) -> String:
    return String("<a href='", href, "'", " aria-current=page" if current else "", ">", label, "</a>")


comptime BRAND = "Mojourney"
comptime SUBTITLE = "the Mojo ecosystem census"
comptime SITE_URL = "https://mojourney.dev"
comptime FEEDBACK = "https://github.com/morca-dev/census/issues"
"""Where the footer's Feedback link goes."""


def census_version() -> String:
    """The release the console is (`1.2.0`, from CENSUS_VERSION, set on a
    release image), else `dev <commit>` (MORCA_COMMIT), else `dev`."""
    var raw = getenv("CENSUS_VERSION")
    var v = String(raw[byte=1:]) if raw.startswith("v") else raw
    if v:
        return v
    var c = getenv("MORCA_COMMIT")
    if c:
        return String("dev ", c[byte = : min(7, c.byte_length())])
    return String("dev")


def _version_link() -> String:
    var v = census_version()
    var commit = getenv("MORCA_COMMIT")
    return String(
        "<a class=ver href='/how/changelog' title='",
        html_escape(String("commit ", commit) if commit else String("this build")),
        "'>",
        html_escape(v),
        "</a>",
    )


comptime EDGE_CACHE = "public, max-age=60, s-maxage=1800, stale-while-revalidate=60, stale-if-error=86400"
"""Cache-Control of a page or JSON answer: a minute in the browser, 30 minutes
at Cloudflare's edge (the refresher's period; a cache rule for mojourney.dev
must make HTML eligible for caching: README, "Edge caching"). Past that the
edge may answer from its copy while it fetches a new one (a minute), and
for a day while the console can't answer: a deploy's restart, or its
warming-up 503, shows readers the last page instead of an error. The
warming-up page, `/checks` and any answer but a 200 are `no-store`."""

comptime DESCRIPTION = (
    "Mojo repos, versions and growth, counted from GH Archive by"
    " magmalake. An independent project, not affiliated with Modular."
)


def _page(
    title: String,
    var body: String,
    section: String,
    q: String = "",
    description: String = "",
    alternate: String = "",
) raises -> Response:
    """The page around `body`; `section` is `repos`, `migrations`, `how` or `ai`, the
    nav entry to light up (none for the overview and search); `q` fills the search box. An empty `title` is the
    home page, titled with the brand alone; others read "<title> · Mojourney".
    `description` is its meta description (`DESCRIPTION` when empty, most from
    `console_pages`) and `alternate` the URL of its JSON, if it has one."""
    var full = String(BRAND, ": ", SUBTITLE) if title == "" else String(title, " · ", BRAND)
    var h = String(
        (
            '<!doctype html><html lang=en><head><meta charset=utf-8><link rel=icon href="data:image/svg+xml,%3Csvg'
            " xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='3'"
            " fill='%23b45309'/%3E%3Crect x='3' y='8' width='2.5' height='5' fill='%23fff'/%3E%3Crect x='6.75' y='4'"
            " width='2.5' height='9' fill='%23fff'/%3E%3Crect x='10.5' y='6' width='2.5' height='7'"
            " fill='%23fff'/%3E%3C/svg%3E\">"
        ),
        "<meta name=viewport content='width=device-width,initial-scale=1'>",
        "<meta name=color-scheme content='light dark'>",
        "<meta name=description content='",
        html_escape(description if description else String(DESCRIPTION)),
        "'>",
        String(
            "<link rel=alternate type=application/json href='", html_escape(alternate), "'>"
        ) if alternate else String(),
        "<title>",
        html_escape(full),
        "</title><style>",
        STYLE,
        "</style>",
        posthog_snippet(getenv("POSTHOG_KEY"), "mojourney"),
        "</head><body>",
        "<header class=top><div class=wrap><a class=brand href='/'>",
        MARK,
        BRAND,
        "</a>",
        "<form class=search action='/search' role=search><input type=search name=q value='",
        html_escape(q),
        "' placeholder='Search repos' aria-label='Search repos'",
        " autocomplete=off></form>",
        "<nav>",
        _nav("/repos", "Repos", section == "repos"),
        _nav("/migrations", "Migrations", section == "migrations"),
        _nav("/live", "Live", section == "live"),
        _nav("/how", "How it works", section == "how"),
        "<span class=sep aria-hidden=true></span>",
        (
            "<a href='https://orca.mojourney.dev' rel=noopener title='The pipelines that build this census'>morca<span"
            " class=arrow> &#8599;</span></a><a href='https://mlake.dev' rel=noopener>mlake.dev<span class=arrow>"
            " &#8599;</span></a></nav></div></header>"
        ),
        "<main><div class=wrap>",
        body,
        "</div></main>",
        "<footer><div class=wrap><p>An independent project; Mojo is a trademark of Modular Inc.",
        " Data from <a href='https://www.gharchive.org' rel=noopener>GH Archive</a>, read by the",
        " mojo-census pipelines on <a href='https://orca.mojourney.dev' rel=noopener>morca</a>: the hour's",
        " public GitHub events, the repositories with Mojo in them, and what their lock files",
        " say at each commit.</p>",
        "<nav><a href='https://mlake.dev' rel=noopener>mlake.dev</a>",
        "<a href='",
        FEEDBACK,
        "' rel=noopener>Feedback</a>",
        "<a href='https://github.com/morca-dev' rel=noopener>GitHub</a>",
        "<a href='/ai'>Use with AI</a><a href='/api/repos'>JSON</a>",
        _version_link(),
        "</nav></div></footer>",
        HELP_JS,
        "</body></html>",
    )
    var resp = Response(status=200, reason="OK", body=List[UInt8](h.as_bytes()))
    resp.headers.set("Content-Type", "text/html; charset=utf-8")
    resp.headers.set("Cache-Control", EDGE_CACHE)
    return resp^


def _empty(title: String, text: String) -> String:
    return String("<div class=empty><strong>", title, "</strong><p>", text, "</p></div>")


def _n(v: Int64) -> String:
    """`12,345`: a number with thousands separators."""
    if v < 0:
        return String("-", _n(-v))
    if v < 1000:
        return String(v)
    var rest = v % 1000
    var tail = String(rest)
    if rest < 10:
        tail = String("00", rest)
    elif rest < 100:
        tail = String("0", rest)
    return String(_n(v // 1000), ",", tail)


def _age(micros: Int64, now_days: Int) -> String:
    """`3.2 years` / `5 months` / `12 days` since `micros`."""
    if micros == 0:
        return String()
    var d = now_days - Int(micros // 86_400_000_000)
    if d >= 365:
        var tenths = d * 10 // 365
        return String(tenths // 10, ".", tenths % 10, " years")
    if d >= 60:
        return String(d // 30, " months")
    return String(d, " days")


def _now_days() raises -> Int:
    return Int(now() // 86400)


def _this_month() raises -> String:
    """`2026-11`: the month in progress, which the per-month charts leave out.
    Its few days so far would read as a drop at the end of every curve."""
    return month_label(month_of_days(_now_days()))


def _or_dash(s: String) -> String:
    """`s` escaped, or a muted dash when it's empty."""
    if s.byte_length() == 0:
        return String("<span class=mute>&ndash;</span>")
    return html_escape(s)


def _chips(topics: List[String], limit: Int = 6) -> String:
    """GitHub topics as chips, each a search for it."""
    if len(topics) == 0:
        return String()
    var h = String("<div class=chips>")
    for i in range(min(len(topics), limit)):
        h.write(
            "<a class=chip href='/search?q=",
            html_escape(topics[i]),
            "'>",
            html_escape(topics[i]),
            "</a>",
        )
    if len(topics) > limit:
        h.write("<span class=chip>+", len(topics) - limit, "</span>")
    h.write("</div>")
    return h^
