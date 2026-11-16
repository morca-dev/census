"""Timeouts and retries (#49): `fetch.Download` against a local server that
stalls, fails and cuts connections (tests/http_faults.py, which needs
`python3`), and the timeout of `command.command` and git's stall detector for
clones.

    pixi run test
"""

from std.os import getenv
from std.os.path import exists
from std.subprocess import run
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns, sleep

from fetch import Download, HttpSettings
from command import STDERR_MERGE, TIMED_OUT, command, git
from history import git_net, transient_git_error


def _sh(cmd: String, timeout_ms: Int = 0) raises -> Tuple[Int, String]:
    """`cmd` run with `sh` (the tests set repositories up with it; the census
    itself runs git without a shell)."""
    return command(["/bin/sh", "-c", cmd], timeout_ms)
from retry import backoff_ms, retryable_status


def _port() raises -> Int:
    """The server's port: started once (its PID in a file beside the
    port), and stopped by `main` by that PID."""
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-fetch")
    var port_file = String(dir, "/port")
    if not exists(port_file):
        _ = run(
            String(
                "mkdir -p '",
                dir,
                "'; python3 -u tests/http_faults.py '",
                port_file,
                "' < /dev/null > /dev/null 2>&1 & echo $! > '",
                dir,
                "/pid'",
            )
        )
        for _ in range(200):
            if exists(port_file):
                break
            sleep(0.05)
    with open(port_file, "r") as f:
        return Int(f.read().strip())


def _url(path: String) raises -> String:
    return String("http://127.0.0.1:", _port(), path)


def _expected(n: Int) -> List[UInt8]:
    var b = List[UInt8](capacity=n)
    for i in range(n):
        b.append(UInt8((7 * i + 3) % 251))
    return b^


def _read_all(dl: Download) raises -> List[UInt8]:
    """The whole body, as the decoder would take it: wait for more, look,
    release."""
    var got = 0
    while True:
        got = dl.wait(got + 1)
        if dl.complete():
            break
    var out = List[UInt8](capacity=got)
    out.extend(dl.view(got))
    return out^


def _quick(retries: Int, deadline_s: Int = 20) -> HttpSettings:
    """Short timeouts, so a stall is found in half a second."""
    return HttpSettings(2_000, 500, deadline_s * 1000, retries)


def _secs(t0: Int) -> Float64:
    return Float64(perf_counter_ns() - t0) / 1e9


def _count(key: String) raises -> Int:
    var dl = Download(_url(String("/count/", key)), _quick(0))
    var b = _read_all(dl)
    var s = String()
    for x in b:
        s += chr(Int(x))
    return Int(s)


def test_ok_is_byte_identical() raises:
    var n = 3_000_000
    var dl = Download(_url(String("/ok/", n)), _quick(0))
    assert_true(_read_all(dl) == _expected(n))


def test_stall_mid_body_fails_within_deadline() raises:
    # Before #49 this read blocked forever. Idle timeout 0.5 s, one retry
    # (from the byte it stopped at, which stalls again): about 1.5 s plus
    # the backoff of under a second.
    var t0 = perf_counter_ns()
    var raised = False
    try:
        var dl = Download(_url("/stall/2000000"), _quick(1))
        _ = _read_all(dl)
    except e:
        raised = True
        assert_true("gave up after 2 tries" in String(e), String(e))
    assert_true(raised)
    assert_true(_secs(t0) < 6.0, String(_secs(t0)))


def test_stalled_head_hits_the_deadline() raises:
    # Plenty of tries, but a 3 s deadline: it stops at the deadline.
    var t0 = perf_counter_ns()
    var raised = False
    try:
        var dl = Download(_url("/stallhead"), _quick(20, 3))
        _ = _read_all(dl)
    except e:
        raised = True
        assert_true("deadline" in String(e), String(e))
    assert_true(raised)
    assert_true(_secs(t0) < 6.0, String(_secs(t0)))


def test_flaky_recovers() raises:
    # 503 (Retry-After: 1), 500, 503, then 200.
    var n = 1_500_000
    var t0 = perf_counter_ns()
    var dl = Download(_url(String("/flaky/3/fl1/", n)), _quick(4))
    assert_true(_read_all(dl) == _expected(n))
    assert_equal(_count("fl1"), 4)
    assert_true(_secs(t0) < 10.0, String(_secs(t0)))


def test_flaky_gives_up() raises:
    var raised = False
    try:
        var dl = Download(_url("/flaky/9/fl2/1000"), _quick(2))
        _ = _read_all(dl)
    except e:
        raised = True
        assert_true("gave up after 3 tries" in String(e), String(e))
    assert_true(raised)
    assert_equal(_count("fl2"), 3)


def test_cut_resumes_with_range() raises:
    var n = 2_500_000
    var dl = Download(_url(String("/cut/c1/", n)), _quick(3))
    assert_true(_read_all(dl) == _expected(n))
    assert_equal(_count("c1"), 2)


def test_cut_resumes_without_range() raises:
    var n = 2_500_000
    var dl = Download(_url(String("/cutnorange/c2/", n)), _quick(3))
    assert_true(_read_all(dl) == _expected(n))
    assert_equal(_count("c2"), 2)


def test_missing_hour_is_not_retried() raises:
    var t0 = perf_counter_ns()
    var raised = False
    try:
        var dl = Download(_url("/missing"), _quick(4))
        _ = _read_all(dl)
    except e:
        raised = True
        assert_true("HTTP 404" in String(e), String(e))
    assert_true(raised)
    assert_equal(_count("missing"), 1)
    assert_true(_secs(t0) < 1.0, String(_secs(t0)))


def test_backoff() raises:
    for r in range(8):
        var w = backoff_ms(r)
        var d = min(30_000, 1000 * (1 << r))
        assert_true(w >= d // 2 and w <= d, String(r, ": ", w))
    assert_true(backoff_ms(100) <= 30_000)
    assert_true(retryable_status(503) and retryable_status(429))
    assert_false(retryable_status(404) or retryable_status(403))


def test_timeout_kills_the_group() raises:
    # A command that started a child of its own: both go at the timeout.
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-fetch")
    var t0 = perf_counter_ns()
    var r = _sh(
        String(
            "mkdir -p '",
            dir,
            "'; sleep 30 & echo $! > '",
            dir,
            "/gc'; sleep 30",
        ),
        500,
    )
    assert_equal(r[0], TIMED_OUT)
    assert_equal(r[1], "timed out after 0 s")
    assert_true(_secs(t0) < 3.0, String(_secs(t0)))
    var gc: String
    with open(String(dir, "/gc"), "r") as f:
        gc = String(f.read().strip())
    var alive = String()
    for _ in range(40):
        alive = String(
            run(
                String(
                    "kill -0 ", gc, " 2>/dev/null && echo alive || echo gone"
                )
            ).strip()
        )
        if alive == "gone":
            break
        sleep(0.05)
    assert_equal(alive, "gone")


def test_sh_with_timeout_keeps_output_and_status() raises:
    var s = _sh("printf 'a\\nb'; false", 10_000)
    assert_equal(s[0], 1)
    assert_equal(s[1], "a\nb")
    var u = _sh("printf 'a\\nb'; false")
    assert_equal(u[0], s[0])
    assert_equal(u[1], s[1])


def test_git_stall_is_detected() raises:
    # git's own detector (the `-c http.lowSpeed*` in `git_net`), with a
    # 2 s window: a server that never answers fails the clone in seconds,
    # with `GIT_TIMEOUT_SECONDS` as the backstop.
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-fetch/stall.git")
    var t0 = perf_counter_ns()
    var args = git_net()
    for i in range(len(args)):
        if args[i] == "http.lowSpeedTime=60":
            args[i] = "http.lowSpeedTime=2"
    for a in ["clone", "--quiet", "--bare", _url("/stallhead/x.git"), dir]:
        args.append(a)
    var r = git(args, 20_000, STDERR_MERGE)
    assert_true(r[0] != 0 and r[0] != TIMED_OUT, String(r[0], " ", r[1]))
    assert_true(_secs(t0) < 10.0, String(_secs(t0)))
    assert_true(transient_git_error(r[1]), r[1])
    assert_false(transient_git_error("remote: Repository not found."))
    assert_false(
        transient_git_error(
            "fatal: could not read Username for 'https://github.com'"
        )
    )


def before_tests() raises:
    """A server a run before this one left behind is not this one's."""
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-fetch")
    if exists(String(dir, "/pid")):
        _ = run(String("kill $(cat '", dir, "/pid') 2>/dev/null; true"))
    _ = run(String("rm -rf '", dir, "'"))


def after_tests() raises:
    """Stops the server by the PID it was started as."""
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-fetch")
    if exists(String(dir, "/pid")):
        _ = run(String("kill $(cat '", dir, "/pid') 2>/dev/null; true"))
    _ = run(String("rm -rf '", dir, "'"))


def main() raises:
    # scripts/test.sh, which runs the tests from one binary, calls
    # before_tests and after_tests as this does.
    before_tests()
    var failed = False
    try:
        TestSuite.discover_tests[__functions_in_module()]().run()
    except e:
        failed = True
        print(e)
    after_tests()
    if failed:
        raise Error("test_fetch failed")
