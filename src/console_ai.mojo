"""What the console serves for crawlers and language models: `/llms.txt`
(llmstxt.org), `/llms-full.txt`, `/sitemap.xml` and `/robots.txt`.

All of it is written from `console_pages`' list and the current `Cache`, the
same as the pages, so it names only routes that exist and numbers that are
current. `/llms-full.txt` is the How it works pages' own HTML, as text.
"""

from flare.http import Request, Response

from days import day_text
from jscan import micros_to_iso
from overview import ACTIVE_DAYS, ARCHIVE_START, archive_days_due

from console_cache import Cache, refresh_secs
from console_how import changelog, how, optimizations
from console_layout import BRAND, EDGE_CACHE, SITE_URL, SUBTITLE, _n
from console_pages import REPO_JSON, REPO_PAGE, SitePage, api_pages, site_pages


def _text(var body: String, content_type: String) raises -> Response:
    var resp = Response(status=200, reason="OK", body=List[UInt8](body.as_bytes()))
    resp.headers.set("Content-Type", content_type)
    resp.headers.set("Cache-Control", EDGE_CACHE)
    return resp^


def example_repo(c: Cache) -> String:
    """The repo `/llms.txt` links as its example repo page: the biggest."""
    return c.libs[0].repo if len(c.libs) > 0 else String()


def _expand(path: String, repo: String) -> String:
    """`path` with `:owner/:name` filled in with `repo`."""
    return path.replace(":owner/:name", repo)


def _entry(p: SitePage, repo: String) -> String:
    """A `/llms.txt` list item, or "" for a repo's entry when there's no repo."""
    var path = _expand(p.path, repo)
    if ":owner" in path:
        return String()
    var name = String(p.name, ": ", repo) if p.path == REPO_PAGE or p.path == REPO_JSON else p.name
    var out = String("- [", name, "](", SITE_URL, path, "): ", p.line)
    if p.path == REPO_PAGE:
        out += " Every repo's page is at /repos/<owner>/<name>."
    elif p.path == REPO_JSON:
        out += " Every repo's is at /api/repos/<owner>/<name>."
    if p.json:
        out.write(" JSON: ", SITE_URL, _expand(p.json, repo))
    out += "\n"
    return out^


def llms_txt(c: Cache) -> String:
    """`/llms.txt`: what the census is and how fresh, then each page and each
    JSON endpoint with a line on what it holds."""
    var repo = example_repo(c)
    var minutes = refresh_secs() // 60
    var out = String(
        "# ",
        BRAND,
        "\n\n> ",
        BRAND,
        ", ",
        SUBTITLE,
        ": the public GitHub repos that contain Mojo",
        " code (",
        _n(Int64(len(c.libs))),
        " as of ",
        day_text(Int64(c.built_day)),
        "), found in GH Archive,",
        " with their whole git history read for their Mojo version, size and growth.",
        " An independent project, not affiliated with Modular.\n\n",
        "The pipelines load each day of GH Archive at 03:00 UTC, the day before; GitHub's stars, forks",
        " and issues once a day; and new commits to the repos every 20 minutes (the Live page).",
        " This site looks at the tables every ",
        minutes,
        " minutes and rebuilds when one changed.",
        " The pages are mostly charts and tables, so read the numbers from the JSON endpoints below.\n\n",
        "## Pages\n\n",
    )
    for p in site_pages():
        out += _entry(p, repo)
    out += "\n## JSON\n\n"
    for p in api_pages():
        out += _entry(p, repo)
    out.write(
        "\n## MCP\n\n",
        "- [MCP server](",
        SITE_URL,
        "/mcp): The same data for agents, as a remote MCP server (Streamable HTTP, POST only,",
        " read-only, no auth). Tools: search_repos, list_repos, get_repo, similar_repos,",
        " version_adoption and overview.\n",
        "\n## Optional\n\n",
        "- [Full text](",
        SITE_URL,
        "/llms-full.txt): The How it works pages and the overview's",
        " numbers, as plain text.\n",
        "- [Sitemap](",
        SITE_URL,
        "/sitemap.xml): Every page, with one URL per repo.\n",
    )
    return out^


def _xml(s: String) -> String:
    return (
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&apos;").replace('"', "&quot;")
    )


def sitemap_xml(c: Cache) -> String:
    """`/sitemap.xml`: the fixed pages, then each repo's page."""
    var out = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n',
    )
    for p in site_pages():
        if p.path == REPO_PAGE:
            continue
        out.write("<url><loc>", SITE_URL, _xml(p.path), "</loc></url>\n")
    for ref l in c.libs:
        out.write("<url><loc>", SITE_URL, "/repos/", _xml(l.repo), "</loc></url>\n")
    out += "</urlset>\n"
    return out^


def robots(req: Request) raises -> Response:
    """`/robots.txt`: only where the sitemap is. Cloudflare's managed
    robots.txt (its content signals) is put in front of it at the edge."""
    return _text(
        String("User-agent: *\nAllow: /\n\nSitemap: ", SITE_URL, "/sitemap.xml\n"), "text/plain; charset=utf-8"
    )


def _entity(name: String) -> String:
    """The text of `&name;`, or "" for one it doesn't know."""
    if name == "amp":
        return "&"
    if name == "lt":
        return "<"
    if name == "gt":
        return ">"
    if name == "quot":
        return '"'
    if name == "apos":
        return "'"
    if name == "nbsp":
        return " "
    if name == "middot":
        return "·"
    if name == "ndash":
        return "–"
    if name == "mdash":
        return "—"
    if name == "ldquo":
        return "“"
    if name == "rdquo":
        return "”"
    if name == "lsquo":
        return "‘"
    if name == "rsquo":
        return "’"
    if name == "rarr":
        return "→"
    if name == "times":
        return "×"
    if name == "hellip":
        return "…"
    if name == "euro":
        return "€"
    if name == "minus":
        return "−"
    if name.startswith("#"):
        try:
            var n: Int
            if name.startswith("#x") or name.startswith("#X"):
                n = atol(String(name[byte=2:]), base=16)
            else:
                n = Int(String(name[byte=1:]))
            var cp = Codepoint.from_u32(UInt32(n))
            if cp:
                return String(cp.value())
        except:
            pass
    return String()


def _attr(tag: String, name: String) -> String:
    """The value of attribute `name` in the start tag `tag`, else ""."""
    var at = tag.find(String(" ", name, "=")).or_else(-1)
    if at < 0:
        return String()
    var i = at + name.byte_length() + 2
    var b = tag.as_bytes()
    if i >= len(b):
        return String()
    var q = b[i]
    if q == UInt8(ord("'")) or q == UInt8(ord('"')):
        var end = tag.find(chr(Int(q)), i + 1).or_else(-1)
        if end < 0:
            return String()
        return String(tag[byte = i + 1 : end])
    var end = i
    while end < len(b) and b[end] != UInt8(ord(" ")) and b[end] != UInt8(ord(">")):
        end += 1
    return String(tag[byte=i:end])


def _absolute(href: String) -> String:
    return String(SITE_URL, href) if href.startswith("/") else href


def html_text(html: String) -> String:
    """The text of a page's `<main>`, as Markdown-ish plain text: headings as
    `#`, list items as `- `, table cells split by ` | `, links as
    `[text](url)` and code in backticks; scripts, nav tabs and help buttons
    dropped."""
    var start = html.find("<main>").or_else(-1)
    var stop = html.find("</main>").or_else(-1)
    var s = String(html[byte = start + 6 : stop]) if start >= 0 and stop > start else html
    var out = String()
    var b = s.as_bytes()
    var i = 0
    # Nesting depth inside an element whose text is dropped.
    var skip = 0
    var skip_tag = String()
    var href = String()
    while i < len(b):
        var ch = b[i]
        if ch == UInt8(ord("<")):
            var end = s.find(">", i).or_else(-1)
            if end < 0:
                break
            var tag = String(s[byte = i + 1 : end])
            i = end + 1
            var closing = tag.startswith("/")
            var full = String(tag[byte=1:]) if closing else tag
            var sp = full.find(" ").or_else(-1)
            var name = (String(full[byte=:sp]) if sp >= 0 else full).lower()
            if skip > 0:
                if name == skip_tag:
                    skip += -1 if closing else 1
                continue
            if not closing and (
                name == "script"
                or name == "style"
                or name == "nav"
                or name == "button"
                or (name == "span" and "class=pop" in tag)
            ):
                skip = 1
                skip_tag = name
                continue
            if name == "h1" or name == "h2" or name == "h3":
                if closing:
                    out += "\n\n"
                else:
                    out += "\n\n#"
                    if name != "h1":
                        out += "#" if name == "h2" else "##"
                    out += " "
            elif name == "li":
                if not closing:
                    out += "\n- "
            elif name == "td" or name == "th":
                if closing:
                    out += " | "
            elif name == "tr":
                out += "\n"
            elif (
                name == "p"
                or name == "div"
                or name == "ul"
                or name == "ol"
                or name == "table"
                or name == "figure"
                or name == "figcaption"
                or name == "pre"
                or name == "br"
            ):
                out += "\n\n" if name != "br" else "\n"
            elif name == "code":
                out += "`"
            elif name == "a":
                if closing:
                    if href:
                        out.write("](", _absolute(href), ")")
                    href = String()
                else:
                    href = _attr(tag, "href")
                    if href.startswith("#"):
                        href = String()  # a link within the page
                    if href:
                        out += "["
            elif name == "img" and not closing:
                var alt = _attr(tag, "alt")
                if alt:
                    out.write("[image: ", alt, "]")
            continue
        if skip > 0:
            i += 1
            continue
        if ch == UInt8(ord("&")):
            var end = s.find(";", i).or_else(-1)
            if end > i and end - i <= 10:
                var e = _entity(String(s[byte = i + 1 : end]))
                if e:
                    out += e
                    i = end + 1
                    continue
        if ch < 128:
            out += chr(Int(ch))
            i += 1
            continue
        # The whole UTF-8 sequence.
        var n = 1
        while i + n < len(b) and (b[i + n] & 0xC0) == 0x80:
            n += 1
        out += String(s[byte = i : i + n])
        i += n
    return _tidy(out)


def _tidy(s: String) -> String:
    """`s` with runs of spaces made one, spaces at line ends dropped and at
    most one blank line in a row."""
    var out = String()
    var blank = 0
    for line in s.split("\n"):
        var words = String()
        var space = False
        for cp in line.codepoint_slices():
            if cp == " " or cp == "\t":
                space = True
                continue
            if space and words.byte_length() > 0:
                words += " "
            space = False
            words += cp
        if words.byte_length() == 0 or words == "|":
            blank += 1
            continue
        if out.byte_length() > 0:
            out += "\n\n" if blank > 0 else "\n"
        blank = 0
        out += words
    out += "\n"
    return out^


def _overview_text(c: Cache) -> String:
    """The overview's numbers (as `/api/overview` has them), as text."""
    ref ov = c.ov
    var out = String(
        "# The numbers\n\nAs of ",
        micros_to_iso(c.sources.as_of_ms * 1000),
        " (",
        min(c.sources.archive_days, archive_days_due(c.built_day)),
        " days of GH Archive loaded, ",
        day_text(Int64(ARCHIVE_START)),
        " to ",
        day_text(Int64(c.built_day - 1)),
        ", of ",
        archive_days_due(c.built_day),
        " due). JSON: ",
        SITE_URL,
        "/api/overview\n\n",
        "- Repos with Mojo: ",
        _n(Int64(ov.repos)),
        " (",
        _n(Int64(ov.repos_30_ago)),
        " 30 days ago); ",
        _n(Int64(ov.with_history)),
        " with their history read; ",
        _n(Int64(ov.active)),
        " with a commit in the last ",
        ACTIVE_DAYS,
        " days\n",
        "- Commits: ",
        _n(Int64(ov.commits)),
        "; ",
        _n(Int64(ov.commits_30)),
        " in the last 30 days, ",
        _n(Int64(ov.commits_prev_30)),
        " in the 30 before\n",
        "- Lines of Mojo: ",
        _n(Int64(ov.lines)),
        " (",
        _n(Int64(ov.lines_30_ago)),
        " 30 days ago)\n",
        "- New repos: ",
        ov.new_this_month,
        " this month, ",
        ov.new_last_month,
        " last month\n",
    )
    if len(ov.buckets) > 0:
        out += "\n## Repos per Mojo version\n\n"
    for i in range(len(ov.buckets)):
        out.write(
            "- ",
            ov.buckets[i],
            ": ",
            _n(Int64(ov.bucket_repos[i])),
            " repos, ",
            _n(Int64(ov.bucket_active[i])),
            " active\n",
        )
    if len(c.rising) > 0:
        out += "\n## Rising (stars gained in 30 days)\n\n"
        for i in range(len(c.rising)):
            out.write("- ", c.rising[i], ": +", c.rising_gain[i], " stars, +", c.rising_forks[i], " forks\n")
    if len(c.active_repos) > 0:
        out += "\n## Most active (commits in 30 days)\n\n"
        for i in range(len(c.active_repos)):
            out.write("- ", c.active_repos[i], ": ", c.active_commits[i], " commits\n")
    if len(c.depended) > 0:
        out += "\n## Most depended on\n\n"
        for ref d in c.depended:
            out.write("- ", d.name, ": used by ", d.used_by, " census repos\n")
    if len(ov.months) > 0:
        out += "\n## Per month (repos, commits, lines of Mojo at the month's end)\n\n"
        for k in range(len(ov.months)):
            out.write(
                "- ",
                ov.months[k],
                ": ",
                _n(Int64(ov.repos_series[k])),
                " repos, ",
                _n(Int64(ov.commits_series[k])),
                " commits, ",
                _n(Int64(ov.lines_series[k])),
                " lines\n",
            )
    return out^


def _body(resp: Response) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body)))


def llms_full_txt(c: Cache) raises -> String:
    """`/llms-full.txt`: `/llms.txt`, the overview's numbers, then the How it
    works pages' text."""
    var req = Request("GET", "/llms-full.txt")
    var out = String(llms_txt(c), "\n", _overview_text(c))
    out.write("\n# How it works (", SITE_URL, "/how)\n\n", _how_text(how(req)))
    out.write("\n# Optimizations (", SITE_URL, "/how/optimizations)\n\n", _how_text(optimizations(req)))
    out.write("\n# Changelog (", SITE_URL, "/how/changelog)\n\n", _how_text(changelog(req)))
    return out^


def _how_text(resp: Response) -> String:
    """A How it works page's text, without the "How it works" title its tabs
    share."""
    comptime TITLE = "# How it works\n\n"
    var t = html_text(_body(resp))
    return String(t[byte = TITLE.byte_length() :]) if t.startswith(TITLE) else t^


def llms_response(c: Cache) raises -> Response:
    return _text(llms_txt(c), "text/plain; charset=utf-8")


def llms_full_response(c: Cache) raises -> Response:
    return _text(llms_full_txt(c), "text/plain; charset=utf-8")


def sitemap_response(c: Cache) raises -> Response:
    return _text(sitemap_xml(c), "application/xml")
