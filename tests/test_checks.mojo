"""The console's data checks: a build whose numbers agree passes, each kind
of disagreement fails its check with the offending row, and a build that
fails leaves the previous one in place (unless there is none).

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from checks import (
    Check,
    CheckRun,
    RepoFacts,
    Tops,
    notice,
    page_facts,
    publish,
    run_checks,
)
from model import Point
from overview import rising_score
from swap import Swap

comptime DAY = Int64(86_400_000_000)
comptime CUT = 100 * DAY
"""The 30-day cut of these tests: day 100."""


def _pt(day: Int64, lines: Int64) -> Point:
    return Point(day * DAY, lines, String("sha"), String(), String(), String(), String())


def _repo(
    name: String, var pts: List[Point], stars: Int64 = 5, used_by: Int64 = 1
) -> RepoFacts:
    """A repo whose numbers all agree with its commit list."""
    var p = page_facts(pts, CUT)
    return RepoFacts(
        name,
        p.commits,
        p.commits30,
        Int64(p.commits),
        p.last_lines,
        stars,
        used_by,
        p^,
    )


def _good() -> List[RepoFacts]:
    var out = List[RepoFacts]()
    out.append(_repo("o/big", [_pt(10, 500), _pt(120, 1000)], 40, 3))
    out.append(_repo("o/small", [_pt(101, 4), _pt(110, 8), _pt(120, 10)]))
    out.append(_repo("o/empty", List[Point](), 0, 0))
    return out^


def _tops() -> Tops:
    var t = Tops()
    t.active = ["o/small", "o/big"]
    t.active_commits = [3, 1]
    t.active_lines = [10, 500]
    t.rising = ["o/big"]
    t.rising_gain = [7]
    t.rising_forks = [2]
    t.rising_used_by = [3]
    t.rising_score = [rising_score(7, 2, 3)]
    t.rising_stars = [40]
    t.depended = ["o/big"]
    t.depended_used_by = [3]
    return t^


def _failing(checks: List[Check]) -> List[String]:
    var out = List[String]()
    for ref c in checks:
        if not c.ok():
            out.append(c.name)
    return out^


def _rows(checks: List[Check], name: String) -> List[String]:
    for ref c in checks:
        if c.name == name:
            return c.rows.copy()
    return List[String]()


def test_page_facts() raises:
    # Two commits after the cut; the newest before it had 500 lines.
    var p = page_facts(
        [_pt(10, 300), _pt(90, 500), _pt(101, 520), _pt(120, 700)], CUT
    )
    assert_equal(p.commits, 4)
    assert_equal(p.commits30, 2)
    assert_equal(p.lines_delta, 200)
    assert_equal(p.last_lines, 700)
    # Nothing before the cut: the change is all the lines.
    var q = page_facts([_pt(101, 4), _pt(120, 10)], CUT)
    assert_equal(q.lines_delta, 10)
    var none = page_facts(List[Point](), CUT)
    assert_equal(none.commits, 0)
    assert_equal(none.last_lines, 0)


def test_all_agree() raises:
    var checks = run_checks(3, _good(), _tops())
    assert_equal(len(checks), 7)
    assert_equal(len(_failing(checks)), 0)


def test_duplicate_repo_rows() raises:
    var checks = run_checks(4, _good(), _tops())
    var bad = _failing(checks)
    assert_equal(len(bad), 1)
    assert_equal(bad[0], "repos_unique")
    assert_equal(
        _rows(checks, "repos_unique")[0], "mojo.repos: 4 rows, 3 distinct names"
    )


def test_more_commits_than_history() raises:
    # Commits read twice: six rows for a history of three.
    var repos = _good()
    repos[1].history = 3
    repos[1].commits = 6
    repos[1].page.commits = 6
    var checks = run_checks(3, repos, _tops())
    var bad = _failing(checks)
    assert_equal(len(bad), 1)
    assert_equal(bad[0], "commits_within_history")
    assert_equal(
        _rows(checks, "commits_within_history")[0],
        "o/small: 6 rows in mojo.commits, 3 recorded",
    )


def test_misaligned_numbers() raises:
    """Issue #40: the 30-day numbers of one repo under another's name."""
    var repos = _good()
    repos[0].commits30 = 3  # o/big shows o/small's
    repos[1].commits30 = 1
    var tops = _tops()
    tops.active = ["o/big", "o/small"]  # the names swapped, the numbers not
    var checks = run_checks(3, repos, tops)
    var bad = _failing(checks)
    assert_equal(len(bad), 3)
    assert_equal(bad[0], "commits30_within_commits")  # o/big: 3 of 2
    assert_equal(bad[1], "top_numbers_match_pages")
    assert_equal(bad[2], "repos_table_matches_pages")
    var rows = _rows(checks, "top_numbers_match_pages")
    assert_equal(rows[0], "o/big: Most active commits 3, its own 1")
    assert_equal(rows[1], "o/big: Most active lines 10, its own 500")


def test_top_name_not_in_repos() raises:
    var tops = _tops()
    tops.rising = ["o/gone"]
    tops.depended = ["o/gone"]
    var checks = run_checks(3, _good(), tops)
    var bad = _failing(checks)
    assert_equal(len(bad), 1)
    assert_equal(bad[0], "top_names_in_repos")
    var rows = _rows(checks, "top_names_in_repos")
    assert_equal(rows[0], "Rising: o/gone")
    assert_equal(rows[1], "Most depended on: o/gone")


def test_rising_numbers() raises:
    var tops = _tops()
    tops.rising_stars = [41]
    tops.rising_score = [1]
    var checks = run_checks(3, _good(), tops)
    var rows = _rows(checks, "top_numbers_match_pages")
    assert_equal(len(rows), 2)
    assert_equal(rows[0], "o/big: Rising stars 41, its own 40")


def test_lines_not_last_commit() raises:
    var repos = _good()
    repos[0].lines = 500
    var checks = run_checks(3, repos, _tops())
    var bad = _failing(checks)
    assert_equal(len(bad), 1)
    assert_equal(bad[0], "lines_match_last_commit")
    assert_equal(
        _rows(checks, "lines_match_last_commit")[0],
        "o/big: 500 lines, last commit 1000",
    )


def test_rows_capped() raises:
    var repos = List[RepoFacts]()
    for i in range(20):
        var r = _repo(String("o/r", i), [_pt(10, 1)])
        r.lines = 2
        repos.append(r^)
    var checks = run_checks(20, repos, Tops())
    for ref c in checks:
        if c.name == "lines_match_last_commit":
            assert_equal(c.failures, 20)
            assert_equal(len(c.rows), 5)


struct Build(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def test_failed_build_keeps_previous() raises:
    var builds = Swap[Build](Build(1))
    var runs = Swap[CheckRun](CheckRun())
    assert_equal(notice(runs.get()[]), "")
    # Build 2 (at 2026-11-07 10:00 UTC) passes and goes in.
    var t1 = Int64(1_794_045_600)
    assert_true(
        publish(
            builds,
            Build(2),
            runs,
            CheckRun(t1, t1, run_checks(3, _good(), _tops())),
            1,
        )
    )
    assert_equal(builds.get()[].n, 2)
    assert_equal(notice(runs.get()[]), "")
    # Build 3, half an hour later, fails: build 2 stays, and the pages say so.
    var t2 = t1 + 1800
    var bad = CheckRun(t2, t2, run_checks(4, _good(), _tops()))
    assert_false(publish(builds, Build(3), runs, bad^, t1))
    assert_equal(builds.get()[].n, 2)
    var last = runs.get()
    assert_false(last[].passed())
    assert_equal(last[].serving, t1)
    assert_equal(
        notice(last[]),
        (
            "Data checks failed at 2026-11-07 10:30 UTC, showing the build from"
            " 2026-11-07 10:00 UTC."
        ),
    )
    assert_true(last[].failed().startswith("repos_unique: 1 failing"))
    assert_true("FAIL  repos_unique" in last[].text())
    assert_true("serving the build from 2026-11-07 10:00 UTC" in last[].text())
    # Build 4 passes again: it goes in and the notice goes away.
    var t3 = t2 + 1800
    assert_true(
        publish(
            builds,
            Build(4),
            runs,
            CheckRun(t3, t3, run_checks(3, _good(), _tops())),
            t1,
        )
    )
    assert_equal(builds.get()[].n, 4)
    assert_equal(notice(runs.get()[]), "")


def test_first_build_served_even_when_failing() raises:
    var builds = Swap[Build](Build(0))
    var runs = Swap[CheckRun](CheckRun())
    var t = Int64(1_794_045_600)
    var bad = CheckRun(t, t, run_checks(4, _good(), _tops()))
    # Nothing built before (0): it goes in, with the notice.
    assert_true(publish(builds, Build(1), runs, bad^, 0))
    assert_equal(builds.get()[].n, 1)
    assert_equal(
        notice(runs.get()[]),
        (
            "Data checks failed at 2026-11-07 10:00 UTC, showing the build from"
            " 2026-11-07 10:00 UTC."
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
