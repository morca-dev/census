from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema
from iceberg.values import Datum
from morca.civil import now

from console_live import live_json, live_page, read_live
from lake import LIVE_COMMITS_SCHEMA, ts

from live import (
    Asked, LiveCommit, ask_heads, freshness, heads_query, history_query, new_since, parse_heads,
    parse_history,
)


def test_heads_query() raises:
    var q = heads_query(["a/b", "c-d/e.f"])
    assert_true(q.startswith('{"query":"query{rateLimit{cost remaining}'))
    assert_true('r0:repository(owner:\\"a\\",name:\\"b\\")' in q)
    assert_true('r1:repository(owner:\\"c-d\\",name:\\"e.f\\")' in q)


def test_parse_heads() raises:
    var body = String(
        '{"data":{"rateLimit":{"cost":1,"remaining":4878},',
        '"r0":{"defaultBranchRef":{"target":{"oid":"aaa"}}},',
        '"r1":null,',
        '"r2":{"defaultBranchRef":null}},',
        '"errors":[{"type":"NOT_FOUND","path":["r1"]}]}',
    )
    var h = parse_heads(body, ["o/a", "o/gone", "o/empty"])
    assert_equal(h.cost, 1)
    assert_equal(h.remaining, 4878)
    assert_equal(len(h.heads), 1)
    assert_equal(h.heads["o/a"], "aaa")


def test_history() raises:
    var body = String(
        '{"data":{"rateLimit":{"cost":1,"remaining":4800},"repository":{"defaultBranchRef":',
        '{"target":{"history":{"nodes":[',
        '{"oid":"c3","messageHeadline":"fix: \\"quoted\\"","committedDate":"2026-11-11T07:50:03Z"},',
        '{"oid":"c2","messageHeadline":"two","committedDate":"2026-11-11T07:40:00Z"},',
        '{"oid":"c1","messageHeadline":"one","committedDate":"2026-11-11T07:30:00Z"}]}}}}}}',
    )
    var cs = parse_history("o/r", body, 1)
    assert_equal(len(cs), 3)
    assert_equal(cs[0].subject, 'fix: "quoted"')
    assert_true(cs[0].committed_at > cs[1].committed_at)
    var got = new_since(cs, "c1")
    assert_true(got[1])
    assert_equal(len(got[0]), 2)
    assert_equal(got[0][0].sha, "c2")  # oldest first
    var all = new_since(cs, "zzz")
    assert_false(all[1])
    assert_equal(len(all[0]), 3)
    assert_true('history(first:30)' in history_query("o/r"))


def test_freshness() raises:
    var s = Int64(1_000_000)
    var cs: List[LiveCommit] = [
        LiveCommit("o/r", "a", "", 0, 60 * s),
        LiveCommit("o/r", "b", "", 0, 120 * s),
        LiveCommit("o/r", "c", "", 0, 600 * s),
        LiveCommit("o/r", "d", "", 0, 200_000 * s),  # pushed a day late: left out
        LiveCommit("o/r", "e", "", 1_000 * s, 1_100 * s),
    ]
    var f = freshness(cs, 0)
    assert_equal(f.n, 4)
    assert_equal(f.median_s, 100)
    assert_equal(f.p90_s, 600)
    assert_equal(freshness(cs, 1_000 * s).n, 1)


def test_live_page_reads_the_table() raises:
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-live-", perf_counter_ns())
    var cat = FilesystemCatalog.local(dir)
    var t = cat.create_table("mojo", "live_commits", Schema.parse(LIVE_COMMITS_SCHEMA))
    var s = Schema.parse(LIVE_COMMITS_SCHEMA)
    var t_now = now()
    var us = Int64(1_000_000)
    # Two polls; the second one's commit is also in the first by mistake
    # (a poll that committed twice), and one row is older than the window.
    var rows: List[Tuple[String, String, String, Int64, Int64]] = [
        ("o/a", "a1", "fix: one", (t_now - 900) * us, (t_now - 600) * us),
        ("o/b", "b1", "Add <thing>", (t_now - 400) * us, (t_now - 300) * us),
        ("o/b", "b1", "Add <thing>", (t_now - 400) * us, (t_now - 300) * us),
        ("o/c", "c1", "old", (t_now - 9 * 86_400) * us, (t_now - 9 * 86_400) * us),
    ]
    var c = List[ColumnBuilder]()
    for i in range(5):
        c.append(ColumnBuilder.of(s, i + 1))
    for r in rows:
        c[0].add(Datum.string_(r[0]))
        c[1].add(Datum.string_(r[1]))
        c[2].add(Datum.string_(r[2]))
        c[3].add(ts(r[3]))
        c[4].add(ts(r[4]))
    _ = t.append([batch_of(c)])
    _ = setenv("MORCA_WAREHOUSE", dir)
    var d = read_live(t_now)
    assert_true(d.snapshot >= 0)
    assert_equal(len(d.commits), 2)
    assert_equal(d.commits[0].sha, "b1")  # newest seen first
    var page = String(StringSlice(unsafe_from_utf8=Span(live_page(d).body)))
    assert_true("Add &lt;thing&gt;" in page)
    assert_true("o/a" in page and "Fix" in page)
    var js = String(StringSlice(unsafe_from_utf8=Span(live_json(d).body)))
    assert_true('"commits":2' in js)
    assert_true('"median_lag_s":100' in js or '"median_lag_s":300' in js)


def _ok_up_to_20(q: String) raises -> Tuple[Int, String]:
    """A GitHub that answers 502 to a heads query of more than 20 repos, and
    to any that asks for o/bad; otherwise every repo's head is "h"."""
    var n = q.count("repository(")
    if n > 20 or "bad" in q:
        return (502, String("<html>502 Bad Gateway</html>"))
    var body = String('{"data":{"rateLimit":{"cost":1,"remaining":4000}')
    for i in range(n):
        body += String(',"r', i, '":{"defaultBranchRef":{"target":{"oid":"h"}}}')
    body += "}}"
    return (200, body^)


def _forbidden(q: String) raises -> Tuple[Int, String]:
    return (401, String("Bad credentials"))


def _repos(n: Int, bad_at: Int = -1) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(String("o/bad") if i == bad_at else String("o/r", i))
    return out^


def test_ask_heads_splits_a_batch_github_times_out() raises:
    var got = Asked()
    ask_heads[_ok_up_to_20](_repos(50), got, pause=False)
    assert_equal(len(got.heads), 50)
    assert_equal(got.skipped, 0)
    assert_equal(got.remaining, 4000)


def test_ask_heads_skips_only_the_batch_that_keeps_failing() raises:
    var got = Asked()
    ask_heads[_ok_up_to_20](_repos(50, bad_at=7), got, pause=False)
    # 50 -> 25 + 25 -> (12 + 13) + ...: o/bad's batch of 6 is skipped.
    assert_true(got.skipped > 0 and got.skipped <= 10)
    assert_equal(len(got.heads) + got.skipped, 50)
    assert_true("502" in got.last_error)


def _always_502(q: String) raises -> Tuple[Int, String]:
    return (502, String("<html>502 Bad Gateway</html>"))


def test_ask_heads_gives_up_when_github_is_down() raises:
    var got = Asked()
    var raised = False
    try:
        ask_heads[_always_502](_repos(200), got, pause=False)
    except e:
        raised = "in a row failed" in String(e)
    assert_true(raised)


def test_ask_heads_raises_on_bad_credentials() raises:
    var got = Asked()
    var raised = False
    try:
        ask_heads[_forbidden](_repos(5), got, pause=False)
    except e:
        raised = "401" in String(e)
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
