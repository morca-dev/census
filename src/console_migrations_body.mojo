"""The Migrations page's body (`/migrations`): the repos moving to each Mojo
version per month, as a chart and tables, which the console's `Cache`
renders once per build; and the line chart it draws, which a repo's stars
chart uses too."""

from flare.http import html_escape
from charts import grid_line
from model import VersionMonth
from overview import bucket_color
from search import sort_buckets, version_bucket

from console_layout import _help, _this_month


def _next_month(m: String) raises -> String:
    """`2025-12` -> `2026-01`."""
    var y = Int(m[byte=:4])
    var mo = Int(m[byte=5:7])
    if mo == 12:
        return String(y + 1, "-01")
    return String(y, "-", "0" if mo < 9 else "", mo + 1)


def _versions_chart(all_rows: List[VersionMonth]) raises -> String:
    """Repos migrating each month as one line per Mojo version bucket
    (`pre-1.0`, then each 1.x minor), as inline SVG with a legend. The
    month in progress is left out while there are earlier ones."""
    var this_month = _this_month()
    var rows = List[VersionMonth]()
    for ref r in all_rows:
        if r.month != this_month:
            rows.append(r.copy())
    if len(rows) == 0:
        rows = all_rows.copy()
    var names = List[String]()
    var oldest = List[String]()
    for ref r in rows:
        var k = version_bucket(r.version)
        if k not in names:
            names.append(k)
            oldest.append(r.version)
    sort_buckets(names, oldest)
    # Buckets keep their colour across the site (the overview's donuts too).
    var colors = List[String]()
    for ref f in names:
        colors.append(bucket_color(f))
    var months = List[String]()
    var m = rows[0].month
    var last = rows[len(rows) - 1].month
    months.append(m)
    while m < last:
        m = _next_month(m)
        months.append(m)
    var counts = Dict[String, Int]()
    var top = 1
    for ref r in rows:
        var k = String(version_bucket(r.version), "|", r.month)
        var c = counts.get(k, 0) + r.repos
        counts[k] = c
        if c > top:
            top = c
    return _line_chart(
        months, names, counts, top,
        String("Line chart: repos migrating to each Mojo version"),
        String(
            "Repos migrating to each Mojo version per month, ", months[0], " to ", last,
        ),
        String(
            "Repos per month, to the last full month; a repo that moved twice in a month"
            " counts for each version.",
        ),
        colors,
    )


def _line_chart(
    months: List[String],
    names: List[String],
    counts: Dict[String, Int],
    top: Int,
    aria: String,
    title: String,
    note: String,
    colors: List[String] = List[String](),
) raises -> String:
    """One line per name over `months`, from `counts` (`name|month`), as
    inline SVG with a legend; the versions and the stars charts draw it.
    `colors` gives each name's colour (by default the palette in order)."""
    var last = months[len(months) - 1]
    var left = 36
    var right = 12
    var up = 10
    var w = 900
    var h = 240
    var pw = w - left - right
    var ph = h - up - 30
    var n = len(months)
    var svg = String(
        "<svg viewBox='0 0 ", w, " ", h, "' role=img aria-label='", html_escape(aria),
        "'><title>", html_escape(title), "</title>",
    )
    # Gridlines and the Y axis: 0, the middle if there's room, the top.
    var ticks = List[Int]()
    ticks.append(0)
    if top >= 4:
        ticks.append(top // 2)
    ticks.append(top)
    for t in ticks:
        var y = up + ph - t * ph // top
        svg.write(
            grid_line(left, w - right, y),
            "<text x=", left - 6, " y=", y + 4, " text-anchor=end>", t, "</text>",
        )
    # X labels, thinned to about twelve.
    var every = (n + 11) // 12
    for i in range(n):
        var x = left + (pw // 2 if n == 1 else i * pw // (n - 1))
        if i % every == 0:
            svg.write("<text x=", x, " y=", h - 8, " text-anchor=middle>", months[i], "</text>")
    var legend = String("<ul class=legend>")
    for si in range(len(names)):
        var color = colors[si] if si < len(colors) else String("var(--c", si % 6, ")")
        var pts = String()
        var dots = String()
        for i in range(n):
            var c = counts.get(String(names[si], "|", months[i]), 0)
            var x = left + (pw // 2 if n == 1 else i * pw // (n - 1))
            var y = up + ph - c * ph // top
            pts.write(x, ",", y, " ")
            if c > 0:
                dots.write("<circle cx=", x, " cy=", y, " r=3 fill='", color, "'/>")
        svg.write(
            "<polyline fill=none stroke='", color, "' stroke-width=2 stroke-linejoin=round points='", pts, "'/>", dots,
        )
        legend.write("<li><i style='background:", color, "'></i>", html_escape(names[si]), "</li>")
    svg.write("</svg>")
    legend.write("</ul>")
    return String(
        "<div class=card>", svg, legend,
        "<p class=mute>", note, "</p></div>",
    )


def _migrations_head() -> String:
    """The Migrations page's title and lead, with what a migration is in a popover."""
    return String(
        "<h1>Mojo version migrations</h1><p class=lead>The repos moving to each Mojo version, per month.",
        _help(
            "h-migrations", "migrations",
            "A migration is a repo's lock file (or its manifest, when there's no lock) moving to a"
            " Mojo version between two of its commits. Each number is the repos whose lock file"
            " moved to that version that month. Versions are in Mojo's own order across the"
            " renumbering: pre-1.0 (24.x to 0.26.x, one line), then each 1.x minor.",
        ),
        "</p>",
    )


def _migrations_body(rows: List[VersionMonth]) raises -> String:
    """The Migrations page's HTML for `rows` (at least one), rendered once
    per cache build."""
    var h = String(
        _migrations_head(),
    )
    h.write(_versions_chart(rows))
    var late = List[VersionMonth]()
    var early = List[VersionMonth]()
    for ref r in rows:
        if version_bucket(r.version) == "pre-1.0":
            early.append(r.copy())
        else:
            late.append(r.copy())
    if len(late) > 0:
        h.write("<h2>Mojo 1.x and later</h2>", _versions_table(late))
    if len(early) > 0:
        # Collapsed: the renumbering's old versions are history.
        h.write(
            "<details class=early><summary>Before 1.0 &mdash; ", len(early), " rows</summary>",
            _versions_table(early), "</details>",
        )
    return h^


def _versions_table(rows: List[VersionMonth]) raises -> String:
    """The month, version and repos table for `rows`: the month cell spans its
    rows, and the bars are against this table's busiest row."""
    var per_month = Dict[String, Int]()
    var top = 1
    for ref r in rows:
        per_month[r.month] = per_month.get(r.month, 0) + 1
        if r.repos > top:
            top = r.repos
    var h = String(
        "<div class=tbl><table><thead><tr><th>Month</th><th>Version</th>",
        "<th>Repos migrating</th></tr></thead><tbody>",
    )
    var last_month = String()
    for ref r in rows:
        h.write("<tr>")
        if r.month != last_month:
            last_month = r.month
            h.write(
                "<td class=month rowspan=", per_month[r.month], ">", html_escape(r.month), "</td>"
            )
        h.write(
            "<td class=mono>", html_escape(r.version), "</td><td><div class=bar><span>",
            r.repos, "</span><i style='width:", r.repos * 100 // top,
            "%' aria-hidden=true></i></div></td></tr>",
        )
    h.write("</tbody></table></div>")
    return h^
