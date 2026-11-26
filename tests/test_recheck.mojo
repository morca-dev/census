"""A repository answered `not mojo` is asked again once GitHub's search
gives it as a Mojo one: amarbaro/mojo-libs was created on 2026-11-05 with
one `.mojo` file among shell scripts and markdown, a candidate only by its
name, and became a Mojo monorepo on 11-20. The rows of `mojo.checked` and
GitHub's replies are fixtures; `detect.to_ask` is what mojo_repos checks.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from detect import Asked, Candidate, RECHECK_DAYS, answer, note, repo_verdict, to_ask
from jscan import days_from_civil

comptime REPO = "amarbaro/mojo-libs"
comptime DAY = Int64(86_400_000_000)


def _at(month: Int, day: Int) -> Int64:
    """Midnight of a day of 2026, in microseconds."""
    return Int64(days_from_civil(2026, month, day)) * DAY


def _checked(repo: String, at: Int64, outcome: String, signals: String) -> Asked:
    """A row of mojo.checked, first seen on the day it was answered."""
    return Asked(at, outcome, Candidate(repo, signals, at, ""))


def _searched(repo: String) raises -> Dict[String, Candidate]:
    """A run's candidates: `repo` given by GitHub's search, last pushed on
    11-26."""
    var found = Dict[String, Candidate]()
    note(found, repo, "search", _at(11, 26) + 3600 * 1_000_000)
    return found^


def _reply(language: String) -> String:
    """GitHub's `GET /repos/amarbaro/mojo-libs` reply."""
    return String(
        '{"id":1094417762,"name":"mojo-libs","full_name":"', REPO, '","description":"Mojo libraries",',
        '"fork":false,"language":"', language, '","stargazers_count":3,"forks_count":0,',
        '"topics":[],"default_branch":"main","size":420,"created_at":"2026-11-05T09:12:00Z"}',
    )


def test_not_mojo_given_by_search_is_asked_again() raises:
    var asked = Dict[String, Asked]()
    answer(asked, _checked(REPO, _at(11, 5), "not mojo", "name"))
    var now = _at(11, 26)
    var todo = to_ask(_searched(REPO), Dict[String, Bool](), asked, now)
    assert_equal(len(todo), 1)
    ref c = todo[0]
    assert_equal(c.repo, REPO)
    assert_true(c.has("search"))
    assert_true(c.has("name"))  # why it was a candidate the first time
    assert_equal(c.first_seen, _at(11, 5))  # first seen when first asked
    assert_equal(c.rank(), 0)
    # GitHub now says Mojo: a `mojo` verdict, as for a new repository.
    var v = repo_verdict(c.repo, 200, _reply("Mojo"), 4000)
    assert_equal(v.outcome, "mojo")
    assert_equal(v.how, "language")
    assert_equal(v.info.repo, REPO)
    # The new answer is a newer row of the log; it wins whichever row is
    # read first.
    answer(asked, Asked(now, "mojo", c.copy()))
    assert_equal(asked[REPO].outcome, "mojo")
    var reversed = Dict[String, Asked]()
    answer(reversed, Asked(now, "mojo", c.copy()))
    answer(reversed, _checked(REPO, _at(11, 5), "not mojo", "name"))
    assert_equal(reversed[REPO].outcome, "mojo")
    # The next run asks no more, even before mojo.repos has it.
    assert_equal(len(to_ask(_searched(REPO), Dict[String, Bool](), asked, now + DAY)), 0)
    var known = Dict[String, Bool]()
    known[REPO] = True
    assert_equal(len(to_ask(_searched(REPO), known, Dict[String, Asked](), now + DAY)), 0)


def test_not_mojo_seen_only_in_the_events_stands() raises:
    var asked = Dict[String, Asked]()
    answer(asked, _checked(REPO, _at(11, 5), "not mojo", "name"))
    var found = Dict[String, Candidate]()
    note(found, REPO, "name", _at(11, 26))
    note(found, REPO, "push", _at(11, 26), "abc123")
    assert_equal(len(to_ask(found, Dict[String, Bool](), asked, _at(11, 26))), 0)


def test_mojo_fork_and_gone_stand() raises:
    var asked = Dict[String, Asked]()
    answer(asked, _checked("a/mojo", _at(11, 5), "mojo", "name"))
    answer(asked, _checked("a/fork", _at(11, 5), "fork", "language"))
    answer(asked, _checked("a/gone", _at(11, 5), "gone", "name"))
    answer(asked, _checked("a/waits", _at(11, 5), "unchecked", "name"))
    var found = Dict[String, Candidate]()
    for repo in ["a/mojo", "a/fork", "a/gone", "a/waits"]:
        note(found, repo, "search", _at(11, 26))
    var todo = to_ask(found, Dict[String, Bool](), asked, _at(11, 26))
    assert_equal(len(todo), 1)
    assert_equal(todo[0].repo, "a/waits")  # `unchecked` is asked, as before


def test_search_and_verify_disagreeing_costs_a_check_a_week() raises:
    # The search gave it and `verify` still said `not mojo` (GitHub's search
    # index behind the repository's `language`): asked again only once
    # RECHECK_DAYS have passed.
    var still = repo_verdict(REPO, 200, _reply("Shell"), 4000)
    assert_equal(still.outcome, "")  # on to the manifests and the commit
    var asked = Dict[String, Asked]()
    var at = _at(11, 20)
    answer(asked, _checked(REPO, at, "not mojo", "name,search"))
    for d in range(1, RECHECK_DAYS):
        assert_equal(len(to_ask(_searched(REPO), Dict[String, Bool](), asked, at + Int64(d) * DAY)), 0)
    assert_equal(len(to_ask(_searched(REPO), Dict[String, Bool](), asked, at + Int64(RECHECK_DAYS) * DAY)), 1)


def test_forks_and_gone_replies() raises:
    var fork = String(_reply("Mojo")).replace('"fork":false', '"fork":true')
    assert_equal(repo_verdict(REPO, 200, fork, 10).outcome, "fork")
    assert_equal(repo_verdict(REPO, 404, "", 10).outcome, "gone")
    assert_equal(repo_verdict(REPO, 403, "", 0).outcome, "limited")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
