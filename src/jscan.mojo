"""A small, allocation-free JSON scanner for GH Archive lines.

GH Archive events are one JSON object per line. We need six top-level
fields and the payload *as written*, so instead of building a DOM we walk
the bytes once and hand back the byte range of each value. `field` finds a
key in an object; `text` decodes a string value. `scan_event` finds all the
fields gharchive stores in one pass over a line, stepping over string
contents and nested values sixteen bytes at a time.
"""

from std.bit import count_trailing_zeros
from std.memory.unsafe import pack_bits


@fieldwise_init
struct Range(Copyable, ImplicitlyCopyable, Movable):
    """A value's bytes, `[start, end)`; `start < 0` when it was absent."""

    var start: Int
    var end: Int

    def found(self) -> Bool:
        return self.start >= 0


comptime _QUOTE = UInt8(ord('"'))
comptime _BSLASH = UInt8(ord("\\"))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACK = UInt8(ord("["))
comptime _RBRACK = UInt8(ord("]"))
comptime _COLON = UInt8(ord(":"))
comptime _COMMA = UInt8(ord(","))


@always_inline
def skip_ws(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    while i < end:
        var c = b[i]
        if c != 0x20 and c != 0x0A and c != 0x0D and c != 0x09:
            return i
        i += 1
    return i


@always_inline
def skip_string(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """`i` at the opening quote; returns the index after the closing one."""
    i += 1
    while i < end:
        var c = b[i]
        if c == _BSLASH:
            i += 2
            continue
        if c == _QUOTE:
            return i + 1
        i += 1
    return end


def skip_value(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """`i` at a value's first byte; returns the index after it."""
    if i >= end:
        return end
    var c = b[i]
    if c == _QUOTE:
        return skip_string(b, i, end)
    if c == _LBRACE or c == _LBRACK:
        var depth = 0
        while i < end:
            c = b[i]
            if c == _QUOTE:
                i = skip_string(b, i, end)
                continue
            if c == _LBRACE or c == _LBRACK:
                depth += 1
            elif c == _RBRACE or c == _RBRACK:
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        return end
    # number, true, false, null
    while i < end:
        c = b[i]
        if c == _COMMA or c == _RBRACE or c == _RBRACK or c == 0x20 or c == 0x0A:
            return i
        i += 1
    return end


def _key_is(b: Span[UInt8, _], ks: Int, ke: Int, key: StringSpan) -> Bool:
    """Whether the string at `[ks, ke)` (quotes included) is exactly `key`."""
    var kb = key.as_bytes()
    var n = len(kb)
    if ke - ks - 2 != n:
        return False
    for k in range(n):
        if b[ks + 1 + k] != kb[k]:
            return False
    return True


def field(b: Span[UInt8, _], obj: Range, key: StringSpan) -> Range:
    """The value of `key` in the object at `obj`, or a range not found."""
    var end = obj.end
    var i = skip_ws(b, obj.start, end)
    if i >= end or b[i] != _LBRACE:
        return Range(-1, -1)
    i += 1
    while i < end:
        i = skip_ws(b, i, end)
        if i >= end or b[i] == _RBRACE:
            break
        if b[i] == _COMMA:
            i += 1
            continue
        if b[i] != _QUOTE:
            break
        var ks = i
        i = skip_string(b, i, end)
        var ke = i
        i = skip_ws(b, i, end)
        if i >= end or b[i] != _COLON:
            break
        i = skip_ws(b, i + 1, end)
        var vs = i
        i = skip_value(b, i, end)
        if _key_is(b, ks, ke, key):
            return Range(vs, i)
    return Range(-1, -1)


comptime _W = 16
comptime _V = SIMD[DType.uint8, _W]


@always_inline
def find_newline(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """The index of the next `\\n` at or after `i`, or `end`."""
    var p = b.unsafe_ptr()
    while i + _W <= end:
        var m = pack_bits[dtype=DType.uint16](
            p.unsafe_load[width=_W](i).eq(_V(0x0A))
        )
        if m != 0:
            return i + Int(count_trailing_zeros(m))
        i += _W
    while i < end and p[unsafe_offset=i] != 0x0A:
        i += 1
    return i


@always_inline
def _skip_string_fast(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """`skip_string`, sixteen bytes at a time between quotes and escapes."""
    var p = b.unsafe_ptr()
    i += 1
    while True:
        if i + _W <= end:
            var c = p.unsafe_load[width=_W](i)
            var m = pack_bits[dtype=DType.uint16](
                c.eq(_V(_QUOTE)) | c.eq(_V(_BSLASH))
            )
            if m == 0:
                i += _W
                continue
            i += Int(count_trailing_zeros(m))
        elif i >= end:
            return end
        var c = p[unsafe_offset=i]
        if c == _BSLASH:
            i += 2
            continue
        if c == _QUOTE:
            return i + 1
        i += 1


def _skip_value_fast(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """`skip_value`, stepping over runs of bytes that can't open, close or
    quote anything sixteen at a time."""
    if i >= end:
        return end
    var p = b.unsafe_ptr()
    var c = p[unsafe_offset=i]
    if c == _QUOTE:
        return _skip_string_fast(b, i, end)
    if c != _LBRACE and c != _LBRACK:
        return skip_value(b, i, end)
    var depth = 0
    while i < end:
        if i + _W <= end:
            var v = p.unsafe_load[width=_W](i)
            var m = pack_bits[dtype=DType.uint16](
                v.eq(_V(_QUOTE))
                | v.eq(_V(_LBRACE))
                | v.eq(_V(_RBRACE))
                | v.eq(_V(_LBRACK))
                | v.eq(_V(_RBRACK))
            )
            if m == 0:
                i += _W
                continue
            i += Int(count_trailing_zeros(m))
        c = p[unsafe_offset=i]
        if c == _QUOTE:
            i = _skip_string_fast(b, i, end)
            continue
        if c == _LBRACE or c == _LBRACK:
            depth += 1
        elif c == _RBRACE or c == _RBRACK:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return end


@fieldwise_init
struct EventFields(Copyable, ImplicitlyCopyable, Movable):
    """Where an event's stored fields are in its line."""

    var id: Range
    var type: Range
    var created_at: Range
    var repo_name: Range
    var actor_login: Range
    var payload: Range


@always_inline
def _is(b: Span[UInt8, _], ks: Int, ke: Int, key: StaticString) -> Bool:
    return _key_is(b, ks, ke, key)


def scan_event(b: Span[UInt8, _], line: Range) -> EventFields:
    """`field(line, "id")`, `"type"`, `"created_at"`, `"payload"`,
    `path(line, "repo", "name")` and `path(line, "actor", "login")` in one
    walk of the line's top-level object, with `field`'s rules: the first
    occurrence of a key wins, and a malformed object ends the walk."""
    var none = Range(-1, -1)
    var out = EventFields(none, none, none, none, none, none)
    var end = line.end
    var i = skip_ws(b, line.start, end)
    if i >= end or b[i] != _LBRACE:
        return out
    var repo = none
    var actor = none
    i += 1
    while i < end:
        i = skip_ws(b, i, end)
        if i >= end or b[i] == _RBRACE:
            break
        if b[i] == _COMMA:
            i += 1
            continue
        if b[i] != _QUOTE:
            break
        var ks = i
        i = _skip_string_fast(b, i, end)
        var ke = i
        i = skip_ws(b, i, end)
        if i >= end or b[i] != _COLON:
            break
        i = skip_ws(b, i + 1, end)
        var vs = i
        i = _skip_value_fast(b, i, end)
        var v = Range(vs, i)
        var klen = ke - ks - 2
        if klen == 2:
            if not out.id.found() and _is(b, ks, ke, "id"):
                out.id = v
        elif klen == 4:
            if not out.type.found() and _is(b, ks, ke, "type"):
                out.type = v
            elif not repo.found() and _is(b, ks, ke, "repo"):
                repo = v
        elif klen == 5:
            if not actor.found() and _is(b, ks, ke, "actor"):
                actor = v
        elif klen == 7:
            if not out.payload.found() and _is(b, ks, ke, "payload"):
                out.payload = v
        elif klen == 10:
            if not out.created_at.found() and _is(b, ks, ke, "created_at"):
                out.created_at = v
    if repo.found():
        out.repo_name = field(b, repo, "name")
    if actor.found():
        out.actor_login = field(b, actor, "login")
    return out


def path(b: Span[UInt8, _], obj: Range, a: StringSpan, c: StringSpan) -> Range:
    """`obj[a][c]`."""
    var r = field(b, obj, a)
    if not r.found():
        return r
    return field(b, r, c)


def _hex(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return 0


def _put_utf8(mut out: List[UInt8], cp: Int):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def text(b: Span[UInt8, _], r: Range) -> String:
    """A string value, decoded; a non-string value as written; "" if absent
    or null."""
    if not r.found() or r.end <= r.start:
        return String()
    if b[r.start] != _QUOTE:
        if r.end - r.start == 4 and b[r.start] == UInt8(ord("n")):
            return String()
        return String(StringSpan(unsafe_from_utf8=b[r.start : r.end]))
    var s = r.start + 1
    var e = r.end - 1
    var plain = True
    for k in range(s, e):
        if b[k] == _BSLASH:
            plain = False
            break
    if plain:
        return String(StringSpan(unsafe_from_utf8=b[s:e]))
    var out = List[UInt8](capacity=e - s)
    var i = s
    while i < e:
        var c = b[i]
        if c != _BSLASH or i + 1 >= e:
            out.append(c)
            i += 1
            continue
        var n = b[i + 1]
        i += 2
        if n == UInt8(ord("n")):
            out.append(0x0A)
        elif n == UInt8(ord("t")):
            out.append(0x09)
        elif n == UInt8(ord("r")):
            out.append(0x0D)
        elif n == UInt8(ord("b")):
            out.append(0x08)
        elif n == UInt8(ord("f")):
            out.append(0x0C)
        elif n == UInt8(ord("u")) and i + 4 <= e:
            var cp = (_hex(b[i]) << 12) | (_hex(b[i + 1]) << 8) | (
                _hex(b[i + 2]) << 4
            ) | _hex(b[i + 3])
            i += 4
            if cp >= 0xD800 and cp < 0xDC00 and i + 6 <= e and b[i] == _BSLASH:
                var lo = (_hex(b[i + 2]) << 12) | (_hex(b[i + 3]) << 8) | (
                    _hex(b[i + 4]) << 4
                ) | _hex(b[i + 5])
                if lo >= 0xDC00 and lo < 0xE000:
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    i += 6
            _put_utf8(out, cp)
        else:
            out.append(n)
    return String(unsafe_from_utf8=out)


def raw(b: Span[UInt8, _], r: Range) -> String:
    """A value's bytes as written."""
    if not r.found():
        return String()
    return String(StringSpan(unsafe_from_utf8=b[r.start : r.end]))


def each(b: Span[UInt8, _], arr: Range) -> List[Range]:
    """The elements of the array at `arr`."""
    var out = List[Range]()
    var end = arr.end
    var i = skip_ws(b, arr.start, end)
    if i >= end or b[i] != _LBRACK:
        return out^
    i += 1
    while i < end:
        i = skip_ws(b, i, end)
        if i >= end or b[i] == _RBRACK:
            break
        if b[i] == _COMMA:
            i += 1
            continue
        var s = i
        i = skip_value(b, i, end)
        out.append(Range(s, i))
    return out^


def days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 (Howard Hinnant's algorithm)."""
    var y = y0 - 1 if m <= 2 else y0
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m + 9 if m <= 2 else m - 3
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _digits(b: Span[UInt8, _], s: Int, n: Int) -> Int:
    var v = 0
    for k in range(n):
        v = v * 10 + Int(b[s + k]) - 48
    return v


def timestamp_micros(b: Span[UInt8, _], r: Range) -> Int64:
    """`"YYYY-MM-DDTHH:MM:SSZ"` as microseconds since the epoch, UTC."""
    var s = r.start + 1
    if not r.found() or r.end - r.start < 21:
        return 0
    var days = days_from_civil(
        _digits(b, s, 4), _digits(b, s + 5, 2), _digits(b, s + 8, 2)
    )
    var secs = days * 86400 + _digits(b, s + 11, 2) * 3600 + _digits(
        b, s + 14, 2
    ) * 60 + _digits(b, s + 17, 2)
    return Int64(secs) * 1_000_000


def micros_to_iso(us: Int64) -> String:
    """Microseconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ`."""
    var secs = Int(us // 1_000_000)
    var days = secs // 86400
    var rem = secs - days * 86400
    # civil_from_days
    var z = days + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return String(
        y, "-", _pad(m), "-", _pad(d), "T", _pad(rem // 3600), ":",
        _pad((rem // 60) % 60), ":", _pad(rem % 60), "Z",
    )


def _pad(v: Int) -> String:
    if v < 10:
        return String("0", v)
    return String(v)
