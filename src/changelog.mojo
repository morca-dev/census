"""CHANGELOG.md as HTML, for the How it works page's Changelog tab.

Only the Markdown the changelog uses: `## <version> - <date>` headings,
`- ` bullets (blank lines between them, indented continuation lines),
paragraphs, `**bold**`, `` `code` ``, `[text](url)` links, and PR numbers,
`#123`, which link to the census's pull requests. Everything before the
first `## ` heading (the `# Changelog` title, and the note on fragments for
contributors) is dropped: the page has its own title and lead.
"""


def changelog_html(text: String, pulls: String) -> String:
    """`text`, CHANGELOG.md, as HTML; `#123` links to `<pulls>/123`."""
    var out = String()
    var para = String()
    var item = String()
    var in_list = False
    var started = False
    for raw in text.split("\n"):
        var line = String(raw)
        if not started and not line.startswith("## "):
            continue
        started = True
        if line.startswith("## "):
            _flush(out, para, item, in_list, pulls)
            _close_list(out, in_list)
            var head = String(line[byte=3:])
            var version = String(head.split(" ")[0])
            out.write("<h2 id='v", _escape(version), "'>", _inline(head, pulls), "</h2>")
        elif line.startswith("# "):
            _flush(out, para, item, in_list, pulls)
            _close_list(out, in_list)
        elif line.startswith("- "):
            _flush(out, para, item, in_list, pulls)
            if not in_list:
                out.write("<ul>")
                in_list = True
            item = String(line[byte=2:])
        elif String(line.strip()) == "":
            _flush(out, para, item, in_list, pulls)
        elif item != "":
            item.write(" ", line.strip())
        else:
            _close_list(out, in_list)
            if para != "":
                para.write(" ")
            para.write(line.strip())
    _flush(out, para, item, in_list, pulls)
    _close_list(out, in_list)
    return out^


def _flush(
    mut out: String, mut para: String, mut item: String, in_list: Bool, pulls: String
):
    if item != "":
        out.write("<li>", _inline(item, pulls), "</li>")
        item = String()
    if para != "":
        out.write("<p>", _inline(para, pulls), "</p>")
        para = String()


def _close_list(mut out: String, mut in_list: Bool):
    if in_list:
        out.write("</ul>")
        in_list = False


def _escape(s: String) -> String:
    var out = List[UInt8]()
    for c in s.as_bytes():
        _put(out, c)
    return String(unsafe_from_utf8=out)


def _put(mut out: List[UInt8], c: UInt8):
    """One byte of text, escaped for HTML."""
    if c == UInt8(ord("&")):
        _put_str(out, "&amp;")
    elif c == UInt8(ord("<")):
        _put_str(out, "&lt;")
    elif c == UInt8(ord(">")):
        _put_str(out, "&gt;")
    elif c == UInt8(ord("'")):
        _put_str(out, "&#39;")
    elif c == UInt8(ord('"')):
        _put_str(out, "&quot;")
    else:
        out.append(c)


def _put_str(mut out: List[UInt8], s: StringSpan):
    for c in s.as_bytes():
        out.append(c)


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _find(b: Span[UInt8, _], start: Int, c: UInt8) -> Int:
    """The index of `c` in `b` from `start`, or -1."""
    for i in range(start, len(b)):
        if b[i] == c:
            return i
    return -1


def _inline(s: String, pulls: String) -> String:
    """A line's text as HTML: escaped, with bold, code, links and PR numbers."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8]()
    var bold = False
    var i = 0
    while i < n:
        var c = b[i]
        if c == UInt8(ord("`")):
            var end = _find(b, i + 1, UInt8(ord("`")))
            if end > i:
                _put_str(out, "<code>")
                for j in range(i + 1, end):
                    _put(out, b[j])
                _put_str(out, "</code>")
                i = end + 1
                continue
        elif c == UInt8(ord("*")) and i + 1 < n and b[i + 1] == UInt8(ord("*")):
            _put_str(out, "</strong>" if bold else "<strong>")
            bold = not bold
            i += 2
            continue
        elif c == UInt8(ord("[")):
            var close = _find(b, i + 1, UInt8(ord("]")))
            if close > i and close + 1 < n and b[close + 1] == UInt8(ord("(")):
                var end = _find(b, close + 2, UInt8(ord(")")))
                if end > close:
                    _put_str(out, "<a href='")
                    for j in range(close + 2, end):
                        _put(out, b[j])
                    _put_str(out, "' rel=noopener>")
                    out.extend(
                        _inline(String(StringSpan(unsafe_from_utf8=b[i + 1 : close])), pulls)
                        .as_bytes()
                    )
                    _put_str(out, "</a>")
                    i = end + 1
                    continue
        elif c == UInt8(ord("#")) and i + 1 < n and _is_digit(b[i + 1]) and (
            i == 0 or not _is_digit(b[i - 1])
        ):
            var end = i + 1
            while end < n and _is_digit(b[end]):
                end += 1
            var num = StringSpan(unsafe_from_utf8=b[i + 1 : end])
            _put_str(out, "<a href='")
            _put_str(out, pulls)
            _put_str(out, "/")
            _put_str(out, num)
            _put_str(out, "' rel=noopener>#")
            _put_str(out, num)
            _put_str(out, "</a>")
            i = end
            continue
        _put(out, c)
        i += 1
    if bold:
        _put_str(out, "</strong>")
    return String(unsafe_from_utf8=out)
