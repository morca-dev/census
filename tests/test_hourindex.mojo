"""The index gharchive writes beside the events says what the events say.

    pixi run test
"""

from std.os import getenv
from std.time import perf_counter_ns
from std.testing import TestSuite, assert_equal, assert_true

from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from morca.tables import Table

from cols import str_at
from activity import Acc, ReleaseRow, add_event, finish, fold_hours
from days import days_of
from detect import Candidate, scan_event
from events import EventParser
from hourindex import HourIndex, candidates_from, write_marker
from lake import CANDIDATES_SCHEMA, GH_RELEASES_SCHEMA, REPO_HOUR_SCHEMA
from jscan import Range, field, scan_event as scan_line, text, timestamp_micros


def _line(
    id: Int, type: String, actor: String, repo: String, at: String, payload: String
) -> String:
    var a = String('"actor":{"login":"', actor, '"},') if actor else String()
    return String(
        '{"id":"', id, '","type":"', type, '",', a, '"repo":{"name":"', repo,
        '"},"payload":', payload, ',"created_at":"', at, '"}\n',
    )


def _events() -> List[String]:
    var out = List[String]()
    var n = 0
    def add(mut out: List[String], mut n: Int, t: String, a: String, r: String, at: String, p: String):
        n += 1
        out.append(_line(n, t, a, r, at, p))
    add(out, n, "WatchEvent", "a", "o/plain", "2025-01-01T01:00:01Z", '{"action":"started"}')
    add(out, n, "WatchEvent", "b", "o/plain", "2025-01-01T01:30:00Z", '{"action":"started"}')
    add(out, n, "WatchEvent", "a", "o/plain", "2025-01-01T02:10:00Z", '{"action":"started"}')
    add(out, n, "ForkEvent", "c", "o/plain", "2025-01-01T02:11:00Z", '{"forkee":{"full_name":"c/plain","language":"Python"}}')
    add(out, n, "ForkEvent", "c", "mod/mojo", "2025-01-01T02:12:00Z", '{"forkee":{"full_name":"c/mojo","language":"Mojo"}}')
    add(out, n, "PushEvent", "d", "x/lib", "2025-01-01T02:13:00Z", '{"commits":[{"sha":"s1","message":"add kernels.mojo and more"},{"sha":"s2","message":"fix"}]}')
    add(out, n, "PushEvent", "d", "x/lib", "2025-01-01T03:13:00Z", '{"commits":[{"sha":"s3","message":"add mojoproject.toml"}]}')
    add(out, n, "IssuesEvent", "e", "x/lib", "2025-01-01T03:14:00Z", '{"action":"opened"}')
    add(out, n, "IssuesEvent", "e", "x/lib", "2025-01-01T03:15:00Z", '{"action":"closed"}')
    add(out, n, "PullRequestEvent", "e", "x/lib", "2025-01-01T03:16:00Z", '{"action":"opened","pull_request":{"base":{"repo":{"full_name":"x/lib","language":"Mojo"}},"head":{"repo":{"full_name":"f/lib","language":"Mojo"}}}}')
    add(out, n, "ReleaseEvent", "g", "x/lib", "2025-01-01T03:17:00Z", '{"action":"published","release":{"tag_name":"v1","name":"One","prerelease":true,"published_at":"2025-01-01T03:16:59Z"}}')
    add(out, n, "ReleaseEvent", "g", "x/lib", "2025-01-01T03:18:00Z", '{"action":"created","release":{"tag_name":"v2"}}')
    add(out, n, "CreateEvent", "h", "h/new", "2025-01-01T03:19:00Z", '{"description":"A Mojo thing"}')
    add(out, n, "CreateEvent", "", "h/anon", "2025-01-01T04:00:00Z", '{"description":"nothing"}')
    return out^


def _parse(lines: List[String], mut p: EventParser) raises:
    var all = String()
    for l in lines:
        all += l
    var b = List[UInt8](all.as_bytes())
    p.feed(Span(b), 0, len(b))


def test_candidates_match_scan_event() raises:
    var lines = _events()
    var p = EventParser(True)
    _parse(lines, p)
    var done = p^.finish_index()
    var index = done^.take_index()
    # The old path: scan_event over the same events, in order.
    var want = Dict[String, Candidate]()
    for l in lines:
        var b = List[UInt8](l.as_bytes())
        var f = scan_line(Span(b), Range(0, len(b)))
        var pl = Span(b)[f.payload.start : f.payload.end]
        scan_event(want, text(Span(b), f.type), text(Span(b), f.repo_name), timestamp_micros(Span(b), f.created_at), pl)
    assert_true(len(want) >= 4)
    var got = candidates_from([index.candidate_batch()])
    assert_equal(len(got), len(want))
    var order = List[String]()
    for e in want.items():
        order.append(e.key)
    var i = 0
    for e in got.items():
        assert_equal(e.key, order[i])  # noticed in the same order
        i += 1
    for e in want.items():
        ref g = got[e.key]
        assert_equal(g.signals, e.value.signals)
        assert_equal(g.first_seen, e.value.first_seen)
        assert_equal(g.sha, e.value.sha)


def test_counts_match_add_event() raises:
    var lines = _events()
    var p = EventParser(True)
    _parse(lines, p)
    var done = p^.finish_index()
    var index = done^.take_index()
    var d = days_of("2025-01-01")
    # The old path: add_event per event.
    var old = Dict[String, Acc]()
    var old_rels = List[ReleaseRow]()
    for l in lines:
        var b = List[UInt8](l.as_bytes())
        var f = scan_line(Span(b), Range(0, len(b)))
        var repo = text(Span(b), f.repo_name)
        if repo not in old:
            old[repo] = Acc(repo, d)
        add_event(
            old[repo], old_rels, text(Span(b), f.type),
            text(Span(b), f.actor_login), Span(b)[f.payload.start : f.payload.end],
        )
    var want = finish(old^)
    # The new path: the repo_hour rows, folded.
    var repos = Dict[String, Bool]()
    for r in want:
        repos[r.repo] = True
    var accs = Dict[String, Acc]()
    fold_hours(index.repo_hour_batch(), d, repos, accs)
    var got = finish(accs^)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i].repo, want[i].repo)
        assert_equal(got[i].events, want[i].events)
        assert_equal(got[i].stars, want[i].stars)
        assert_equal(got[i].forks, want[i].forks)
        assert_equal(got[i].releases, want[i].releases)
        assert_equal(got[i].issues_opened, want[i].issues_opened)
        assert_equal(got[i].prs_opened, want[i].prs_opened)
        assert_equal(got[i].pushes, want[i].pushes)
        assert_equal(got[i].actors, want[i].actors)
    assert_equal(len(index.releases), len(old_rels))
    assert_equal(index.releases[0].tag, old_rels[0].tag)
    assert_equal(index.releases[0].repo, "x/lib")
    # x/lib saw actors d, e, g in different hours: three, not the sum of
    # each hour's distinct count.
    for r in got:
        if r.repo == "x/lib":
            assert_equal(r.actors, 3)
            assert_equal(r.pushes, 2)


def test_repo_hour_is_sorted() raises:
    var lines = _events()
    var p = EventParser(True)
    _parse(lines, p)
    var done = p^.finish_index()
    var b = done^.take_index().repo_hour_batch()
    var last = String()
    for r in range(b.num_rows):
        var repo = str_at(b.column(0), r)
        assert_true(repo >= last)
        last = repo


def test_no_marker_without_a_day() raises:
    """An hour the step commits with its day carries no marker rows; a day
    with nothing at all gets one file of them (`write_marker`)."""
    var none = HourIndex()
    assert_equal(none.candidate_batch().num_rows, 0)
    assert_equal(none.repo_hour_batch().num_rows, 0)
    assert_equal(none.releases_batch().num_rows, 0)
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-marker-", perf_counter_ns())
    var cat = FilesystemCatalog.local(dir)
    var day = days_of("2024-06-12") * 86_400_000_000
    # Made with iceberg (a step's `ensure_table` needs a run), written
    # through morca's tables.
    var schemas: List[String] = [CANDIDATES_SCHEMA, REPO_HOUR_SCHEMA, GH_RELEASES_SCHEMA]
    var names: List[String] = ["c", "h", "r"]
    var tables = List[Table]()
    for k in range(3):
        var spec = PartitionSpec(
            0, [PartitionField.single(2, 1000, "day", parse_transform("day"))]
        )
        var t = cat.create_table("t", names[k], Schema.parse(schemas[k]), spec)
        tables.append(Table.load(t.metadata.location))
    for which in range(3):
        var files = write_marker(day, which, tables[which])
        assert_equal(len(files), 1)
        assert_equal(files.files()[0].record_count, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
