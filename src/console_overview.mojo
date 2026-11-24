"""The console's home page (`/`): the headline cards, the repos per Mojo
version as donuts, the growth curves, Rising, Most stars, Most active and Most depended
on."""

from flare.http import Request, Response, html_escape, internal_error, redirect
from morca.civil import now

from charts import compact, compact_bytes, donut, line_chart
from days import day_text
from jscan import micros_to_iso
from listing import ListQuery, list_url, with_category, with_new
from categories import CATEGORIES_VERSION, VOTERS, category_keys, category_title
from model import Stored, stored_total
from overview import (
    ARCHIVE_START,
    RISING_FORK_WEIGHT,
    RISING_USED_BY_WEIGHT,
    Overview,
    archive_days_due,
    bucket_color,
)

from console_cache import Cache, refresh_secs
from console_how import MORCA_UI
from console_layout import _empty, _help, _n, _page, _this_month
from console_pages import page_json, page_line
from console_list import _raw_query


def _signed(v: Int64) -> String:
    """`+1,234` or `-12`, in the colour of its direction."""
    if v > 0:
        return String("<span class=up>+", _n(v), "</span>")
    if v < 0:
        return String("<span class=down>&minus;", _n(-v), "</span>")
    return String("no change")


def _kpi(label: String, value: String, note: String, href: String = "", help: String = "") -> String:
    """One headline card; a link when `href` is given. `note` is HTML; `help`
    a `_help` after the label (not with `href`: no button inside a link)."""
    var inner = String("<b>", label, help, "</b><span>", value, "</span><small>", note, "</small>")
    if href.byte_length() > 0:
        return String("<a class=kpi href='", html_escape(href), "'>", inner, "</a>")
    return String("<div class=kpi>", inner, "</div>")


def _held(st: Stored, noun: String) -> String:
    """`1,234,567 events, 41 GB`."""
    return String(_n(st.records), " ", noun, ", ", compact_bytes(st.bytes))


def _input_kpi(c: Cache) -> String:
    """The Input processed card: what the lake holds now, records and bytes,
    from the tables' snapshot summaries (`model.read_stored`), with GH
    Archive's raw events, its index and the census tables apart in the
    help."""
    ref src = c.sources
    var all = stored_total(src.stored)
    var events = stored_total(src.stored, "gharchive.events")
    var index = Stored("", 0, 0)
    for name in ["gharchive.candidates", "gharchive.repo_hour", "gharchive.releases"]:
        var st = stored_total(src.stored, name)
        index.records += st.records
        index.bytes += st.bytes
    var census = stored_total(src.stored, "mojo.")
    var commits = stored_total(src.stored, "mojo.commits")
    var note = String("nothing loaded yet")
    if all.records > 0 or src.days > 0:
        note = String(
            compact(all.records), " records in ", len(src.stored), " table" if len(src.stored) == 1 else " tables",
            ", from ", _n(Int64(src.days)), " day" if src.days == 1 else " days", " of GH Archive and ",
            _n(Int64(c.ov.with_history)), " git history" if c.ov.with_history == 1 else " git histories",
        )
    var events_line = String(
        "not kept for any day loaded so far" if events.records == 0
        else String(_held(events, "events"), ", the ", _n(Int64(src.event_days)), " days loaded with them kept")
    )
    return _kpi(
        "Input processed", compact_bytes(all.bytes), note,
        help=_help(
            "h-kpi-input", "Input processed",
            String(
                "What the lake holds now: the rows of its tables and the size of their Parquet data files",
                " (zstd), by each table's current snapshot (Iceberg's <em>total-records</em> and",
                " <em>total-files-size</em>). GH Archive's raw events (gharchive.events): ", events_line,
                ". Its index, the candidates, repo-hours and releases of every day loaded",
                " (gharchive.candidates, repo_hour, releases): ", _held(index, "rows"),
                ". The census's tables (mojo.*), read from the repos' git histories and GitHub: ",
                _held(census, "rows"), ", of them ", _n(commits.records), " commits.",
                " Not recorded: the bytes downloaded from GH Archive (one .json.gz file an hour),",
                " and the events of the days whose raw events aren't kept.",
            ),
        ),
    )


def _pct(part: Int, whole: Int) -> String:
    """`37%`, or `37.5%` below ten; `0%` for no whole."""
    if whole <= 0:
        return String("0%")
    var tenths = part * 1000 // whole
    if tenths >= 100 or tenths % 10 == 0:
        return String(tenths // 10, "%")
    return String(tenths // 10, ".", tenths % 10, "%")


def _categories_card(c: Cache) -> String:
    """Repos per category (`categories.categorize`), each linking to them;
    nothing before mojo_embed has run."""
    if c.embed_snapshot < 0 or len(c.categories) != len(c.libs):
        return String()
    var per = Dict[String, Int]()
    for ref k in c.categories:
        if k.byte_length() > 0:
            per[k] = per.get(k, 0) + 1
    var total = 0
    for e in per.items():
        total += e.value
    if total == 0:
        return String()
    var any = ListQuery(String("lines"), False, String(), False, String(), False, String())
    var h = String(
        "<h2>Repos by category",
        _help(
            "h-categories", "Repos by category",
            String(
                "Approximate. A repo with no description is Other; one whose description says"
                " bindings for or a port of a library goes by that; the rest go by the ", VOTERS,
                " nearest of 72 hand-labelled repos, by the embeddings of their descriptions"
                " (categories v", CATEGORIES_VERSION, "). About 4 in 5 agree with a hand label.",
            ),
        ),
        "</h2><div class=tbl><table><thead><tr><th>Category</th><th class=num>Repos</th>",
        "<th class=num>Share</th></tr></thead><tbody>",
    )
    for ref k in category_keys():
        var n = per.get(k, 0)
        if n == 0:
            continue
        h.write(
            "<tr><td><a href='", html_escape(list_url(with_category(any, k))), "'>",
            html_escape(category_title(k)), "</a></td><td class=num>", _n(Int64(n)),
            "</td><td class=num>", _pct(n, total), "</td></tr>",
        )
    h.write("</tbody></table></div>")
    return h^


def _family_url(f: String, active: Bool, estimate: Bool = False) -> String:
    return list_url(ListQuery(String("lines"), False, f, active, String(), estimate, String()))


def _family_donut(c: Cache, active: Bool, estimate: Bool = False) -> String:
    """A donut of the repos per Mojo version family (the ones active in the
    last year when `active`), each slice a link to the filtered Repos table,
    and a legend with the numbers."""
    ref ov = c.ov
    var labels = List[String]()
    var values = List[Int]()
    var colors = List[String]()
    var hrefs = List[String]()
    var total = 0
    var names = ov.est_buckets.copy() if estimate else ov.buckets.copy()
    var counts = List[Int]()
    for n in range(len(names)):
        if estimate:
            counts.append(ov.est_bucket_active[n] if active else ov.est_bucket_repos[n])
        else:
            counts.append(ov.bucket_active[n] if active else ov.bucket_repos[n])
    for i in range(len(names)):
        var n = counts[i]
        total += n
        labels.append(names[i])
        values.append(n)
        colors.append(bucket_color(names[i]))
        hrefs.append(_family_url(names[i], active, estimate))
    var what = String("active in the last year") if active else String("all")
    var svg = donut(
        labels, values, colors, hrefs, String(total), String("repos"),
        String("Donut chart: ", total, " repos (", what, ") by Mojo version"),
    )
    var legend = String("<ul class=legend>")
    for i in range(len(labels)):
        if values[i] == 0:
            continue
        legend.write(
            "<li><a href='", html_escape(hrefs[i]), "'><i class=sw style='background:", colors[i],
            "'></i>", html_escape(labels[i]),
            "<sup class=mark title='see the note under the charts'>*</sup>" if _no_version(labels[i]) else "",
            " <b>", values[i], "</b> <span class=mute>",
            _pct(values[i], total), "</span></a></li>",
        )
    legend.write("</ul>")
    return String(
        "<div class=card><h3>", "Active in the last year" if active else "All repos", "</h3>", svg, legend, "</div>"
    )


def _no_version(bucket: String) -> Bool:
    """The buckets of repos with no version, starred in the legends."""
    return bucket == "unknown" or bucket == "no-manifest"


def _count_of(names: List[String], counts: List[Int], name: String) -> Int:
    for i in range(len(names)):
        if names[i] == name:
            return counts[i]
    return 0


def _and(parts: List[String]) -> String:
    """`a`, `a and b`, `a, b and c`."""
    var out = String()
    for i in range(len(parts)):
        if i > 0:
            out += " and " if i == len(parts) - 1 else ", "
        out += parts[i]
    return out^


def versions_note(ov: Overview, estimate: Bool) -> String:
    """The footnote under the version donuts: what the starred `unknown` and
    `no-manifest` slices of all repos are made of, that the census is still
    reading the histories (while some aren't read), and the link to the
    estimate. Empty when every repo has a version."""
    ref names = ov.est_buckets if estimate else ov.buckets
    ref counts = ov.est_bucket_repos if estimate else ov.bucket_repos
    var unknown = _count_of(names, counts, "unknown")
    var none = _count_of(names, counts, "no-manifest")
    var unread = ov.est_unread if estimate else ov.unread
    var named_none = unknown - unread
    if unknown + none == 0:
        return String()
    # The first number names its noun: "540 repos don't ..., 36 have ...".
    var first = unread if unread > 0 else (named_none if named_none > 0 else none)
    var noun = String(" repo" if first == 1 else " repos")
    var unk = List[String]()
    if unread > 0:
        unk.append(
            String(_n(Int64(unread)), noun, " doesn't" if unread == 1 else " don't", " have their history read yet")
        )
        noun = String()
    if named_none > 0:
        unk.append(
            String(_n(Int64(named_none)), noun, " has" if named_none == 1 else " have", " a manifest that names no Mojo version")
        )
        noun = String()
    var parts = List[String]()
    if len(unk) > 0:
        parts.append(String(_and(unk), " (<em>unknown</em>)"))
    if none > 0:
        parts.append(
            String(
                _n(Int64(none)), noun, " states" if none == 1 else " state",
                " no version anywhere the census looks (<em>no-manifest</em>)",
            )
        )
    var h = String("<p class='mute note'>* ")
    if estimate:
        h += "With no estimate by date either, "
    if len(parts) == 2:
        h.write(parts[0], ", and ", parts[1], ".")
    else:
        h.write(parts[0], ".")
    if unread > 0:
        h.write(
            " The census is still reading them: ", _n(Int64(ov.with_history)), " of ",
            _n(Int64(ov.repos)), " histories read.",
        )
    if not estimate:
        var est_left = _count_of(ov.est_buckets, ov.est_bucket_repos, "unknown") + _count_of(
            ov.est_buckets, ov.est_bucket_repos, "no-manifest"
        )
        var filled = unknown + none - est_left
        if filled > 0:
            h.write(
                " <a href='/?estimate=1'>Add the estimate by date</a> to fill in ",
                "all of them" if est_left == 0 else String(_n(Int64(filled)), " of them"), ".",
            )
    h += "</p>"
    return h^


def _legend(names: List[String], colors: List[String], values: List[String]) -> String:
    var h = String("<ul class=legend>")
    for i in range(len(names)):
        h.write(
            "<li><i style='background:", colors[i], "'></i>", html_escape(names[i]), " <b>",
            values[i], "</b></li>",
        )
    h.write("</ul>")
    return h^


def _curve_card(
    title: String,
    months: List[String],
    names: List[String],
    series: List[List[Int64]],
    colors: List[String],
    percent: Bool,
    note: String,
    area: Bool = False,
) -> String:
    var last = months[len(months) - 1]
    var aria = String("Line chart: ", title, ", ", months[0], " to ", last)
    var now_vals = List[String]()
    for ref s in series:
        now_vals.append(String(s[len(s) - 1], "%") if percent else _n(s[len(s) - 1]))
    var svg = line_chart(months, names, series, colors, percent, aria, area)
    # The class lets the chart's text be sized for small screens.
    svg = svg.replace("<svg viewBox", "<svg class=lc viewBox", )
    var id = String("h-", title.lower().replace(" ", "-"))
    return String(
        "<div class=card><h3>", html_escape(title), _help(id, title, note), "</h3>", svg,
        _legend(names, colors, now_vals), "</div>",
    )


def _issues_card(ov: Overview, months: List[String]) -> String:
    """Issues opened and closed and pull requests opened and merged per
    month, over `months` (the commits card's, which end with the last full
    month); "" before mojo.issues has rows."""
    var n = len(months)
    if len(ov.issues_opened) < n or n < 2:
        return String()
    var total = Int64(0)
    for k in range(n):
        total += ov.issues_opened[k] + ov.prs_opened[k]
    if total == 0:
        return String()
    var names: List[String] = ["Issues opened", "Issues closed", "PRs opened", "PRs merged"]
    var colors: List[String] = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)"]
    var series = List[List[Int64]]()
    for src in [ov.issues_opened.copy(), ov.issues_closed.copy(), ov.prs_opened.copy(), ov.prs_merged.copy()]:
        var s = List[Int64]()
        for k in range(n):
            s.append(src[k])
        series.append(s^)
    return _curve_card(
        "Issues and PRs per month", months, names, series, colors, False,
        "From GitHub's issues list of each census repo (mojo.issues), to the last full month."
        " A repo counts once mojo_issues has read it.",
    )


def _as_of(ms: Int64) -> String:
    """`2026-11-05 03:12 UTC` for a time in milliseconds."""
    var iso = micros_to_iso(ms * 1000)
    return String(iso[byte=:10], " ", iso[byte=11:16], " UTC")


def _span(secs: Int) -> String:
    """`45 s`, `12 min`, `3 h 5 min`."""
    if secs < 90:
        return String(max(secs, 0), " s")
    var mins = (secs + 30) // 60
    if mins < 120:
        return String(mins, " min")
    return String(mins // 60, " h ", mins % 60, " min") if mins % 60 > 0 else String(mins // 60, " h")


comptime HISTORY_KEYS = MORCA_UI + "/pipelines/mojo_history"
"""mojo_history's keys on morca: which repos' histories are read."""
comptime ARCHIVE_COVERAGE = MORCA_UI + "/pipelines/gharchive?tab=operate&cov=year#coverage"
"""gharchive's coverage calendar on morca, by year: which days are loaded."""


def overview(req: Request, c: Cache) raises -> Response:
    if _raw_query(req).byte_length() > 0 and (
        req.query_param("sort").byte_length() > 0
        or req.query_param("dir").byte_length() > 0
        or req.query_param("version").byte_length() > 0
        or req.query_param("active").byte_length() > 0
        or req.query_param("new").byte_length() > 0
    ):
        # The Repos table used to be the home page: keep its links working.
        return redirect(String("/repos?", _raw_query(req)), 301)
    try:
        ref ov = c.ov
        var estimate = req.query_param("estimate") == "1"
        var h = String(
            "<h1>Mojourney: the Mojo ecosystem census</h1><p class=lead>How the Mojo language is being used on GitHub:",
            " the repos that contain Mojo, found in GH Archive, with their whole git history",
            " read. An independent project, not affiliated with Modular.</p>",
        )
        if ov.repos == 0:
            h.write(
                _empty(
                    "No repos yet",
                    "The lake is still filling. The pipelines read GH Archive an hour at a"
                    " time, so this page fills in as they catch up.",
                )
            )
            h.write("<div class=kpis>", _input_kpi(c), "</div>")
            return _page("", h^, "overview", description=page_line("/"), alternate=page_json("/"))
        var dc = ov.commits_30 - ov.commits_prev_30
        # Coverage: the repos whose history is read, and the GH Archive days
        # loaded since ARCHIVE_START; most numbers below rest on one of them.
        var due = archive_days_due(c.built_day)
        var got = min(c.sources.archive_days, due)
        var hist_of = String(_n(Int64(ov.with_history)), " of ", _n(Int64(ov.repos)), " repos")
        var hist_pct = _pct(ov.with_history, ov.repos)
        var days_of = String(_n(Int64(got)), " of ", _n(Int64(due)), " days")
        var days_pct = _pct(got, due)
        var hist_a = String("<a href='", html_escape(HISTORY_KEYS), "' rel=noopener>")
        var days_a = String("<a href='", html_escape(ARCHIVE_COVERAGE), "' rel=noopener>")
        var hist_help = String(
            "Partial coverage: counted over the ", _n(Int64(ov.with_history)),
            " repos whose git history is read, ", hist_pct, " of the ", _n(Int64(ov.repos)),
            " found so far. ", hist_a, "mojo_history's keys</a> show which are read.",
        )
        h.write(
            "<p class=cov><b>Coverage:</b> git histories read for ", hist_a, hist_of, "</a> (", hist_pct,
            "); GH Archive loaded for ", days_a, days_of, "</a> since <span class=nw>", day_text(Int64(ARCHIVE_START)),
            "</span> (", days_pct, "). Numbers that rest on either are partial and grow as the pipelines catch up.</p>",
            "<div class=kpis>",
            _kpi(
                "Repos", String("<a href='/repos'>", _n(Int64(ov.repos)), "</a>"),
                String(
                    "<a href='", html_escape(list_url(with_new(ListQuery(String("lines"), False, String(), False, String(), False, String()), String("30d")))), "'>",
                    _signed(Int64(ov.with_history - ov.repos_30_ago)), " in 30 days</a> of the ",
                    _n(Int64(ov.with_history)), " with history",
                ),
                help=_help(
                    "h-kpi-repos", "Repos",
                    String(
                        "Partial coverage: repos are found in the GH Archive days loaded so far, ", days_of,
                        " (", days_pct, "), so the total is a lower bound (", days_a, "coverage calendar</a>).",
                        " The change in 30 days is by first Mojo commit, so it counts only the ",
                        _n(Int64(ov.with_history)), " repos whose git history is read (", hist_pct, "; ",
                        hist_a, "mojo_history's keys</a>).",
                    ),
                ),
            ),
            _kpi(
                "Commits", _n(Int64(ov.commits)),
                String("in the ", _n(Int64(ov.with_history)), " repos whose history is read"),
                help=_help("h-kpi-commits", "Commits", hist_help),
            ),
            _kpi(
                "Lines of Mojo",
                String(
                    "<a href='", html_escape(list_url(ListQuery(String("lines"), False, String(), False, String(), False, String()))),
                    "'>", compact(ov.lines), "</a>",
                ),
                String(_signed(ov.lines - ov.lines_30_ago), " in 30 days"),
                help=_help("h-kpi-lines", "Lines of Mojo", hist_help),
            ),
            _kpi(
                "Active repos", String("<a href='/repos?active=1y'>", _n(Int64(ov.active)), "</a>"),
                String(
                    "a commit in the last year: ", _pct(ov.active, ov.with_history), " of the ",
                    _n(Int64(ov.with_history)), " repos whose history is read",
                ),
                help=_help("h-kpi-active", "Active repos", hist_help),
            ),
            _kpi(
                "Commits, 30 days", _n(Int64(ov.commits_30)),
                String(_signed(Int64(dc)), " vs the 30 days before"),
                help=_help("h-kpi-commits30", "Commits, 30 days", hist_help),
            ),
            _kpi(
                "New repos this month",
                String("<a href='/repos?new=month'>", _n(Int64(ov.new_this_month)), "</a>"),
                String(
                    "<a href='/repos?new=last-month'>", ov.new_last_month,
                    " last month</a> (first Mojo commit)",
                ),
                help=_help("h-kpi-new", "New repos this month", hist_help),
            ),
            _input_kpi(c),
            "</div>",
        )
        # Repos per Mojo version family.
        h.write(
            "<h2>Repos by Mojo version",
            _help(
                "h-versions", "Repos by Mojo version",
                "The version a repo states: its latest lock file or manifest, else its CI, Docker or"
                " README files. <em>no-manifest</em> is a repo with nothing there to read (mostly"
                " early projects from before magic and pixi); <em>unknown</em> has a manifest that"
                " names no Mojo version, or its history isn't read yet. The note under the charts"
                " (<em>*</em>) counts each. Click a slice for its repos.",
            ),
            "</h2><p class=sub>Counting <strong>", "detected and estimated versions" if estimate else "detected versions only",
            "</strong>. <a href='", "/" if estimate else "/?estimate=1", "'>",
            "Show detected only" if estimate else "Add an estimate by date for repos with no version",
            "</a>",
            _help(
                "h-estimate", "the estimate by date",
                "The estimate is the Mojo release current at the repo's last Mojo commit: a guess,"
                " not a detection. It fills in only repos with no detected version.",
            ),
            "</p>",
            "<div class=cols>", _family_donut(c, False, estimate), _family_donut(c, True, estimate), "</div>",
            versions_note(ov, estimate),
            _categories_card(c),
        )
        # Growth.
        if len(ov.months) >= 2:
            var m = ov.months.copy()
            var single_color: List[String] = ["var(--ember)"]
            var lines_names: List[String] = ["Lines of Mojo"]
            var lines_series = List[List[Int64]]()
            lines_series.append(ov.lines_series.copy())
            var repos_names: List[String] = ["Repos"]
            var repos_series = List[List[Int64]]()
            repos_series.append(ov.repos_series.copy())
            var commits_names: List[String] = ["Commits"]
            var commits_series = List[List[Int64]]()
            commits_series.append(ov.commits_series.copy())
            # Commits per month ends with the last full month.
            var cm = m.copy()
            if len(cm) > 2 and cm[len(cm) - 1] == _this_month():
                _ = cm.pop()
                _ = commits_series[0].pop()
            var issues_card = _issues_card(ov, cm)
            h.write(
                "<h2>Growth",
                _help(
                    "h-growth", "Growth",
                    "Monthly, from each repo's full git history, so the curves reach back before"
                    " the census found the repos.",
                ),
                "</h2><div class=cols>",
                _curve_card(
                    "Lines of Mojo", m, lines_names, lines_series, single_color, False,
                    "Lines of Mojo at the end of each month, summed over every repo.", True,
                ),
                _curve_card(
                    "Repos", m, repos_names, repos_series, single_color, False,
                    "A repo counts from its first Mojo commit.", True,
                ),
                _curve_card(
                    "Commits per month", cm, commits_names, commits_series, single_color, False,
                    "Commits in the repos' first-parent histories, to the last full month.", True,
                ),
                issues_card,
            )
            # Tooling share, in percent of the repos that exist that month.
            var none = List[Int64]()
            var magic = List[Int64]()
            var pixi = List[Int64]()
            var bazel = List[Int64]()
            var python = List[Int64]()
            for k in range(len(m)):
                var tot = (
                    ov.tool_none[k] + ov.tool_magic[k] + ov.tool_pixi[k]
                    + ov.tool_bazel[k] + ov.tool_python[k]
                )
                var t = tot if tot > 0 else Int64(1)
                none.append(ov.tool_none[k] * 100 // t)
                magic.append(ov.tool_magic[k] * 100 // t)
                pixi.append(ov.tool_pixi[k] * 100 // t)
                bazel.append(ov.tool_bazel[k] * 100 // t)
                python.append(ov.tool_python[k] * 100 // t)
            var tool_names: List[String] = ["none", "magic", "pixi", "bazel", "python"]
            var tool_colors: List[String] = ["var(--c5)", "var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)"]
            var tool_series = List[List[Int64]]()
            tool_series.append(none^)
            tool_series.append(magic^)
            tool_series.append(pixi^)
            tool_series.append(bazel^)
            tool_series.append(python^)
            h.write(
                _curve_card(
                    "Tooling", m, tool_names, tool_series, tool_colors, True,
                    String(
                        "Share of repos by how they manage Mojo: no lock file or manifest, magic, pixi,",
                        " bazel, or python (Mojo from PyPI with uv, poetry, pdm or pip).",
                    ),
                ),
                "</div>",
            )
        # Rising and the most active repos, side by side.
        h.write("<div class=cols><div>")
        h.write(
            "<h2>Rising",
            _help(
                "h-rising", "Rising",
                String(
                    "The repos with the highest score over the last 30 days: the stars and forks they",
                    " gained (GH Archive's WatchEvents and ForkEvents on the days loaded so far) and the",
                    " census repos that depend on them. Score = stars gained + ", RISING_FORK_WEIGHT,
                    " &times; forks gained + ", RISING_USED_BY_WEIGHT, " &times; repos using it now; a",
                    " repo needs a new star or fork to be ranked. Stars is its total now.",
                    " Partial coverage: GH Archive is loaded for ", days_of, " since ",
                    day_text(Int64(ARCHIVE_START)), " (", days_pct, "), and a day not loaded adds no",
                    " stars or forks (", days_a, "coverage calendar</a>).",
                ),
            ),
            "</h2>",
        )
        if len(c.rising) > 0:
            h.write(
                "<div class=tbl><table><thead><tr>",
                "<th>Repository</th><th class=num>Stars, 30 days</th><th class=num>Stars</th>",
                "<th class=num>Forks, 30 days</th>",
                "<th class=num>Used by</th><th class=num>Score</th></tr></thead><tbody>",
            )
            for i in range(len(c.rising)):
                h.write(
                    "<tr><td><a class=repo href='/repos/", html_escape(c.rising[i]), "'>",
                    html_escape(c.rising[i]), "</a></td><td class=num>", _signed(c.rising_gain[i]),
                    "</td><td class=num>", _n(c.rising_stars[i]),
                    "</td><td class=num>", _signed(c.rising_forks[i]),
                    "</td><td class=num>", _n(c.rising_used_by[i]),
                    "</td><td class=num>", _n(c.rising_score[i]), "</td></tr>",
                )
            h.write("</tbody></table></div>")
        h.write(
            "<h2><a href='",
            html_escape(list_url(ListQuery(String("stars"), False, String(), False, String(), False, String()))),
            "'>Most stars</a>",
            _help(
                "h-stars", "Most stars",
                "The repos with the most GitHub stars now, and the stars they gained in the last 30 days.",
            ),
            "</h2>",
        )
        if len(c.starred) > 0:
            h.write(
                "<div class=tbl><table><thead><tr>",
                "<th>Repository</th><th class=num>Stars</th><th class=num>Stars, 30 days</th>",
                "<th class=num>Forks</th><th class=num>Used by</th></tr></thead><tbody>",
            )
            for i in range(len(c.starred)):
                h.write(
                    "<tr><td><a class=repo href='/repos/", html_escape(c.starred[i]), "'>",
                    html_escape(c.starred[i]), "</a></td><td class=num>", _n(c.starred_stars[i]),
                    "</td><td class=num>", _signed(c.starred_gain[i]),
                    "</td><td class=num>", _n(c.starred_forks[i]),
                    "</td><td class=num>", _n(c.starred_used_by[i]), "</td></tr>",
                )
            h.write("</tbody></table></div>")
        h.write(
            "</div><div><h2><a href='",
            html_escape(list_url(ListQuery(String("commits30"), False, String(), False, String(), False, String()))),
            "'>Most active</a>",
            _help(
                "h-active", "Most active",
                "The repos with the most commits in the last 30 days, and how many lines of Mojo"
                " they grew by.",
            ),
            "</h2>",
        )
        if len(c.active_repos) > 0:
            h.write(
                "<div class=tbl><table><thead><tr><th>Repository</th><th class=num>Commits, 30 days</th>",
                "<th class=num>Lines, 30 days</th></tr></thead><tbody>",
            )
            for i in range(len(c.active_repos)):
                h.write(
                    "<tr><td><a class=repo href='/repos/", html_escape(c.active_repos[i]), "'>",
                    html_escape(c.active_repos[i]), "</a></td><td class=num>", _n(c.active_commits[i]),
                    "</td><td class=num>", _signed(c.active_lines[i]), "</td></tr>",
                )
            h.write("</tbody></table></div>")
        h.write("</div></div>")
        # The libraries the most census repos declare a dependency on.
        if len(c.depended) > 0:
            h.write(
                "<div class=cols><div><h2><a href='",
                html_escape(list_url(ListQuery(String("used_by"), False, String(), False, String(), False, String()))),
                "'>Most depended on</a>",
                _help(
                    "h-depended", "Most depended on",
                    "The repos the most census repos declare a dependency on, in the manifests at"
                    " their HEAD (pixi, magic, pyproject, recipe): by GitHub URL, package name or"
                    " repo name. A dependency is internal when both repos have the same GitHub"
                    " owner; Outside the org counts the rest. When two or more of one owner's repos"
                    " would be listed they are one row, owner/*: Used by counts the distinct repos"
                    " that depend on any of them, and Stars and Forks are their sums.",
                ),
                "</h2>",
                "<div class=tbl><table><thead><tr><th>Repository</th><th class=num>Used by</th>",
                "<th class=num>Outside the org</th>",
                "<th class=num>Stars</th><th class=num>Forks</th></tr></thead><tbody>",
            )
            for ref d in c.depended:
                if d.group:
                    h.write(
                        "<tr><td><a class=repo href='/search?q=", html_escape(d.owner), "'>",
                        html_escape(d.name), "</a> <span class=mute>&middot; ", len(d.members),
                        " repos</span>",
                    )
                else:
                    h.write(
                        "<tr><td><a class=repo href='/repos/", html_escape(d.name), "'>",
                        html_escape(d.name), "</a>",
                    )
                h.write(
                    "</td><td class=num>", _n(d.used_by), "</td><td class=num>", _n(d.used_by - d.internal),
                    "</td><td class=num>", _n(d.stars), "</td><td class=num>", _n(d.forks), "</td></tr>",
                )
            h.write("</tbody></table></div></div></div>")
        # As of.
        h.write(
            "<p class=asof>Data as of ", _as_of(c.sources.as_of_ms), ". Refreshed every ",
            _span(refresh_secs()), "; built ", _span(Int(now() - c.built_at)), " ago.",
        )
        if c.sources.days > 0:
            h.write(
                " GH Archive days loaded: ", c.sources.days, ", ", c.sources.first_day, " to ",
                c.sources.last_day, ".",
            )
        h.write(
            _help(
                "h-asof", "the data",
                String(
                    "As of the latest snapshot of the tables behind this page; every run is on <a href='",
                    MORCA_UI, "/runs' rel=noopener>orca.mojourney.dev/runs</a>. Repos are discovered",
                    " from the GH Archive days loaded so far: a repo is found only when an event of it",
                    " falls on a loaded day, so the repo count is a lower bound.",
                ),
            ),
            "</p>",
        )
        return _page("", h^, "overview", description=page_line("/"), alternate=page_json("/"))
    except e:
        return internal_error(String(e))
