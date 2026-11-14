"""The republish magmalake/flare_mlake is found, and counts for
ehsanmok/flare: GH Archive's recent events never made it a candidate,
GitHub's search does, and a
project depending on the republish is one of flare's dependents through a
fork of it (`deps.republishes`).

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from deps import DEPENDS, Dep, ForkOf, PROVIDES, RepoDep, manifest_deps, republishes, resolve
from detect import Candidate, parse_search, scan_event, search_queries
from jscan import Range, scan_event as scan_line, text, timestamp_micros


def _event(type: String, repo: String, payload: String) -> String:
    """An event as GH Archive's 2026-11 hours have them: no push or create
    events, and pull requests whose repositories carry no `language`."""
    return String(
        '{"id":"1","type":"', type, '","actor":{"login":"dev"},"repo":{"id":1,"name":"', repo,
        '"},"payload":', payload, ',"created_at":"2026-11-12T10:00:00Z"}',
    )


def test_events_name_no_candidate() raises:
    var lines: List[String] = [
        _event("WatchEvent", "magmalake/flare_mlake", '{"action":"started"}'),
        _event(
            "PullRequestEvent", "magmalake/flare_mlake",
            '{"action":"opened","pull_request":{"head":{"repo":{"id":1,"name":"flare_mlake"}},"base":{"repo":{"id":1,"name":"flare_mlake"}}}}',
        ),
        _event("WatchEvent", "magmalake/iceberg.mojo", '{"action":"started"}'),
    ]
    var found = Dict[String, Candidate]()
    for ref l in lines:
        var b = List[UInt8](l.as_bytes())
        var f = scan_line(Span(b), Range(0, len(b)))
        scan_event(found, text(Span(b), f.type), text(Span(b), f.repo_name), timestamp_micros(Span(b), f.created_at), Span(b)[f.payload.start : f.payload.end])
    # Only a name that says "mojo" is a candidate.
    assert_true("magmalake/iceberg.mojo" in found)
    assert_false("magmalake/flare_mlake" in found)


def test_search_finds_it() raises:
    var body = String(
        '{"total_count":2,"incomplete_results":false,"items":[',
        '{"id":1,"full_name":"magmalake/flare_mlake","fork":false,"language":"Mojo","pushed_at":"2026-11-12T10:39:51Z"},',
        '{"id":2,"full_name":"someone/flare","fork":true,"language":"Mojo","pushed_at":"2026-11-12T11:00:00Z"}]}',
    )
    var got = parse_search(body)
    assert_equal(got[0], 2)
    assert_equal(len(got[1]), 1)  # the fork is left out
    ref c = got[1][0]
    assert_equal(c.repo, "magmalake/flare_mlake")
    assert_equal(c.signals, "search")
    assert_equal(c.rank(), 0)
    assert_true(c.first_seen > 0)
    var daily = search_queries("2026-11-12", True)
    assert_equal(len(daily), 2)
    assert_equal(daily[0], "language:Mojo+created:2026-11-12")
    assert_equal(daily[1], "language:Mojo+pushed:%3E%3D2026-11-12")
    assert_equal(len(search_queries("2024-03-01", False)), 1)


def _rows(repo: String, path: String, text: String) -> List[RepoDep]:
    var out = List[RepoDep]()
    for ref d in manifest_deps(path, text):
        out.append(RepoDep(repo, 0, d.copy()))
    return out^


def test_flare_lists_republish_users_through_a_fork() raises:
    var census = String(
        "[dependencies]\n",
        'flare_mlake = { git = "https://github.com/magmalake/flare_mlake.git", rev = "b2c5823" }\n',
        'json_mlake = { git = "https://github.com/magmalake/json_mlake.git", rev = "27c05c1" }\n',
    )
    # By the package name the republish publishes, from the mojoshelf channel.
    var dista = String("[dependencies]\n", 'flare_mlake = ">=0.14.1,<0.15"\n')
    # Upstream directly: a direct dependent, not one through a fork.
    var app = String("[dependencies]\n", 'flare = { git = "https://github.com/ehsanmok/flare" }\n')
    var rows = _rows("morca-dev/census", "pixi.toml", census)
    rows.extend(_rows("morca-dev/dista", "pixi.toml", dista))
    rows.extend(_rows("x/app", "pixi.toml", app))
    rows.append(RepoDep("magmalake/flare_mlake", 0, Dep(PROVIDES, "package", "flare_mlake", "", "package", "pixi.toml")))
    var repos: List[String] = [
        "ehsanmok/flare", "magmalake/flare_mlake", "ehsanmok/json",
        "morca-dev/census", "morca-dev/dista", "x/app",
    ]
    var g = resolve(repos, rows)
    ref users = g.used_by["ehsanmok/flare"]
    assert_equal(len(users), 3)
    assert_equal(users[0], "morca-dev/census")
    assert_equal(users[1], "morca-dev/dista")
    assert_equal(users[2], "x/app")
    ref forks = g.via_forks["ehsanmok/flare"]
    assert_equal(len(forks), 2)
    assert_equal(forks[0], "morca-dev/census")
    assert_equal(forks[1], "morca-dev/dista")
    # The republish keeps its own dependents.
    assert_equal(len(g.used_by["magmalake/flare_mlake"]), 2)
    # json_mlake isn't a census repo here: its upstream is, through it.
    assert_equal(g.used_by["ehsanmok/json"][0], "morca-dev/census")
    assert_equal(g.via_forks["ehsanmok/json"][0], "morca-dev/census")
    ref mine = g.depends_on["morca-dev/census"]
    assert_equal(len(mine), 3)  # flare, json, flare_mlake
    # Without the table, flare has its direct dependent only.
    var plain = resolve(repos, rows, Dict[String, ForkOf](), Dict[String, String](), Dict[String, String]())
    assert_equal(len(plain.used_by["ehsanmok/flare"]), 1)


def test_table() raises:
    var t = republishes()
    assert_equal(t["magmalake/flare_mlake"], "ehsanmok/flare")
    assert_equal(t["magmalake/json_mlake"], "ehsanmok/json")
    assert_equal(len(t), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
