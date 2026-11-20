"""Counting a day's events per repository, and reading ReleaseEvents.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from activity import (
    Acc,
    ActivityRow,
    ReleaseRow,
    activity_batch,
    activity_rows,
    add_event,
    finish,
    parse_release,
    release_rows,
    releases_batch,
)
from days import day_text, days_of, month_of


def _b(s: StringSpan) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def test_release_payload() raises:
    var p = _b(
        '{"action":"published","release":{"url":"x","tag_name":"v0.3.0",'
        '"name":"Spring \\u00e9dition","draft":false,"prerelease":true,'
        '"created_at":"2026-11-02T10:00:00Z","published_at":"2026-11-03T08:30:00Z",'
        '"author":{"login":"bot"}}}'
    )
    var d = days_of("2026-11-03")
    var r = parse_release("o/r", d, "alice", Span(p))
    assert_true(Bool(r))
    var rel = r.take()
    assert_equal(rel.tag, "v0.3.0")
    assert_equal(rel.name, "Spring édition")
    assert_true(rel.prerelease)
    assert_equal(day_text(rel.published_at // 86_400_000_000), "2026-11-03")
    assert_equal(rel.actor, "alice")
    # Other actions, and a payload with no tag, aren't releases.
    var created = _b('{"action":"created","release":{"tag_name":"v1"}}')
    assert_false(Bool(parse_release("o/r", d, "a", Span(created))))
    var no_tag = _b('{"action":"published","release":{"name":"x"}}')
    assert_false(Bool(parse_release("o/r", d, "a", Span(no_tag))))
    assert_false(Bool(parse_release("o/r", d, "a", Span(List[UInt8]()))))


def test_counts() raises:
    var d = days_of("2025-01-01")
    var acc = Acc("o/r", d)
    var rels = List[ReleaseRow]()
    var watch = _b('{"action":"started"}')
    var opened = _b('{"action":"opened","number":3}')
    var closed = _b('{"action":"closed","number":3}')
    var push = _b('{"repository_id":1,"push_id":2,"ref":"refs/heads/main"}')
    var rel = _b('{"action":"published","release":{"tag_name":"v1","prerelease":false}}')
    add_event(acc, rels, "WatchEvent", "a", Span(watch))
    add_event(acc, rels, "WatchEvent", "b", Span(watch))
    add_event(acc, rels, "ForkEvent", "b", Span(List[UInt8]()))
    add_event(acc, rels, "IssuesEvent", "c", Span(opened))
    add_event(acc, rels, "IssuesEvent", "c", Span(closed))
    add_event(acc, rels, "PullRequestEvent", "d", Span(opened))
    add_event(acc, rels, "PullRequestEvent", "d", Span(closed))
    add_event(acc, rels, "PushEvent", "a", Span(push))
    add_event(acc, rels, "ReleaseEvent", "", Span(rel))
    add_event(acc, rels, "IssueCommentEvent", "e", Span(List[UInt8]()))
    var accs = Dict[String, Acc]()
    accs["o/r"] = acc^
    var rows = finish(accs^)
    assert_equal(len(rows), 1)
    ref r = rows[0]
    assert_equal(r.events, 10)
    assert_equal(r.stars, 2)
    assert_equal(r.forks, 1)
    assert_equal(r.issues_opened, 1)
    assert_equal(r.prs_opened, 1)
    assert_equal(r.pushes, 1)
    assert_equal(r.releases, 1)
    assert_equal(r.actors, 5)  # a, b, c, d, e; the empty actor isn't one
    assert_equal(len(rels), 1)
    assert_equal(rels[0].tag, "v1")
    assert_false(rels[0].prerelease)


def test_rows_round_trip() raises:
    var d = days_of("2026-10-31")
    var rows: List[ActivityRow] = [
        ActivityRow("a/b", d, 5, 2, 1, 0, 1, 0, 3, 4),
        ActivityRow("c/d", d + 1, 1, 0, 0, 1, 0, 0, 0, 1),
    ]
    var back = activity_rows(activity_batch(rows))
    assert_equal(len(back), 2)
    assert_equal(back[1].repo, "c/d")
    assert_equal(back[1].day, d + 1)
    assert_equal(back[0].pushes, 3)
    assert_equal(back[0].actors, 4)
    var rels: List[ReleaseRow] = [
        ReleaseRow("a/b", d, "v1", "", 0, True, "x"),
        ReleaseRow("a/b", d, "v2", "Two", 1700000000_000000, False, ""),
    ]
    var rb = release_rows(releases_batch(rels))
    assert_equal(len(rb), 2)
    assert_true(rb[0].prerelease)
    assert_false(rb[1].prerelease)
    assert_equal(rb[1].name, "Two")
    assert_equal(rb[1].published_at, 1700000000_000000)
    assert_equal(rb[0].name, "")


def test_days_and_months() raises:
    assert_equal(days_of("1970-01-01"), 0)
    assert_equal(day_text(days_of("2024-02-29")), "2024-02-29")
    assert_equal(month_of(days_of("1970-01-31")), 0)
    assert_equal(month_of(days_of("2026-11-05")), (2026 - 1970) * 12 + 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
