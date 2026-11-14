"""A repository renamed and then transferred keeps one identity (#181): GH
Archive's events, GitHub's replies to mojo_stats and mojo_repos, and a
manifest naming it by its old URL, all as fixtures.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from activity import Acc, ReleaseRow, add_event, finish
from deps import ForkOf, RepoDep, manifest_deps, resolve
from detect import Candidate, parse_repo, scan_event
from jscan import Range, scan_event as scan_line, text, timestamp_micros
from model import MonthActivity, merge_months
from names import NameRow, Names, names_from
from search import names_score
from stats import parse_stats

comptime ID = 811_204_517
"""GitHub's id for the repository, the same under every name."""


def _event(type: String, repo: String, at: String, payload: String) -> String:
    """A GH Archive event line: the repository as `{"id", "name"}`, the name
    being the one it had when the event happened."""
    return String(
        '{"id":"1","type":"', type, '","actor":{"login":"dev"},"repo":{"id":', ID,
        ',"name":"', repo, '","url":"https://api.github.com/repos/', repo,
        '"},"payload":', payload, ',"created_at":"', at, '"}',
    )


def _events() -> List[String]:
    """Found as magmalake/orca.mojo, renamed magmalake/orca on 11-05, moved to
    the morca-dev organization on 11-11."""
    var push = String('{"commits":[{"sha":"s1","message":"add step.mojo"}]}')
    return [
        _event("PushEvent", "magmalake/orca.mojo", "2026-11-01T10:00:00Z", push),
        _event("WatchEvent", "magmalake/orca.mojo", "2026-11-01T11:00:00Z", '{"action":"started"}'),
        _event("WatchEvent", "magmalake/orca", "2026-11-06T09:00:00Z", '{"action":"started"}'),
        _event("PushEvent", "magmalake/orca", "2026-11-06T09:30:00Z", push),
        _event("WatchEvent", "morca-dev/morca", "2026-11-12T08:00:00Z", '{"action":"started"}'),
        _event("PushEvent", "morca-dev/morca", "2026-11-12T08:30:00Z", push),
    ]


def _reply(full_name: String, description: String, topics: String) -> String:
    """GitHub's `GET /repos/...` reply: the redirect followed, it names the
    repository as it is now."""
    return String(
        '{"id":', ID, ',"name":"x","full_name":"', full_name, '","description":"', description,
        '","fork":false,"language":"Mojo","stargazers_count":12,"forks_count":1,',
        '"topics":', topics, ',"default_branch":"main","size":10,',
        '"created_at":"2026-10-01T00:00:00Z","subscribers_count":1}',
    )


def _stats_rows() raises -> List[NameRow]:
    """mojo_stats's rows for the key `magmalake/orca.mojo` on three days,
    the first from before `repo_id` was recorded, and one for an unrelated
    repository."""
    var out = List[NameRow]()
    var days: List[Int64] = [20_393, 20_398, 20_404]
    var names: List[String] = ["magmalake/orca.mojo", "magmalake/orca", "morca-dev/morca"]
    for i in range(3):
        var r = parse_stats("magmalake/orca.mojo", _reply(names[i], "A Mojo orchestrator", '["mojo"]'))
        out.append(NameRow(r.repo, days[i], r.state, r.renamed_to, r.repo_id if i > 0 else 0))
    var other = parse_stats("acme/http", _reply("acme/http", "HTTP", "[]").replace(String(ID), "7"))
    out.append(NameRow(other.repo, 20_404, other.state, other.renamed_to, other.repo_id))
    return out^


def _names() raises -> Names:
    return names_from(["magmalake/orca.mojo", "acme/http"], _stats_rows())


def test_stats_reply_records_rename_and_id() raises:
    var r = parse_stats("magmalake/orca.mojo", _reply("morca-dev/morca", "d", "[]"))
    assert_equal(r.state, "renamed")
    assert_equal(r.renamed_to, "morca-dev/morca")
    assert_equal(r.repo_id, ID)
    assert_equal(parse_repo(_reply("morca-dev/morca", "d", "[]")).id, ID)


def test_current_name_and_aliases() raises:
    var n = _names()
    # The key, the rename and the transfer are one repository, named as
    # GitHub named it on the latest day.
    assert_equal(n.canon("magmalake/orca.mojo"), "morca-dev/morca")
    assert_equal(n.canon("magmalake/orca"), "morca-dev/morca")
    assert_equal(n.canon("Morca-Dev/MORCA"), "morca-dev/morca")
    var all = n.names_of("magmalake/orca.mojo")
    assert_equal(len(all), 3)
    assert_equal(all[0], "morca-dev/morca")
    assert_equal(all[1], "magmalake/orca")
    assert_equal(all[2], "magmalake/orca.mojo")
    assert_equal(len(n.aliases_of("morca-dev/morca")), 2)
    # An unrelated repository is left alone, and an unknown name is itself.
    assert_equal(n.canon("acme/http"), "acme/http")
    assert_equal(len(n.aliases_of("acme/http")), 0)
    assert_equal(n.canon("someone/else"), "someone/else")
    assert_false(n.knows("someone/else"))


def test_new_name_is_not_a_new_repository() raises:
    # The day after the transfer, the events name morca-dev/morca, a
    # candidate for mojo_repos (a push naming a .mojo file).
    var found = Dict[String, Candidate]()
    for ref l in _events():
        var b = List[UInt8](l.as_bytes())
        var f = scan_line(Span(b), Range(0, len(b)))
        var p = Span(b)[f.payload.start : f.payload.end]
        scan_event(found, text(Span(b), f.type), text(Span(b), f.repo_name), timestamp_micros(Span(b), f.created_at), p)
    assert_true("morca-dev/morca" in found)
    var n = _names()
    # Known by name once mojo_stats has seen the transfer...
    assert_equal(n.known_as("morca-dev/morca", 0), "morca-dev/morca")
    # ...and by GitHub's id before it has: a later name mojo_stats hasn't
    # seen yet, from mojo_repos's own `GET /repos/...`.
    var info = parse_repo(_reply("morca-dev/orca-next", "d", "[]"))
    assert_equal(n.known_as(info.repo, info.id), "morca-dev/morca")
    assert_equal(n.known_as("someone/new", 99), "")


def test_duplicate_key_is_one_repository() raises:
    # A key added under the new name before this fix: the same id joins it.
    var rows = _stats_rows()
    rows.append(NameRow("morca-dev/morca", 20_404, "ok", "", ID))
    var n = names_from(["magmalake/orca.mojo", "morca-dev/morca"], rows)
    assert_equal(n.canon("magmalake/orca.mojo"), "morca-dev/morca")
    assert_equal(n.canon("morca-dev/morca"), "morca-dev/morca")
    assert_equal(len(n.names_of("morca-dev/morca")), 3)


def test_activity_under_every_name() raises:
    # mojo_activity's members are every name; each day's events count under
    # the name they carry, and the console adds the names up.
    var n = _names()
    var members = Dict[String, Bool]()
    for name in n.names_of("magmalake/orca.mojo"):
        members[name] = True
    var by_name = Dict[String, List[MonthActivity]]()
    var rels = List[ReleaseRow]()
    for ref l in _events():
        var b = List[UInt8](l.as_bytes())
        var f = scan_line(Span(b), Range(0, len(b)))
        var repo = text(Span(b), f.repo_name)
        assert_true(repo in members, repo)
        var accs = Dict[String, Acc]()
        accs[repo] = Acc(repo, 0)
        add_event(accs[repo], rels, text(Span(b), f.type), "dev", Span(b)[f.payload.start : f.payload.end])
        for ref row in finish(accs^):
            if row.repo not in by_name:
                by_name[row.repo] = List[MonthActivity]()
            by_name[row.repo].append(MonthActivity("2026-11", row.stars, row.forks, row.releases, row.issues_opened, row.prs_opened, row.pushes, 1))
    var total = List[MonthActivity]()
    for name in n.names_of("magmalake/orca.mojo"):
        if name in by_name:
            var days = by_name[name].copy()
            var month = days[0].copy()
            for i in range(1, len(days)):
                month.stars += days[i].stars
                month.pushes += days[i].pushes
                month.days_active += days[i].days_active
            total = merge_months(total, [month^])
    assert_equal(len(total), 1)
    assert_equal(total[0].stars, 3)
    assert_equal(total[0].pushes, 3)


def test_search_finds_every_name() raises:
    var n = _names()
    var cur = n.canon("magmalake/orca.mojo")
    var old = n.aliases_of(cur)
    assert_true(names_score(cur, old, "A Mojo orchestrator", "morca") > 0)
    assert_true(names_score(cur, old, "A Mojo orchestrator", "morca-dev") > 0)
    assert_true(names_score(cur, old, "A Mojo orchestrator", "orca.mojo") > 0)
    # The current name ranks above the same match on an old one.
    assert_true(names_score(cur, old, "", "morca") > names_score("a/x", ["b/morca"], "", "morca"))
    assert_equal(names_score(cur, old, "", "nothing"), 0)


def test_dependency_by_old_url() raises:
    # The census's pixi.toml from before the move names orca by its old URL;
    # a fork of it names the old name as its parent (mojo.dep_forks).
    var n = _names()
    var pixi = String(
        "[dependencies]\n",
        'morca-mojo = { git = "https://github.com/magmalake/orca.mojo.git", rev = "abc" }\n',
    )
    var rows = List[RepoDep]()
    for ref d in manifest_deps("pixi.toml", pixi):
        rows.append(RepoDep("acme/http", 0, d.copy()))
    var forked = 'helper = { git = "https://github.com/someone/orca-fork", rev = "abc" }\n'
    for ref d in manifest_deps("pixi.toml", String("[dependencies]\n", forked)):
        rows.append(RepoDep("b/app", 0, d.copy()))
    var forks = Dict[String, ForkOf]()
    forks["someone/orca-fork"] = ForkOf("magmalake/orca", "magmalake/orca")
    var g = resolve(["morca-dev/morca", "acme/http", "b/app"], rows, forks, n.current)
    assert_equal(len(g.depends_on["acme/http"]), 1)
    assert_equal(g.depends_on["acme/http"][0], "morca-dev/morca")
    assert_equal(len(g.used_by["morca-dev/morca"]), 2)
    assert_equal(len(g.via_forks["morca-dev/morca"]), 1)
    assert_equal(g.via_forks["morca-dev/morca"][0], "b/app")
    # A depender keyed by its old name (mojo.repo_deps' `repo`) is resolved
    # as the repository it is now.
    var mine = List[RepoDep]()
    for ref d in manifest_deps("pixi.toml", "[dependencies]\nhttp = { git = \"https://github.com/acme/http\" }\n"):
        mine.append(RepoDep("magmalake/orca.mojo", 0, d.copy()))
    var g2 = resolve(["morca-dev/morca", "acme/http"], mine, Dict[String, ForkOf](), n.current)
    assert_equal(g2.depends_on["morca-dev/morca"][0], "acme/http")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
