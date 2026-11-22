"""The MCP endpoint's usage events in PostHog, sent from the server (#229).

Every request to `/mcp` becomes one `mcp_request` event (`McpEvent`,
`event_json`): the method, for tools/call the tool and its arguments (each
string cut to `ARG_STRING_MAX` characters, the whole object to
`ARG_OBJECT_MAX` bytes, `trim_arguments`), the client's name and version,
the protocol version, how it went (`ok`, `tool_error`, `rpc_error`,
`rate_limited`), how many results, how long it took and how big the answer
was. No personal data: `distinct_id` is a hash of the client's IP with a
random salt that changes every UTC day (`ClientIds`), and the event asks
PostHog for no person profile, no IP and no GeoIP.

Requests never wait on PostHog: `EventQueue.push` adds the event to a
bounded queue (`QUEUE_MAX`, the oldest dropped when full) and returns, and
`posthog_flusher`, a thread of its own like the console's refreshers, sends
the queue to PostHog's batch API every `FLUSH_SECS` or once `FLUSH_AT`
events wait. A failed send is logged at most once a minute and its events
are dropped. With no `POSTHOG_KEY` (or one that isn't a project key) the
queue is off and nothing is kept or sent.
"""

from std.time import perf_counter_ns, sleep

from hashes import xxh64
from jscan import Range, each, skip_value, skip_ws, text
from threads import Mutex, OpaquePtr

from analytics import is_project_key
from fetch import post_json
from jscan import micros_to_iso


comptime POSTHOG_BATCH = "https://us.i.posthog.com/batch/"
"""PostHog's batch capture API, US region (the page snippet's)."""
comptime QUEUE_MAX = 1000
comptime FLUSH_AT = 100
"""Events per batch, and how many waiting make the flusher send early."""
comptime FLUSH_SECS = 10
comptime ERROR_LOG_SECS = 60
comptime ARG_STRING_MAX = 200
"""Characters kept of each string in a tools/call's arguments."""
comptime ARG_OBJECT_MAX = 1024
"""Bytes kept of the arguments object as a whole."""
comptime CLIENT_FIELD_MAX = 100


def js(s: StringSpan) -> String:
    """`s` as a JSON string, every control character escaped."""
    var out = String('"')
    for cp in s.codepoint_slices():
        var b = cp.as_bytes()
        if len(b) == 1 and b[0] < 0x20:
            var c = Int(b[0])
            if c == 0x0A:
                out += "\\n"
            elif c == 0x09:
                out += "\\t"
            elif c == 0x0D:
                out += "\\r"
            else:
                comptime HEX = "0123456789abcdef"
                out.write("\\u00", HEX[byte = c >> 4], HEX[byte = c & 15])
        elif cp == '"':
            out += '\\"'
        elif cp == "\\":
            out += "\\\\"
        else:
            out += cp
    out += '"'
    return out^


def cut(s: String, n: Int) -> String:
    """The first `n` characters (codepoints) of `s`."""
    if s.byte_length() <= n:
        return s
    var out = String()
    var k = 0
    for cp in s.codepoint_slices():
        if k >= n:
            break
        out += cp
        k += 1
    return out^


def _trim_value(b: Span[UInt8, _], r: Range, depth: Int) -> String:
    """The JSON value at `r` again, its strings cut to `ARG_STRING_MAX`."""
    var i = skip_ws(b, r.start, r.end)
    if i >= r.end:
        return String("null")
    var c = b[i]
    if c == UInt8(ord('"')):
        return js(cut(text(b, Range(i, r.end)), ARG_STRING_MAX))
    if depth > 8:
        return String("null")
    if c == UInt8(ord("[")):
        var out = String("[")
        var first = True
        for e in each(b, Range(i, r.end)):
            out.write("" if first else ",", _trim_value(b, e, depth + 1))
            first = False
        out += "]"
        return out^
    if c == UInt8(ord("{")):
        var out = String("{")
        var first = True
        for m in members(b, Range(i, r.end)):
            out.write(
                "" if first else ",", js(cut(text(b, m.key), ARG_STRING_MAX)), ":",
                _trim_value(b, m.value, depth + 1),
            )
            first = False
        out += "}"
        return out^
    return String(StringSpan(unsafe_from_utf8=b[i : skip_value(b, i, r.end)]))


@fieldwise_init
struct Member(Copyable, ImplicitlyCopyable, Movable):
    var key: Range
    """The key, quotes included."""
    var value: Range


def members(b: Span[UInt8, _], obj: Range) -> List[Member]:
    """The members of the object at `obj`, in order."""
    var out = List[Member]()
    var end = obj.end
    var i = skip_ws(b, obj.start, end)
    if i >= end or b[i] != UInt8(ord("{")):
        return out^
    i += 1
    while i < end:
        i = skip_ws(b, i, end)
        if i >= end or b[i] == UInt8(ord("}")):
            break
        if b[i] == UInt8(ord(",")):
            i += 1
            continue
        if b[i] != UInt8(ord('"')):
            break
        var ks = i
        i = skip_value(b, i, end)
        var ke = i
        i = skip_ws(b, i, end)
        if i >= end or b[i] != UInt8(ord(":")):
            break
        i = skip_ws(b, i + 1, end)
        var vs = i
        i = skip_value(b, i, end)
        out.append(Member(Range(ks, ke), Range(vs, i)))
    return out^


def trim_arguments(b: Span[UInt8, _], args: Range) -> String:
    """A tools/call's `arguments` object for the event: each string cut to
    `ARG_STRING_MAX` characters, then members kept in order while the whole
    stays within `ARG_OBJECT_MAX` bytes (`"_truncated":true` says some were
    left out). "{}" when there are none."""
    if not args.found():
        return String("{}")
    var out = String("{")
    var dropped = False
    comptime MARK = ',"_truncated":true}'
    for m in members(b, args):
        var item = String(js(cut(text(b, m.key), ARG_STRING_MAX)), ":", _trim_value(b, m.value, 0))
        var sep = 0 if out.byte_length() == 1 else 1
        if out.byte_length() + sep + item.byte_length() + MARK.byte_length() > ARG_OBJECT_MAX:
            dropped = True
            continue
        out.write("," if sep else "", item)
    if dropped:
        out += MARK if out.byte_length() > 1 else '"_truncated":true}'
    else:
        out += "}"
    return out^


def client_of_agent(user_agent: String) -> Tuple[String, String]:
    """The client's name and version from a `User-Agent` like
    `claude-code/2.0.1 (darwin)`: its first product token."""
    var ua = String(user_agent.strip())
    var sp = ua.find(" ").or_else(-1)
    var token = String(ua[byte=:sp]) if sp >= 0 else ua
    var slash = token.find("/").or_else(-1)
    if slash < 0:
        return (cut(token, CLIENT_FIELD_MAX), String())
    return (cut(String(token[byte=:slash]), CLIENT_FIELD_MAX), cut(String(token[byte = slash + 1 :]), CLIENT_FIELD_MAX))


@fieldwise_init
struct McpEvent(Copyable, Movable):
    """One `/mcp` request, as PostHog gets it."""

    var distinct_id: String
    """`ClientIds.id_of` the client's IP: never the IP itself."""
    var at_us: Int64
    """When, in microseconds since the epoch."""
    var method: String
    var tool: String
    """tools/call's tool, else ""."""
    var arguments: String
    """tools/call's `trim_arguments`, else ""."""
    var client_name: String
    var client_version: String
    var protocol_version: String
    var status: String
    """`ok`, `tool_error`, `rpc_error` or `rate_limited`."""
    var results: Int
    var duration_ms: Int
    var response_bytes: Int


def event_json(e: McpEvent) -> String:
    """The event as an item of PostHog's batch."""
    var out = String(
        '{"event":"mcp_request","distinct_id":', js(e.distinct_id),
        ',"timestamp":', js(micros_to_iso(e.at_us)),
        ',"properties":{"site":"mojourney","method":', js(e.method),
    )
    if e.tool.byte_length() > 0:
        out.write(',"tool":', js(e.tool), ',"arguments":', e.arguments if e.arguments.byte_length() > 0 else "{}")
    out.write(
        ',"client_name":', js(e.client_name), ',"client_version":', js(e.client_version),
        ',"protocol_version":', js(e.protocol_version), ',"status":', js(e.status),
        ',"results":', e.results, ',"duration_ms":', e.duration_ms,
        ',"response_bytes":', e.response_bytes,
        ',"$process_person_profile":false,"$ip":null,"$geoip_disable":true}}',
    )
    return out^


def batch_json(key: String, events: List[String]) -> String:
    """The body of a POST to `POSTHOG_BATCH`."""
    var out = String('{"api_key":', js(key), ',"batch":[')
    for i in range(len(events)):
        out.write("," if i > 0 else "", events[i])
    out += "]}"
    return out^


def _random_u64() -> UInt64:
    """64 bits from /dev/urandom, else from the clock."""
    try:
        with open("/dev/urandom", "r") as f:
            var bytes = f.read_bytes(8)
            if len(bytes) == 8:
                var v = UInt64(0)
                for k in range(8):
                    v = (v << 8) | UInt64(bytes[k])
                return v
    except:
        pass
    return UInt64(perf_counter_ns()) * 0x9E3779B97F4A7C15


struct ClientIds(Movable):
    """`distinct_id`s: a client IP hashed with a random salt drawn anew for
    each UTC day and kept only in memory, so one client is one id for a day
    and the id can't be turned back into the IP."""

    var _lock: Mutex
    var _day: Int64
    var _salt: UInt64

    def __init__(out self) raises:
        self._lock = Mutex()
        self._day = -1
        self._salt = 0

    def id_of(mut self, ip: String, day: Int64) -> String:
        self._lock.lock()
        if day != self._day:
            self._day = day
            self._salt = _random_u64()
        var salt = self._salt
        self._lock.unlock()
        var h = xxh64(ip.as_bytes(), salt)
        comptime HEX = "0123456789abcdef"
        var out = String("mcp_")
        for k in range(16):
            out += HEX[byte = Int((h >> UInt64(60 - 4 * k)) & 15)]
        return out^


struct EventQueue(Movable):
    """The events waiting for PostHog: at most `cap`, the oldest dropped
    first. `push` and `take` hold the lock only to move strings."""

    var _lock: Mutex
    var _events: List[String]
    var cap: Int
    var key: String
    """The PostHog project key; "" when sending is off."""
    var dropped: Int
    """Events dropped because the queue was full, in all."""

    def __init__(out self, key: String, cap: Int = QUEUE_MAX) raises:
        self._lock = Mutex()
        self._events = List[String]()
        self.cap = cap
        self.key = key if is_project_key(key) else String()
        self.dropped = 0

    def on(self) -> Bool:
        return self.key.byte_length() > 0

    def push(mut self, var event: String):
        if not self.on():
            return
        self._lock.lock()
        while len(self._events) >= self.cap and len(self._events) > 0:
            _ = self._events.pop(0)
            self.dropped += 1
        if self.cap > 0:
            self._events.append(event^)
        self._lock.unlock()

    def count(mut self) -> Int:
        self._lock.lock()
        var n = len(self._events)
        self._lock.unlock()
        return n

    def take(mut self, most: Int = FLUSH_AT) -> List[String]:
        """Up to `most` of the oldest events, removed from the queue."""
        self._lock.lock()
        var n = min(most, len(self._events))
        var out = List[String](capacity=n)
        for k in range(n):
            out.append(self._events[k])
        var rest = List[String](capacity=len(self._events) - n)
        for k in range(n, len(self._events)):
            rest.append(self._events[k])
        self._events = rest^
        self._lock.unlock()
        return out^


def flush(mut q: EventQueue) raises -> Int:
    """Send every waiting event, `FLUSH_AT` to a POST; the number sent.
    Raises on the first batch PostHog doesn't take (its events are dropped)."""
    var sent = 0
    var batch = q.take()
    while len(batch) > 0:
        var status = post_json(POSTHOG_BATCH, batch_json(q.key, batch))
        if status < 200 or status >= 300:
            raise Error("PostHog answered HTTP ", status)
        sent += len(batch)
        batch = q.take()
    return sent


def posthog_flusher(arg: OpaquePtr) -> OpaquePtr:
    """The flusher thread: `arg` is the address of the `EventQueue`, which
    lives as long as the process. It looks every second and sends when
    `FLUSH_SECS` have passed or `FLUSH_AT` events wait."""
    ref q = Pointer[EventQueue, MutUntrackedOrigin](unsafe_from_address=Int(arg))[]
    var last_flush = Int64(perf_counter_ns())
    var last_log = Int64(-1)
    while True:
        sleep(1.0)
        var t = Int64(perf_counter_ns())
        if q.count() < FLUSH_AT and t - last_flush < Int64(FLUSH_SECS) * 1_000_000_000:
            continue
        last_flush = t
        try:
            _ = flush(q)
        except e:
            if last_log < 0 or t - last_log >= Int64(ERROR_LOG_SECS) * 1_000_000_000:
                last_log = t
                print("console: MCP events to PostHog:", e, "; dropped them")
    return arg
