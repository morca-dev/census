"""HTTP: GH Archive files, GitHub's REST API and raw files, and whether a
package is on anaconda.org (`head_status`).

Uses flare's blocking `HttpClient`, with a read timeout as well as the
connect timeout: without one a stalled connection blocks a read forever
(#49). `Download`, GH Archive's, also retries and resumes (`HttpSettings`,
`retry`). GitHub calls send `GITHUB_TOKEN` when it
is set (morca gives runs the secret registered with `--secret`); without it
the REST API allows 60 requests an hour, which is enough for a local run.
"""

from std.ffi import external_call
from std.memory import unsafe_memcpy
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.os.path import exists
from std.sys.info import CompilationTarget
from std.time import perf_counter_ns, sleep

from flare.http import HttpClient, HttpStreamResponse, Request, Response
from flare.tls import TlsConfig
from gzstream import GzInput
from retry import backoff_ms, env_int, log_retry, now_ms, retryable_status
from threads import AtomicCounter, OpaquePtr, ThreadHandle, opaque_ptr

comptime USER_AGENT = "mojo-census (magmalake)"


def _ca_bundle() -> String:
    """A CA bundle path for flare to load: `SSL_CERT_FILE`, else the first
    of the conda and Debian bundles that exists, else "" (OpenSSL's
    default). flare 0.13.2 passes an empty path to OpenSSL without its
    terminating NUL on Linux, so a concrete path avoids that."""
    var env = getenv("SSL_CERT_FILE")
    if env:
        return env
    var prefix = getenv("CONDA_PREFIX")
    var conda = String(prefix, "/ssl/cacert.pem")
    if prefix and exists(conda):
        return conda
    var debian = String("/etc/ssl/certs/ca-certificates.crt")
    if exists(debian):
        return debian
    return String()


def _client(timeout_ms: Int = 30_000, idle_ms: Int = 60_000) raises -> HttpClient:
    """A new blocking client for one call: each call makes its own, so none
    is shared between threads. `timeout_ms` bounds the connect and the TLS
    handshake; `idle_ms` (0 for none) each read, so a connection that goes
    quiet raises `Timeout` instead of blocking forever. flare's `timeout_ms`
    alone never reaches a read (magmalake/mojo-census#49)."""
    var ca = _ca_bundle()
    var c = HttpClient(TlsConfig(ca_bundle=ca), timeout_ms=timeout_ms) if ca else HttpClient(timeout_ms=timeout_ms)
    if idle_ms > 0:
        return c^.with_read_timeout(idle_ms)
    return c^


@fieldwise_init
struct HttpSettings(ImplicitlyCopyable, Movable):
    """Timeouts and retries of a download, in milliseconds (`retry` says
    what each one bounds and their defaults)."""

    var connect_ms: Int
    var idle_ms: Int
    var deadline_ms: Int
    """The whole download, every try and wait included, but not the time
    the reader spends held back by a slow consumer (`_AHEAD`)."""
    var retries: Int
    """Tries after the first."""

    @staticmethod
    def gharchive() -> Self:
        """From `GHARCHIVE_CONNECT_SECONDS`, `GHARCHIVE_IDLE_SECONDS`,
        `GHARCHIVE_TIMEOUT_SECONDS` and `GHARCHIVE_RETRIES`."""
        return Self(
            env_int("GHARCHIVE_CONNECT_SECONDS", 20) * 1000,
            env_int("GHARCHIVE_IDLE_SECONDS", 30) * 1000,
            env_int("GHARCHIVE_TIMEOUT_SECONDS", 900) * 1000,
            env_int("GHARCHIVE_RETRIES", 4),
        )


def get_bytes(url: String, timeout_ms: Int = 600_000) raises -> List[UInt8]:
    """The body of a GET, raising on any status but 200."""
    var c = _client(timeout_ms)
    var req = Request(method="GET", url=url)
    req.headers.set("User-Agent", USER_AGENT)
    var resp = c.send(req)
    if resp.status != 200:
        raise Error("GET ", url, ": HTTP ", resp.status)
    var body = List[UInt8]()
    swap(body, resp.body)
    return body^


comptime _AHEAD = 1 << 25
"""How far the reader thread may run ahead of what the decoder released:
32 MB of compressed input, a few seconds of decoding. Beyond it the thread
waits, and TCP holds the rest of the body back."""

comptime _RELEASE_STEP = 1 << 20
"""`Download.release` gives input back a megabyte at a time: a multiple of
any page size, so every boundary it unmaps at is page-aligned."""


def _map(size: Int) raises -> Int:
    """`size` bytes of fresh anonymous memory (`mmap`), by address."""
    comptime PROT_READ_WRITE: Int = 3
    comptime MAP_PRIVATE: Int = 2
    comptime MAP_ANON: Int = 0x1000 if CompilationTarget.is_macos() else 0x20
    # The signature memory-region declares, which the same program links.
    var p = external_call["mmap", Int](
        0, size, PROT_READ_WRITE, MAP_PRIVATE | MAP_ANON, -1, Int64(0)
    )
    if p == -1 or p == 0:
        raise Error("download: can't map ", size, " bytes")
    return p


def _unmap(addr: Int, size: Int):
    if size > 0:
        _ = external_call["munmap", Int32](addr, size)


struct _Conn(Movable):
    """One request's client and its streaming response (the response reads
    through the client's connection, so the two go together)."""

    var client: HttpClient
    var resp: HttpStreamResponse

    def __init__(out self, var client: HttpClient, var resp: HttpStreamResponse):
        self.client = client^
        self.resp = resp^


def _stopping(stop: Int) -> Bool:
    """Whether the `Download` holding the state cell at `stop` (0: none) is
    being dropped."""
    if stop == 0:
        return False
    return AtomicCounter.at(stop).load() == 3


def _retry_wait(
    url: String,
    s: HttpSettings,
    tries: Int,
    deadline: Int,
    err: String,
    retry_after_s: Int,
    stop: Int,
) raises:
    """After a failed try (`tries` made so far): raises if no tries or time
    are left, else logs the retry and waits for it (exponential backoff with
    jitter, or `Retry-After`), returning early if the download is dropped."""
    if tries > s.retries:
        raise Error("GET ", url, ": ", err, " (gave up after ", tries, " tries)")
    var wait = backoff_ms(tries - 1)
    if retry_after_s > 0:
        wait = retry_after_s * 1000
    if now_ms() + wait > deadline:
        raise Error(
            "GET ", url, ": ", err, " (", tries, " tries; no time left in its ",
            s.deadline_ms // 1000, " s deadline)",
        )
    log_retry(String("GET ", url), tries, s.retries + 1, wait, err)
    var until = now_ms() + wait
    while now_ms() < until:
        if _stopping(stop):
            return
        sleep(0.05)


def _content_range(v: String) -> Tuple[Int, Int]:
    """`bytes A-B/T` as (A, T), or (-1, -1)."""
    try:
        if not v.startswith("bytes "):
            return (-1, -1)
        var dash = v.find("-").or_else(-1)
        var slash = v.find("/").or_else(-1)
        if dash < 0 or slash < dash:
            return (-1, -1)
        return (
            Int(String(v[byte=6:dash]).strip()),
            Int(String(v[byte = slash + 1 :]).strip()),
        )
    except:
        return (-1, -1)


def _open(
    url: String,
    offset: Int,
    size: Int,
    s: HttpSettings,
    mut tries: Int,
    deadline: Int,
    stop: Int,
) raises -> _Conn:
    """A GET of `url` from byte `offset` on (`Range`; the whole body when
    0), retried on a connect or read failure, a timeout, 408, 429 and 5xx
    until it answers 200 (206 for a range) or the tries or the deadline run
    out; any other status raises at once (a 404 is an hour GH Archive hasn't
    published). A server that ignores the range and sends all `size` bytes
    again is read past the first `offset`. `tries` counts every try of the
    download, so the budget is the whole download's, not one request's."""
    while True:
        tries += 1
        var final = False
        var err: String
        var retry_after = -1
        try:
            var c = _client(s.connect_ms, s.idle_ms)
            var req = Request(method="GET", url=url)
            req.headers.set("User-Agent", USER_AGENT)
            if offset > 0:
                req.headers.set("Range", String("bytes=", offset, "-"))
            var resp = c.send_streaming(req^)
            var st = resp.status
            if st == 200 or (st == 206 and offset > 0):
                var conn = _Conn(c^, resp^)
                if offset > 0 and st == 206:
                    var cr = _content_range(conn.resp.header("content-range"))
                    if cr[0] != offset or cr[1] != size:
                        final = True
                        raise Error(
                            "asked for bytes ", offset, "- of ", size,
                            " and got ", conn.resp.header("content-range"),
                        )
                elif offset > 0:
                    # The range was ignored: the same body from the start.
                    var cl = conn.resp.header("content-length")
                    if cl and Int(cl) != size:
                        final = True
                        raise Error(
                            "the body changed size from ", size, " to ", cl,
                            " between tries",
                        )
                    var skip = offset
                    while skip > 0:
                        var chunk = conn.resp.read_chunk(min(skip, 1 << 20))
                        if len(chunk) == 0:
                            raise Error("the body ended at ", offset - skip, " bytes")
                        skip -= len(chunk)
                    if skip < 0:
                        final = True
                        raise Error("read past the resume point")
                return conn^
            err = String("HTTP ", st)
            if st == 429 or st == 503:
                var ra = resp.header("retry-after")
                if ra:
                    try:
                        retry_after = Int(ra)
                    except:
                        pass
            if not retryable_status(st):
                final = True
                raise Error(err)
        except e:
            if final:
                raise Error("GET ", url, ": ", e)
            err = String(e)
        _retry_wait(url, s, tries, deadline, err, retry_after, stop)
        if _stopping(stop):
            raise Error("GET ", url, ": dropped")


struct _Shared(Movable):
    """What a download's reader thread and its consumer share. The reader
    writes the body, then publishes progress through `have` and `state` with
    atomic stores; the consumer reads only the first `have` bytes. With a
    `Content-Length` the body goes into `region`, mapped to its full size up
    front so it doesn't move while the reader runs, and the consumer unmaps
    what it is done with (`released`), so the body is never all resident at
    once (#37); without one, into `buf`. A connection that fails mid-body is
    opened again from where it stopped (`_open`), so the consumer sees one
    body whatever happened underneath."""

    var conn: _Conn
    var url: String
    var settings: HttpSettings
    var tries: Int
    """Tries so far, the first request's included."""
    var deadline: Int
    """`now_ms()` past which the download fails; moved on by the time the
    reader is held back for the consumer."""
    var size: Int
    """`Content-Length`, or -1."""
    var buf: List[UInt8]
    """The body when there was no `Content-Length`."""
    var region: Int
    """Otherwise the body is here: `size` bytes mapped for it (`_map`), of
    which the consumer has given the first `released` back (`release`;
    release-stored, as the reader thread reads it)."""
    var released: Int64
    var have: Int64
    """Bytes of the body that have arrived (release-stored by the reader)."""
    var state: Int64
    """0 while reading, 1 done, 2 failed (`err`), 3 asked to stop."""
    var err: String
    var ms: Int64

    def __init__(
        out self,
        var conn: _Conn,
        url: String,
        settings: HttpSettings,
        tries: Int,
        deadline: Int,
        size: Int,
    ):
        self.conn = conn^
        self.url = url
        self.settings = settings
        self.tries = tries
        self.deadline = deadline
        self.size = size
        self.buf = List[UInt8]()
        self.region = 0
        self.released = 0
        self.have = 0
        self.state = 0
        self.err = String()
        self.ms = 0


def _cell(ref v: Int64) -> AtomicCounter:
    """An atomic view of one of `_Shared`'s integers, for the cross-thread
    stores and loads."""
    return AtomicCounter.at(Int(Pointer(to=v)))


def _past_deadline(sh: Pointer[_Shared, MutUntrackedOrigin], at: Int) raises:
    if now_ms() > sh[].deadline:
        raise Error(
            "no end to the body after its ", sh[].settings.deadline_ms // 1000,
            " s deadline (", at, " bytes in, ", sh[].tries, " tries)",
        )


def _pull(arg: OpaquePtr) -> OpaquePtr:
    """The reader thread: the body into `region`, publishing `have` as it
    goes and staying within `_AHEAD` of what the consumer released. With no
    `Content-Length` it reads it all into `buf`, then publishes. A read
    that fails (a reset, an idle timeout, a body cut short) opens the
    connection again from the byte it stopped at, within the tries and the
    deadline the download has left."""
    var sh = Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=Int(arg))
    var stop = Int(Pointer(to=sh[].state))
    var t0 = perf_counter_ns()
    try:
        # No `Content-Length` (chunked): the buffer can't be sized up front,
        # so the body is gathered and published all at once; a failure
        # starts it again from the beginning.
        if sh[].size < 0:
            var all = List[UInt8]()
            while True:
                if _cell(sh[].state).load() == 3:
                    return arg
                _past_deadline(sh, len(all))
                var chunk: List[UInt8]
                try:
                    chunk = sh[].conn.resp.read_chunk(1 << 20)
                except e:
                    _retry_wait(
                        sh[].url, sh[].settings, sh[].tries, sh[].deadline,
                        String(e), -1, stop,
                    )
                    all.clear()
                    sh[].conn = _open(
                        sh[].url, 0, -1, sh[].settings, sh[].tries,
                        sh[].deadline, stop,
                    )
                    continue
                if len(chunk) == 0:
                    break
                all.extend(Span(chunk))
            sh[].buf = all^
            sh[].size = len(sh[].buf)
            _cell(sh[].have).store(Int64(sh[].size))
        else:
            var at = 0
            var dst = Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=sh[].region
            )
            while True:
                # Asked to stop: the `Download` was dropped before the body
                # ended, and its destructor is waiting to join this thread.
                if _cell(sh[].state).load() == 3:
                    return arg
                if at - Int(_cell(sh[].released).load()) >= _AHEAD:
                    # Held back by the consumer, not the network: the
                    # deadline moves on by the wait.
                    var w0 = now_ms()
                    sleep(0.001)
                    sh[].deadline += now_ms() - w0
                    continue
                _past_deadline(sh, at)
                var chunk: List[UInt8]
                try:
                    chunk = sh[].conn.resp.read_chunk(1 << 20)
                    if len(chunk) == 0 and at != sh[].size:
                        raise Error(
                            "the body ended at ", at, " of its ", sh[].size,
                            " bytes",
                        )
                except e:
                    _retry_wait(
                        sh[].url, sh[].settings, sh[].tries, sh[].deadline,
                        String(e), -1, stop,
                    )
                    sh[].conn = _open(
                        sh[].url, at, sh[].size, sh[].settings, sh[].tries,
                        sh[].deadline, stop,
                    )
                    continue
                if len(chunk) == 0:
                    break
                if at + len(chunk) > sh[].size:
                    raise Error("the body is longer than its Content-Length")
                unsafe_memcpy(
                    dest=dst.unsafe_offset(at),
                    src=chunk.unsafe_ptr(),
                    count=len(chunk),
                )
                at += len(chunk)
                _cell(sh[].have).store(Int64(at))
        sh[].ms = Int64(Int(perf_counter_ns() - t0) // 1_000_000)
        _cell(sh[].state).store(1)
    except e:
        sh[].err = String(e)
        _cell(sh[].state).store(2)
    return arg


struct Download(GzInput, Movable):
    """A GET whose body arrives on its own thread while the caller uses
    what has come so far: `wait` for more, `view` the bytes in hand. This
    is what lets an hour task gunzip and parse while the hour is still
    downloading (about 100 MB of gzip), so its time is roughly the longer of
    the two, not their sum, while holding only the part not yet decoded
    (`release`). Its timeouts and retries are `HttpSettings`: a stalled or
    reset connection is retried (from where it stopped), and the download
    fails, rather than hangs, once they run out."""

    var addr: Int
    """The heap `_Shared`, by address: the reader thread holds it too."""
    var thread: ThreadHandle
    var url: String

    def __init__(out self, url: String) raises:
        """`HttpSettings.gharchive()`'s download of `url`."""
        self = Self(url, HttpSettings.gharchive())

    def __init__(out self, url: String, settings: HttpSettings) raises:
        """Sends the request (with its retries) and starts the reader
        thread; raises on a final status (404, any 4xx but 408 and 429) or
        once the tries run out. The body is not read yet."""
        var tries = 0
        var deadline = now_ms() + settings.deadline_ms
        var conn = _open(url, 0, -1, settings, tries, deadline, 0)
        var size = -1
        var cl = conn.resp.header("content-length")
        if cl:
            try:
                size = Int(cl)
            except:
                size = -1
        var p = unsafe_alloc[_Shared](1)
        p.unsafe_write(_Shared(conn^, url, settings, tries, deadline, size))
        if size > 0:
            p[].region = _map(size)
        self.addr = Int(p)
        self.url = url
        self.thread = ThreadHandle.spawn[_pull](opaque_ptr(self.addr))

    @always_inline
    def _sh(self) -> Pointer[_Shared, MutUntrackedOrigin]:
        """The shared state, which lives on the heap so the reader thread can
        hold it while this struct moves."""
        return Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=self.addr)

    def __deinit__(deinit self):
        # Ask the reader to stop between chunks, wait for it, then free.
        var st = _cell(
            Pointer[_Shared, MutUntrackedOrigin](
                unsafe_from_address=self.addr
            )[].state
        )
        if st.load() == 0:
            st.store(3)
        try:
            self.thread.join()
        except:
            pass
        var p = Pointer[_Shared, MutUntrackedOrigin](unsafe_from_address=self.addr)
        if p[].region != 0:
            var gone = Int(p[].released)
            _unmap(p[].region + gone, p[].size - gone)
        p.unsafe_deinit_pointee()
        p.unsafe_free()

    def have(self) raises -> Int:
        """Bytes arrived so far; raises if the download failed."""
        var n = Int(_cell(self._sh()[].have).load())
        if _cell(self._sh()[].state).load() == 2:
            raise Error("GET ", self.url, ": ", self._sh()[].err)
        return n

    def complete(self) raises -> Bool:
        """Whether every byte has arrived."""
        var st = _cell(
            Pointer[_Shared, MutUntrackedOrigin](
                unsafe_from_address=self.addr
            )[].state
        ).load()
        if st == 2:
            raise Error("GET ", self.url, ": ", self._sh()[].err)
        return st == 1

    def view(self, n: Int) -> Span[UInt8, MutUntrackedOrigin]:
        """The first `n` bytes, `n` no more than `have()` returned."""
        if n == 0:
            return Span[UInt8, MutUntrackedOrigin]()
        var at = self._sh()[].region
        if at == 0:
            at = Int(self._sh()[].buf.unsafe_ptr())
        return Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=at),
            length=n,
        )

    def release(self, upto: Int):
        """The decoder is done with the first `upto` bytes (which have
        arrived): give them back to the OS, a megabyte at a time, so an hour
        holds the compressed input not yet decoded rather than all of it
        (100-130 MB in 2023-2025). `view` must not be read below it again."""
        var sh = self._sh()
        if sh[].region == 0:
            return
        var to = min(upto, Int(_cell(sh[].have).load()))
        to -= to % _RELEASE_STEP
        var gone = Int(_cell(sh[].released).load())
        if to > gone:
            _unmap(sh[].region + gone, to - gone)
            _cell(sh[].released).store(Int64(to))

    def wait(self, want: Int) raises -> Int:
        """Blocks until `want` bytes have arrived or all of them have;
        returns how many there are."""
        while True:
            var done = self.complete()
            var n = self.have()
            if done or n >= want:
                return n
            sleep(0.0005)

    def ms(self) -> Int:
        """How long the body took to arrive (once complete)."""
        return Int(self._sh()[].ms)


@fieldwise_init
struct Reply(Movable):
    var status: Int
    var body: String
    var remaining: Int
    """`X-RateLimit-Remaining`: requests left in the current window, or -1
    when the reply didn't say. mojo_repos and mojo_stats use it, with the
    two below, to stop or wait before GitHub refuses a request."""
    var retry_after: Int
    """`Retry-After` in seconds, or -1."""
    var reset: Int
    """`X-RateLimit-Reset` (epoch seconds), or -1."""


def _header_int(resp: Response, name: String) -> Int:
    """A numeric response header, or -1 if it is absent or not a number."""
    var v = resp.headers.get(name)
    if v:
        try:
            return Int(v)
        except:
            pass
    return -1


def github(path: String) raises -> Reply:
    """GET `https://api.github.com<path>`, with the token if there is one.
    Any status comes back as a `Reply` (it does not raise on 403/404/429), so
    that callers can tell a missing repository from a rate limit."""
    var c = _client()
    var req = Request(method="GET", url=String("https://api.github.com", path))
    req.headers.set("User-Agent", USER_AGENT)
    req.headers.set("Accept", "application/vnd.github+json")
    req.headers.set("X-GitHub-Api-Version", "2022-11-28")
    var token = getenv("GITHUB_TOKEN")
    if token:
        req.headers.set("Authorization", String("Bearer ", token))
    var resp = c.send(req)
    return Reply(
        resp.status,
        resp.text(),
        _header_int(resp, "x-ratelimit-remaining"),
        _header_int(resp, "retry-after"),
        _header_int(resp, "x-ratelimit-reset"),
    )


def github_graphql(body: String) raises -> Reply:
    """POST `body` (`{"query": ...}`) to GitHub's GraphQL API with the token.
    A query's cost is in rate-limit points (`rateLimit { cost }`), from a
    budget of its own, not the REST API's."""
    var c = _client()
    var bytes = List[UInt8](body.as_bytes())
    var req = Request(method="POST", url="https://api.github.com/graphql", body=bytes)
    req.headers.set("User-Agent", USER_AGENT)
    req.headers.set("Content-Type", "application/json")
    var token = getenv("GITHUB_TOKEN")
    if token:
        req.headers.set("Authorization", String("Bearer ", token))
    var resp = c.send(req)
    return Reply(
        resp.status,
        resp.text(),
        _header_int(resp, "x-ratelimit-remaining"),
        _header_int(resp, "retry-after"),
        _header_int(resp, "x-ratelimit-reset"),
    )


def raw_file(repo: String, branch: String, file: String) raises -> String:
    """A file from raw.githubusercontent.com, or "" if it isn't there. These
    requests are not part of the REST API's rate limit and send no token."""
    var c = _client()
    var url = String(
        "https://raw.githubusercontent.com/", repo, "/", branch, "/", file
    )
    var req = Request(method="GET", url=url)
    req.headers.set("User-Agent", USER_AGENT)
    var resp = c.send(req)
    if resp.status != 200:
        return String()
    return resp.text()


def head_status(url: String, timeout_ms: Int = 30_000) raises -> Int:
    """The status a HEAD request to `url` gets, without the body (mojo_stats
    asks anaconda.org whether a package exists, whose GET answers can be
    megabytes). Connect and each read are bounded by `timeout_ms`."""
    var c = _client(timeout_ms, timeout_ms)
    var req = Request(method="HEAD", url=url)
    req.headers.set("User-Agent", USER_AGENT)
    return c.send(req).status


def post_json(url: String, body: String, timeout_ms: Int = 10_000) raises -> Int:
    """POST the JSON `body` to `url`; the status. Connect and each read are
    bounded by `timeout_ms` (the console's PostHog events, `mcp_events`)."""
    var c = _client(timeout_ms, timeout_ms)
    var req = Request(method="POST", url=url, body=List[UInt8](body.as_bytes()))
    req.headers.set("User-Agent", USER_AGENT)
    req.headers.set("Content-Type", "application/json")
    return c.send(req).status
