"""mojo.dep_names' rows: which names are due to be asked about, what the
answers say, and that a failed request keeps the last answer.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from depnames import DEP_NAMES_REASK_DAYS, DepName, merge_names, name_answer, names_due

comptime DAY = Int64(86_400_000_000)


def test_name_answer() raises:
    # `requests` on conda-forge under its first form; `lightbug-http` under
    # neither; a 500 is an error, not an answer.
    var yes: List[Int] = [200]
    var a = name_answer("requests", 5, yes)
    assert_true(a.settled())
    assert_true(a.conda_forge)
    var no: List[Int] = [404, 404]
    var b = name_answer("lightbug-http", 5, no)
    assert_true(b.settled())
    assert_false(b.conda_forge)
    var later: List[Int] = [404, 200]
    assert_true(name_answer("typing-extensions", 5, later).conda_forge)
    var err: List[Int] = [404, 503]
    var c = name_answer("sqlite", 5, err)
    assert_false(c.settled())
    assert_equal(c.state, "error HTTP 503")
    assert_false(c.conda_forge)
    var none = List[Int]()
    assert_false(name_answer("x", 5, none).settled())


def test_names_due() raises:
    var now = Int64(100) * DAY
    var lookups = Dict[String, List[String]]()
    for n in ["sqlite", "emberjson", "requests", "flare", "mist"]:
        lookups[n] = [String(n)]
    var stored = Dict[String, DepName]()
    # Answered recently: not due. Answered long ago, or an error: due.
    stored["emberjson"] = DepName("emberjson", now - DAY, "ok", False)
    stored["requests"] = DepName("requests", now - Int64(DEP_NAMES_REASK_DAYS + 1) * DAY, "ok", True)
    stored["flare"] = DepName("flare", now - DAY, "error HTTP 502", False)
    # A row of a name no longer looked up isn't asked about.
    stored["gone"] = DepName("gone", 0, "error", False)
    var due = names_due(lookups, stored, now)
    assert_equal(len(due), 4)
    assert_equal(due[0], "flare")
    assert_equal(due[1], "mist")
    assert_equal(due[2], "requests")
    assert_equal(due[3], "sqlite")


def test_merge_keeps_last_answer() raises:
    var stored: List[DepName] = [
        DepName("requests", 1, "ok", True),
        DepName("sqlite", 1, "error HTTP 500", False),
        DepName("emberjson", 1, "ok", False),
    ]
    var asked: List[DepName] = [
        # A failed re-ask keeps the answer it had.
        DepName("requests", 9, "error HTTP 503", False),
        # An answer replaces an error.
        DepName("sqlite", 9, "ok", True),
        # A new name is added, error or not.
        DepName("cuda", 9, "error", False),
        DepName("emberjson", 9, "ok", False),
    ]
    var out = merge_names(stored, asked)
    assert_equal(len(out), 4)
    assert_equal(out[0].name, "requests")
    assert_equal(out[0].fetched_at, 1)
    assert_true(out[0].conda_forge)
    assert_equal(out[1].state, "ok")
    assert_true(out[1].conda_forge)
    assert_equal(out[2].fetched_at, 9)
    assert_equal(out[3].name, "cuda")
    assert_false(out[3].settled())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
