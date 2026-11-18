"""The Overview's numbers over a few in-memory commits, the Repos table's
sorting and filtering, and the charts' text.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from charts import compact, compact_bytes, donut, grid_line, line_chart, nice_ceil
from jscan import days_from_civil
from listing import (
    NEW_30D,
    NEW_LAST_MONTH,
    NEW_MONTH,
    list_url,
    parse_list_query,
    select_repos,
    sorted_by,
    with_version,
)
from overview import (
    ARCHIVE_START,
    DAY_US,
    RISING_FORK_WEIGHT,
    RISING_USED_BY_WEIGHT,
    Builder,
    archive_days_due,
    bucket_color,
    month_label,
    month_of_days,
    rising_score,
    tool_code,
    top_gains,
)


def _us(y: Int, m: Int, d: Int) -> Int64:
    return Int64(days_from_civil(y, m, d)) * DAY_US


def test_archive_days_due() raises:
    # 2023-01-01 to yesterday: none on the first day, 1,407 on 2026-11-08.
    assert_equal(ARCHIVE_START, days_from_civil(2023, 1, 1))
    assert_equal(archive_days_due(ARCHIVE_START), 0)
    assert_equal(archive_days_due(ARCHIVE_START + 1), 1)
    assert_equal(archive_days_due(days_from_civil(2026, 11, 8)), 1407)
    assert_equal(archive_days_due(ARCHIVE_START - 5), 0)


def test_months() raises:
    assert_equal(month_of_days(0), 0)
    assert_equal(month_label(0), "1970-01")
    assert_equal(month_label(month_of_days(days_from_civil(2026, 11, 5))), "2026-11")
    assert_equal(month_label(month_of_days(days_from_civil(2024, 2, 29))), "2024-02")
    assert_equal(month_of_days(days_from_civil(2024, 12, 31)) + 1, month_of_days(days_from_civil(2025, 1, 1)))


def test_tool_code() raises:
    assert_equal(tool_code("magic"), 1)
    assert_equal(tool_code("pixi"), 2)
    assert_equal(tool_code("bazel"), 3)
    assert_equal(tool_code("uv"), 4)
    assert_equal(tool_code("poetry"), 4)
    assert_equal(tool_code("pdm"), 4)
    assert_equal(tool_code("pip"), 4)
    # Not by the first letter any more: `pip` and `poetry` aren't pixi.
    assert_equal(tool_code("pixie"), 0)
    assert_equal(tool_code("none"), 0)
    assert_equal(tool_code(""), 0)


def _small() raises -> Builder:
    """Today is 2026-11-15. `a` has two commits and moves 1.0.0 to 1.1.0,
    `b` is old (2024) with a magic lock then one commit this month, `c` has
    no commits, `d` is stale."""
    var b = Builder(days_from_civil(2026, 11, 15))
    var a = b.add_repo("o/a")
    var bb = b.add_repo("o/b")
    _ = b.add_repo("o/c")
    var d = b.add_repo("o/d")
    # a: Dec 2025 (100 lines, pixi 1.0.0), then 20 Oct 2026 (150 lines, 1.1.0).
    b.add_commit(a, _us(2025, 12, 3), 0, 100, 2, "1.0.0")
    b.add_commit(a, _us(2026, 10, 20), 1, 150, 2, "1.1.0")
    # b: May 2024 (40 lines, magic, 0.26.1), 10 Nov 2026 (60 lines, magic).
    b.add_commit(bb, _us(2024, 5, 2), 0, 40, 1, "0.26.1")
    b.add_commit(bb, _us(2026, 11, 10), 1, 60, 1, "0.26.1")
    # d: one commit in 2023, no version.
    b.add_commit(d, _us(2023, 6, 1), 0, 10, 0, "")
    return b^


def test_totals() raises:
    var ov = _small().finish(4)
    assert_equal(ov.repos, 4)
    assert_equal(ov.with_history, 3)
    assert_equal(ov.commits, 5)
    assert_equal(ov.lines, 150 + 60 + 10)
    # Within 30 days of 2026-11-15 (after 2026-10-16): a's 20 Oct and b's 10 Nov.
    assert_equal(ov.commits_30, 2)
    assert_equal(ov.commits_prev_30, 0)
    # 30 days ago: a had 100 lines (Dec 2025), b 40, d 10.
    assert_equal(ov.lines_30_ago, 150)
    assert_equal(ov.repos_30_ago, 3)
    assert_equal(ov.active, 2)
    assert_equal(ov.new_this_month, 0)
    assert_equal(ov.new_last_month, 0)


def test_buckets() raises:
    var ov = _small().finish(4)
    # a is on 1.1, b on 0.26.x (pre-1.0); d was read and has no manifest, c
    # has no history yet: no-manifest and unknown are different buckets.
    var want: List[String] = ["pre-1.0", "1.1", "no-manifest", "unknown"]
    assert_equal(len(ov.buckets), 4)
    for i in range(4):
        assert_equal(ov.buckets[i], want[i])
    for i in range(4):
        assert_equal(ov.bucket_repos[i], 1)
    # Active: a and b; d's commit is from 2023.
    assert_equal(ov.bucket_active[0], 1)
    assert_equal(ov.bucket_active[1], 1)
    assert_equal(ov.bucket_active[2], 0)
    assert_equal(ov.bucket_active[3], 0)
    # The old families are still counted.
    var fams: List[String] = ["0.26.x", "1.x", "no-manifest", "unknown"]
    for i in range(4):
        assert_equal(ov.families[i], fams[i])
    assert_equal(ov.family_repos[1], 1)


def test_unknown_with_a_manifest() raises:
    # A pixi repo whose manifest names no Mojo version is unknown, not
    # "no manifest".
    var b = Builder(days_from_civil(2026, 11, 15))
    var p = b.add_repo("o/p")
    b.add_commit(p, _us(2026, 10, 1), 0, 10, 2, "")
    var ov = b.finish(1)
    assert_equal(len(ov.buckets), 1)
    assert_equal(ov.buckets[0], "unknown")


def test_unread() raises:
    # unknown splits into not read yet (c) and read with a manifest that
    # names no version (p); a version from the files at HEAD isn't unread.
    var b = _small()
    var p = b.add_repo("o/p")
    b.add_commit(p, _us(2026, 10, 1), 0, 10, 2, "")
    var h = b.add_repo("o/h")
    b.set_version(h, "1.1.0", "")
    var ov = b.finish(6)
    assert_equal(ov.unread, 1)
    assert_equal(ov.buckets[len(ov.buckets) - 1], "unknown")
    assert_equal(ov.bucket_repos[len(ov.buckets) - 1], 2)
    assert_equal(ov.est_unread, 1)
    # An estimate for an unread repo takes it out of est_unread only.
    var e = _small()
    e.set_version(2, "", "0.4")
    var eo = e.finish(4)
    assert_equal(eo.unread, 1)
    assert_equal(eo.est_unread, 0)


def test_estimate_buckets() raises:
    var b = _small()
    # d (no manifest, 2023) gets an estimate; b's detected version stays.
    b.set_version(3, "", "0.4")
    b.set_version(1, "0.26.1", "0.26.2")
    var ov = b.finish(4)
    # Detected only: as before.
    assert_equal(len(ov.buckets), 4)
    assert_equal(ov.buckets[2], "no-manifest")
    # With the estimate d is pre-1.0 beside b; c has nothing to estimate.
    var want: List[String] = ["pre-1.0", "1.1", "unknown"]
    assert_equal(len(ov.est_buckets), 3)
    for i in range(3):
        assert_equal(ov.est_buckets[i], want[i])
    assert_equal(ov.est_bucket_repos[0], 2)
    assert_equal(ov.est_bucket_repos[1], 1)
    assert_equal(ov.est_bucket_repos[2], 1)
    var total = 0
    for n in ov.est_bucket_repos:
        total += n
    assert_equal(total, 4)


def test_bucket_colors() raises:
    assert_equal(bucket_color("pre-1.0"), "var(--c0)")
    assert_equal(bucket_color("1.0"), "var(--c1)")
    assert_equal(bucket_color("1.3"), "var(--c4)")
    assert_equal(bucket_color("1.4"), "var(--c6)")
    assert_equal(bucket_color("1.7"), "var(--c9)")
    assert_equal(bucket_color("1.8"), "var(--c1)")
    assert_equal(bucket_color("other"), "var(--c5)")
    assert_true(bucket_color("unknown") != bucket_color("other"))
    assert_true(bucket_color("no-manifest") != bucket_color("unknown"))
    # Distinct minors get distinct colours until the palette wraps.
    for i in range(7):
        assert_true(bucket_color(String("1.", i)) != bucket_color(String("1.", i + 1)))


def test_listing_query() raises:
    var nq = parse_list_query("commits30", "", "", "", "30d")
    assert_equal(nq.sort, "commits30")
    assert_equal(nq.new, "30d")
    assert_equal(list_url(nq), "/repos?sort=commits30&new=30d")
    assert_equal(parse_list_query("", "", "", "", "yesterday").new, "")

    var q = parse_list_query("stars", "asc", "1.x", "1y")
    assert_equal(q.sort, "stars")
    assert_true(q.asc)
    assert_equal(q.version, "1.x")
    assert_true(q.active)
    assert_equal(list_url(q), "/repos?sort=stars&dir=asc&version=1.x&active=1y")
    var d = parse_list_query("", "", "", "")
    assert_equal(list_url(d), "/repos")
    assert_true(d.is_default_order())
    assert_true(not d.has_filter())
    # Unknown values are the defaults.
    var bad = parse_list_query("nonsense", "up", "", "forever")
    assert_equal(list_url(bad), "/repos")
    # A header click: the same column flips, another starts largest first.
    assert_equal(list_url(sorted_by(d, "lines")), "/repos?dir=asc")
    assert_equal(list_url(sorted_by(d, "stars")), "/repos?sort=stars")
    assert_equal(list_url(sorted_by(sorted_by(d, "stars"), "stars")), "/repos?sort=stars&dir=asc")
    assert_equal(list_url(with_version(q, "")), "/repos?sort=stars&dir=asc&active=1y")


def test_listing_buckets_and_estimate() raises:
    # `?version=` takes the new buckets; `estimate=1` is carried by the URL.
    var lines: List[Int64] = [900, 500, 100, 50]
    var files: List[Int64] = [1, 1, 1, 1]
    var stars: List[Int64] = [0, 0, 0, 0]
    var buckets: List[String] = ["1.1", "no-manifest", "no-manifest", "unknown"]
    var active: List[Bool] = [True, True, False, False]
    var nm = select_repos(parse_list_query("", "", "no-manifest", ""), lines, files, stars, buckets, active)
    assert_equal(len(nm), 2)
    var un = select_repos(parse_list_query("", "", "unknown", ""), lines, files, stars, buckets, active)
    assert_equal(len(un), 1)
    assert_equal(un[0], 3)
    var q = parse_list_query("", "", "pre-1.0", "", "", "1")
    assert_true(q.estimate)
    assert_equal(list_url(q), "/repos?version=pre-1.0&estimate=1")
    assert_equal(list_url(with_version(q, "")), "/repos?estimate=1")
    assert_equal(list_url(sorted_by(q, "stars")), "/repos?sort=stars&version=pre-1.0&estimate=1")
    assert_true(not parse_list_query("", "", "", "", "", "").estimate)
    assert_true(not parse_list_query("", "", "", "", "", "yes").estimate)


def test_select_new_and_commits30() raises:
    var lines: List[Int64] = [900, 500, 100]
    var files: List[Int64] = [1, 1, 1]
    var stars: List[Int64] = [0, 0, 0]
    var buckets: List[String] = ["1.2", "pre-1.0", "1.2"]
    var legacy: List[String] = ["1.x", "0.26.x", "1.x"]
    var active: List[Bool] = [True, True, True]
    var news: List[Int] = [NEW_MONTH | NEW_30D, NEW_LAST_MONTH, 0]
    var c30: List[Int64] = [3, 9, 5]
    var month = select_repos(parse_list_query("", "", "", "", "month"), lines, files, stars, buckets, active, legacy, news, c30)
    assert_equal(len(month), 1)
    assert_equal(month[0], 0)
    var last = select_repos(parse_list_query("", "", "", "", "last-month"), lines, files, stars, buckets, active, legacy, news, c30)
    assert_equal(len(last), 1)
    assert_equal(last[0], 1)
    assert_equal(len(select_repos(parse_list_query("", "", "", "", "30d"), lines, files, stars, buckets, active, legacy, news, c30)), 1)
    # Combined with the version filters, new and old.
    assert_equal(len(select_repos(parse_list_query("", "", "pre-1.0", "", "month"), lines, files, stars, buckets, active, legacy, news, c30)), 0)
    assert_equal(len(select_repos(parse_list_query("", "", "0.26.x", "", "last-month"), lines, files, stars, buckets, active, legacy, news, c30)), 1)
    assert_equal(len(select_repos(parse_list_query("", "", "1.x", "", ""), lines, files, stars, buckets, active, legacy, news, c30)), 2)
    var by = select_repos(parse_list_query("commits30", "", "", ""), lines, files, stars, buckets, active, legacy, news, c30)
    var want: List[Int] = [1, 2, 0]
    for i in range(3):
        assert_equal(by[i], want[i])


def test_select() raises:
    # Five repos in the default order (lines descending).
    var lines: List[Int64] = [900, 500, 500, 100, 50]
    var files: List[Int64] = [9, 20, 5, 1, 1]
    var stars: List[Int64] = [3, 40, 40, 0, 7]
    var fams: List[String] = ["1.x", "0.26.x", "1.x", "unknown", "1.x"]
    var active: List[Bool] = [True, True, False, False, True]
    var d = parse_list_query("", "", "", "")
    var all = select_repos(d, lines, files, stars, fams, active)
    assert_equal(len(all), 5)
    for i in range(5):
        assert_equal(all[i], i)
    var by_stars = select_repos(parse_list_query("stars", "", "", ""), lines, files, stars, fams, active)
    var want: List[Int] = [1, 2, 4, 0, 3]  # the 40-star tie keeps its order
    for i in range(5):
        assert_equal(by_stars[i], want[i])
    var by_files_asc = select_repos(parse_list_query("files", "asc", "", ""), lines, files, stars, fams, active)
    var want2: List[Int] = [3, 4, 2, 0, 1]
    for i in range(5):
        assert_equal(by_files_asc[i], want2[i])
    var lines_asc = select_repos(parse_list_query("lines", "asc", "", ""), lines, files, stars, fams, active)
    var want3: List[Int] = [4, 3, 1, 2, 0]
    for i in range(5):
        assert_equal(lines_asc[i], want3[i])
    var v1 = select_repos(parse_list_query("", "", "1.x", ""), lines, files, stars, fams, active)
    assert_equal(len(v1), 3)
    assert_equal(v1[0], 0)
    assert_equal(v1[2], 4)
    var both = select_repos(parse_list_query("stars", "", "1.x", "1y"), lines, files, stars, fams, active)
    assert_equal(len(both), 2)
    assert_equal(both[0], 4)
    assert_equal(both[1], 0)
    var unknown = select_repos(parse_list_query("", "", "unknown", ""), lines, files, stars, fams, active)
    assert_equal(len(unknown), 1)
    assert_equal(unknown[0], 3)
    assert_equal(len(select_repos(parse_list_query("", "", "9.x", ""), lines, files, stars, fams, active)), 0)
    # Forks and used-by sort when their arrays are given.
    var forks: List[Int64] = [1, 0, 5, 2, 0]
    var used: List[Int64] = [0, 3, 0, 1, 3]
    var no30 = List[Int64]()
    var by_forks = select_repos(parse_list_query("forks", "", "", ""), lines, files, stars, fams, active, List[String](), List[Int](), no30, forks, used)
    var want4: List[Int] = [2, 3, 0, 1, 4]
    for i in range(5):
        assert_equal(by_forks[i], want4[i])
    var by_used = select_repos(parse_list_query("used_by", "", "", ""), lines, files, stars, fams, active, List[String](), List[Int](), no30, forks, used)
    var want5: List[Int] = [1, 4, 3, 0, 2]
    for i in range(5):
        assert_equal(by_used[i], want5[i])


def test_rising_score() raises:
    assert_equal(rising_score(10, 0, 0), 10)
    assert_equal(rising_score(10, 2, 1), 10 + 2 * RISING_FORK_WEIGHT + RISING_USED_BY_WEIGHT)
    # Used by alone doesn't make a repo rise.
    assert_equal(rising_score(0, 0, 40), 0)
    assert_equal(rising_score(0, 1, 0), RISING_FORK_WEIGHT)
    var scores: List[Int64] = [rising_score(30, 0, 0), rising_score(20, 2, 2), rising_score(0, 0, 9)]
    var top = top_gains(scores, 10)
    assert_equal(len(top), 2)
    assert_equal(top[0], 1)  # 20 + 6 + 10 beats 30


def test_compact() raises:
    assert_equal(compact(0), "0")
    assert_equal(compact(950), "950")
    assert_equal(compact(1000), "1k")
    assert_equal(compact(1234), "1.2k")
    assert_equal(compact(15_000), "15k")
    assert_equal(compact(8_365_141), "8.3M")
    assert_equal(compact(2_000_000), "2M")
    assert_equal(compact(999_999_999), "999M")
    assert_equal(compact(4_123_456_789), "4.1B")
    assert_equal(compact(-1500), "-1.5k")
    assert_equal(compact_bytes(0), "0 B")
    assert_equal(compact_bytes(999), "999 B")
    assert_equal(compact_bytes(1000), "1 kB")
    assert_equal(compact_bytes(1_234_567), "1.2 MB")
    assert_equal(compact_bytes(41_700_000_000), "41 GB")
    assert_equal(compact_bytes(1_100_000_000_000), "1.1 TB")
    assert_equal(compact_bytes(12_000_000_000_000_000), "12 PB")
    assert_equal(compact_bytes(1_200_000_000_000_000_000), "1200 PB")
    assert_equal(nice_ceil(1), 1)
    assert_equal(nice_ceil(7), 10)
    assert_equal(nice_ceil(130), 200)
    assert_equal(nice_ceil(8_365_141), 10_000_000)
    assert_equal(nice_ceil(2000), 2000)


def _closes_cleanly(svg: String) -> Bool:
    """Whether every `/>` follows a quote or a space. In HTML an unquoted
    attribute value takes the `/` (`y2=202/>` is `y2="202/"`), so the element
    stays open and the browser hides every later mark inside it."""
    var b = svg.as_bytes()
    for i in range(1, len(b) - 1):
        if Int(b[i]) == ord("/") and Int(b[i + 1]) == ord(">"):
            var p = Int(b[i - 1])
            if p != ord("'") and p != ord('"') and p != ord(" "):
                return False
    return True


def test_svg_elements_close() raises:
    assert_true(_closes_cleanly(grid_line(46, 550, 202)))
    assert_true(not _closes_cleanly("<line y2=202/><polyline/>"))
    var months: List[String] = ["2025-01", "2025-02"]
    var names: List[String] = ["a", "b"]
    var series = List[List[Int64]]()
    series.append([1, 5])
    series.append([2, 3])
    var cs: List[String] = ["var(--c0)", "var(--c1)"]
    assert_true(_closes_cleanly(line_chart(months, names, series, cs, False, "x", True)))
    assert_true(_closes_cleanly(line_chart(months, names, series, cs, True, "x")))
    var labels: List[String] = ["1.x", "unknown"]
    var values: List[Int] = [3, 0]
    var hrefs: List[String] = ["/a", "/b"]
    assert_true(_closes_cleanly(donut(labels, values, cs, hrefs, "3", "repos", "d")))
    var none: List[Int] = [0, 0]
    assert_true(_closes_cleanly(donut(labels, none, cs, hrefs, "0", "repos", "d")))


def test_donut_and_line() raises:
    var labels: List[String] = ["1.x", "unknown"]
    var values: List[Int] = [3, 1]
    var colors: List[String] = ["var(--c4)", "var(--border-strong)"]
    var hrefs: List[String] = ["/repos?version=1.x", "/repos?version=unknown"]
    var svg = donut(labels, values, colors, hrefs, "4", "repos", "Donut chart: 4 repos")
    assert_true("viewBox='0 0 200 200'" in svg)
    assert_true("<title>Donut chart: 4 repos</title>" in svg)
    assert_true("href='/repos?version=unknown'" in svg)
    assert_true("1.x: 3 of 4" in svg)
    # 75% of the circumference of r=70 is 329.87.
    assert_true("stroke-dasharray='329.87 109.96'" in svg)
    var months: List[String] = ["2025-01", "2025-02", "2025-03"]
    var names: List[String] = ["repos"]
    var series = List[List[Int64]]()
    series.append([1, 5, 8])
    var cs: List[String] = ["var(--ember)"]
    var line = line_chart(months, names, series, cs, False, "Line chart: repos", True)
    assert_true("role=img" in line)
    assert_true("<polyline" in line)
    assert_true("<polygon" in line)
    assert_true(">10</text>" in line)
    assert_true("2025-01" in line)


def test_add_repo_twice_and_recent() raises:
    """A name added twice keeps one accumulator; `recent` follows the names
    asked for, not the order they were added in."""
    var b = Builder(days_from_civil(2026, 11, 15))
    var a = b.add_repo("o/a")
    var z = b.add_repo("o/z")
    assert_equal(b.add_repo("o/a"), a)
    assert_equal(len(b.accs), 2)
    assert_equal(b.id_of("o/z"), z)
    assert_equal(b.id_of("o/none"), -1)
    b.add_commit(a, _us(2026, 11, 1), 0, 5, 2, "")
    b.add_commit(z, _us(2026, 1, 1), 0, 100, 2, "")
    b.add_commit(z, _us(2026, 11, 2), 1, 130, 2, "")
    b.add_commit(z, _us(2026, 11, 3), 2, 140, 2, "")
    var names: List[String] = ["o/z", "o/none", "o/a"]
    var r = b.recent(names)
    assert_equal(len(r.commits30), 3)
    assert_equal(r.commits30[0], 2)
    assert_equal(r.lines_delta[0], 40)
    assert_equal(r.commits30[1], 0)
    assert_equal(r.lines_delta[1], 0)
    assert_equal(r.commits30[2], 1)
    assert_equal(r.lines_delta[2], 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
