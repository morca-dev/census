"""Which repositories mojo_refresh reads again (`refresh.select_due`): due
when the live head moved past the head they were last read for, not before
the wait after their last try, with a back-off after failures, longest
stale first and capped. morca-dev/dista is the case that started it: on
Mojo 1.3 nightlies at its head, 1.2.0 in the lake since 2026-11-11.

    pixi run test test_refresh
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from jscan import days_from_civil
from refresh import (
    FAILED,
    HOUR,
    OK,
    Due,
    Known,
    Policy,
    Refreshed,
    after_try,
    refreshed_batch,
    refreshed_rows,
    select_due,
    wait_hours,
)

comptime DAY = Int64(86_400_000_000)
comptime DISTA = "morca-dev/dista"


def _at(month: Int, day: Int) -> Int64:
    """Midnight of a day of 2026, in microseconds."""
    return Int64(days_from_civil(2026, month, day)) * DAY


struct _Lake(Movable):
    """What a run reads, filled per test."""

    var repos: List[String]
    var sizes: Dict[String, Int64]
    var heads: Dict[String, String]
    var records: Dict[String, Refreshed]
    var known: Dict[String, Known]

    def __init__(out self):
        self.repos = List[String]()
        self.sizes = Dict[String, Int64]()
        self.heads = Dict[String, String]()
        self.records = Dict[String, Refreshed]()
        self.known = Dict[String, Known]()

    def read(mut self, repo: String, commit_head: String, commit_at: Int64, version_head: String):
        """A repository mojo_history and mojo_versions read."""
        self.repos.append(repo)
        self.known[repo] = Known(commit_head, commit_at, version_head)

    def due(self, now: Int64, p: Policy = Policy.default()) raises -> List[String]:
        var out = List[String]()
        for ref d in select_due(self.repos, self.sizes, self.heads, self.records, self.known, now, p).due:
            out.append(d.repo)
        return out^


def test_dista_moved_since_its_first_read_is_due() raises:
    var lake = _Lake()
    lake.read(DISTA, "aaa", _at(11, 11), "aaa")
    lake.heads[DISTA] = "bbb"
    var sel = select_due(lake.repos, lake.sizes, lake.heads, lake.records, lake.known, _at(11, 27), Policy.default())
    assert_equal(len(sel.due), 1)
    assert_equal(sel.due[0].repo, DISTA)
    assert_equal(sel.due[0].head, "bbb")
    assert_equal(sel.due[0].since, _at(11, 11))
    # Not moved: both tables were read at the live head.
    lake.heads[DISTA] = "aaa"
    assert_equal(len(lake.due(_at(11, 27))), 0)
    # mojo_versions read a newer head than mojo_history: due all the same.
    lake.known[DISTA] = Known("aaa", _at(11, 11), "ccc")
    assert_equal(len(lake.due(_at(11, 27))), 1)


def test_not_due_without_commits_or_a_head_or_over_the_size_limit() raises:
    var lake = _Lake()
    lake.repos.append("new/repo")  # mojo_history hasn't read it
    lake.heads["new/repo"] = "bbb"
    lake.read("gone/repo", "aaa", _at(11, 1), "aaa")  # no live head
    lake.read("modular/modular", "aaa", _at(11, 1), "aaa")
    lake.heads["modular/modular"] = "bbb"
    lake.sizes["modular/modular"] = 2_000_000
    var p = Policy.default()
    p.max_kb = 100_000
    var sel = select_due(lake.repos, lake.sizes, lake.heads, lake.records, lake.known, _at(11, 27), p)
    assert_equal(len(sel.due), 0)
    assert_equal(sel.unread, 1)
    assert_equal(sel.no_head, 1)
    assert_equal(sel.too_big, 1)
    # Without MOJO_HISTORY_MAX_KB (production) it is read, as mojo_history
    # reads it.
    assert_equal(len(lake.due(_at(11, 27))), 1)


def test_a_record_waits_after_a_good_read() raises:
    var lake = _Lake()
    lake.read(DISTA, "aaa", _at(11, 11), "aaa")
    var t = _at(11, 27)
    var read = after_try(None, Due(DISTA, "bbb", _at(11, 11)), t, "")
    assert_equal(read.outcome, OK)
    assert_equal(read.head, "bbb")
    assert_equal(read.read_at, t)
    assert_equal(read.failures, 0)
    lake.records[DISTA] = read.copy()
    # The record, not mojo.commits, says what it was read at.
    lake.heads[DISTA] = "bbb"
    assert_equal(len(lake.due(t + HOUR)), 0)
    # Moved again: not before min_hours (6) since the read.
    lake.heads[DISTA] = "ccc"
    var sel = select_due(lake.repos, lake.sizes, lake.heads, lake.records, lake.known, t + 5 * HOUR, Policy.default())
    assert_equal(len(sel.due), 0)
    assert_equal(sel.resting, 1)
    assert_equal(len(lake.due(t + 6 * HOUR)), 1)
    # A repository over big_kb waits big_hours (24).
    lake.sizes[DISTA] = 2_000_000
    assert_equal(len(lake.due(t + 23 * HOUR)), 0)
    assert_equal(len(lake.due(t + 24 * HOUR)), 1)


def test_failures_back_off() raises:
    var p = Policy.default()
    var lake = _Lake()
    lake.read(DISTA, "aaa", _at(11, 11), "aaa")
    lake.heads[DISTA] = "bbb"
    var t = _at(11, 20)
    var r = after_try(None, Due(DISTA, "bbb", _at(11, 11)), t, "git clone failed")
    assert_equal(r.outcome, FAILED)
    assert_equal(r.failures, 1)
    assert_equal(r.head, "")  # never read well by mojo_refresh
    assert_equal(r.error, "git clone failed")
    # 6, 12, 24, 48, 96 hours, then a week at most.
    var waits: List[Int64] = [6, 12, 24, 48, 96, 168, 168, 168]
    for i in range(len(waits)):
        assert_equal(wait_hours(r, 0, p), waits[i])
        lake.records[DISTA] = r.copy()
        assert_equal(len(lake.due(r.tried_at + (waits[i] - 1) * HOUR)), 0)
        var sel = select_due(lake.repos, lake.sizes, lake.heads, lake.records, lake.known, r.tried_at + waits[i] * HOUR, p)
        assert_equal(len(sel.due), 1)
        var next = r.tried_at + waits[i] * HOUR
        r = after_try(r.copy(), sel.due[0].copy(), next, "git clone failed")
        assert_equal(r.failures, Int64(i + 2))
    # A good read ends the back-off, and keeps the head it was read for.
    var ok = after_try(r.copy(), Due(DISTA, "bbb", 0), r.tried_at + DAY * 7, "")
    assert_equal(ok.failures, 0)
    assert_equal(wait_hours(ok, 0, p), 6)
    # A failure after a good read keeps the good read's head and time.
    var again = after_try(ok.copy(), Due(DISTA, "ccc", 0), ok.tried_at + DAY, "timed out")
    assert_equal(again.head, "bbb")
    assert_equal(again.read_at, ok.read_at)
    assert_equal(again.failures, 1)
    # A failed try for a head that moves back to the last good one: current.
    lake.records[DISTA] = again.copy()
    lake.heads[DISTA] = "bbb"
    assert_equal(len(lake.due(again.tried_at + DAY * 30)), 0)


def test_longest_stale_first_and_capped() raises:
    var lake = _Lake()
    # Read by mojo_history only, their newest commits from 11-01 to 11-05.
    lake.read("e/five", "x", _at(11, 5), "x")
    lake.read("a/one", "x", _at(11, 1), "x")
    lake.read("c/three", "x", _at(11, 3), "x")
    lake.read("b/three", "x", _at(11, 3), "x")
    # Read by mojo_refresh on 11-02 (an older read than three of them).
    lake.read("d/two", "x", _at(11, 1), "x")
    lake.records["d/two"] = Refreshed("d/two", "x", _at(11, 2), _at(11, 2), OK, 0, String())
    for ref r in lake.repos:
        lake.heads[r] = "moved"
    var p = Policy.default()
    p.max_repos = 3
    var sel = select_due(lake.repos, lake.sizes, lake.heads, lake.records, lake.known, _at(11, 27), p)
    assert_equal(len(sel.due), 3)
    assert_equal(sel.due[0].repo, "a/one")
    assert_equal(sel.due[1].repo, "d/two")
    assert_equal(sel.due[2].repo, "b/three")  # before c/three, by name
    assert_equal(sel.waiting, 2)
    p.max_repos = 60
    assert_equal(len(lake.due(_at(11, 27), p)), 5)
    # A repository listed twice in mojo.repos is read once.
    lake.repos.append("a/one")
    assert_equal(len(lake.due(_at(11, 27), p)), 5)


def test_record_rows_round_trip() raises:
    var rows: List[Refreshed] = [
        Refreshed(DISTA, "bbb", _at(11, 27), _at(11, 27), OK, 0, String()),
        Refreshed("modular/modular", String(), 0, _at(11, 27), FAILED, 3, "git clone timed out"),
    ]
    var back = refreshed_rows(refreshed_batch(rows))
    assert_equal(len(back), 2)
    for i in range(2):
        assert_equal(back[i].repo, rows[i].repo)
        assert_equal(back[i].head, rows[i].head)
        assert_equal(back[i].read_at, rows[i].read_at)
        assert_equal(back[i].tried_at, rows[i].tried_at)
        assert_equal(back[i].outcome, rows[i].outcome)
        assert_equal(back[i].failures, rows[i].failures)
        assert_equal(back[i].error, rows[i].error)
    assert_false(back[1].head.byte_length() > 0)
    assert_true(back[1].error.byte_length() > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
