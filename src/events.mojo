"""GH Archive hours into `gharchive.events` rows.

`fetch_hour` is the body of gharchive's per-hour dista task: it downloads an
hour (`fetch.Download`), gunzips what has arrived (`decode_index`), parses
the NDJSON lines into columns (`EventParser`, `eventrows.EventRows`) and
hands each full file's rows (`ROWS_PER_BATCH`) to a sink that writes them
into the table (`datafiles.TableWriter`), all at once, so an hour is never
fully in memory, as JSON or as rows (#37). The compressed hour is given back
as it is decoded (`GzInput.release`). The same pass feeds
`hourindex.HourIndex` for the three index tables.

With `GHARCHIVE_EVENTS=off` (`keep_events`) the parser builds no rows at all,
only the index: the hour's index files are the same, byte for byte, and
nothing is written to `gharchive.events`.
"""

from std.os import getenv
from std.time import perf_counter_ns

from morca.tables import Table
from parquet import RecordBatch

from datafiles import BatchSink, DataFiles, TableWriter
from eventrows import EventRows, TextColumn
from days import days_of
from fetch import Download
from deflate import MARGIN, GzipReader, InflateStatus
from gzstream import GzInput, Whole
from hourindex import HourIndex, write_index
from retry import env_int
from jscan import Range, find_newline, scan_event, text, timestamp_micros

comptime ROWS_PER_BATCH = 50_000
"""Rows per batch, which is also the rows of each Parquet file of the
events: the unit that is sorted by (repo, type) and written."""


def keep_events() raises -> Bool:
    """`GHARCHIVE_EVENTS`: `on` (the default) writes each hour's events
    into `gharchive.events`; `off` writes only the three index tables. The
    step and its hour tasks each read it, and the step checks that the
    files a task sends back agree."""
    var v = String(getenv("GHARCHIVE_EVENTS", "on").strip())
    if v == "on" or v.byte_length() == 0:
        return True
    if v == "off":
        return False
    raise Error("GHARCHIVE_EVENTS: on or off, not ", v)


def hour_url(day: String, hour: Int) -> String:
    """`https://data.gharchive.org/2025-09-15-16.json.gz`: hours aren't
    zero-padded in GH Archive's names."""
    var base = getenv("GHARCHIVE_BASE", "https://data.gharchive.org")
    return String(base, "/", day, "-", hour, ".json.gz")


def not_found(err: String) -> Bool:
    """Whether a fetch failed on a 404, which `fetch._open` raises at once,
    without retrying, as `GET <url>: HTTP 404`."""
    return err.endswith(": HTTP 404")


def hour_overdue(day: String, hour: Int, now_s: Int) raises -> Bool:
    """Whether GH Archive should have published the hour by `now_s` (Unix
    seconds): the hour ended more than `GHARCHIVE_MISSING_AFTER_HOURS`
    (default 48) ago. A 404 then is a gap in the archive, such as
    2025-06-12's 17:00 (magmalake/mojo-census#77); a 404 for a more recent
    hour may only mean it isn't published yet, and still fails the day."""
    var ended = Int(days_of(day)) * 86_400 + (hour + 1) * 3_600
    var grace = env_int("GHARCHIVE_MISSING_AFTER_HOURS", 48) * 3_600
    return now_s - ended > grace


def parse_hours(spec: String) raises -> List[Int]:
    """`GHARCHIVE_HOURS`: empty for 0-23, else `A-B` or `A,B,C`. The step
    identifies a committed hour by its place in this list, so the order
    given is the order the hours are committed in."""
    var out = List[Int]()
    if spec.byte_length() == 0:
        for h in range(24):
            out.append(h)
        return out^
    for part in spec.split(","):
        var p = String(part.strip())
        if "-" in p:
            var ab = p.split("-")
            for h in range(Int(ab[0]), Int(ab[1]) + 1):
                out.append(h)
        elif p:
            out.append(Int(p))
    for h in out:
        if h < 0 or h > 23:
            raise Error("GHARCHIVE_HOURS: hour out of range: ", h)
    return out^


def _add_text(mut c: TextColumn, data: Span[UInt8, _], r: Range, null_if_empty: Bool) raises:
    """`text(data, r)` into `c`: an escaped string is decoded, a plain one
    copied as it is; "" (absent, null, empty) is null if `null_if_empty`."""
    var s = r.start + 1
    var e = r.end - 1
    if r.found() and r.end - r.start >= 2 and data[r.start] == 0x22:
        var plain = True
        for k in range(s, e):
            if data[k] == 0x5C:
                plain = False
                break
        if plain:
            if e > s or not null_if_empty:
                c.add_bytes(data[s:e])
            else:
                c.add_null()
            return
    var t = text(data, r)
    if t.byte_length() == 0 and null_if_empty:
        c.add_null()
    else:
        c.add_bytes(t.as_bytes())


def _int(s: String) -> Int64:
    """The digits at the start of `s` as a number (GH Archive's event ids are
    strings in the JSON)."""
    var v = Int64(0)
    for c in s.as_bytes():
        if c < 48 or c > 57:
            return v
        v = v * 10 + Int64(c - 48)
    return v


struct EventsAndIndex(Movable):
    """What a finished parser has: the last files' rows and the hour's
    index."""

    var rows: List[EventRows]
    var index: HourIndex

    def __init__(out self, var rows: List[EventRows], var index: HourIndex):
        self.rows = rows^
        self.index = index^

    def take_rows(deinit self) -> List[EventRows]:
        """The rows, giving up the index."""
        return self.rows^

    def take_batches(deinit self) raises -> List[RecordBatch]:
        """The rows as record batches, in arrival order."""
        var out = List[RecordBatch]()
        for i in range(len(self.rows)):
            out.append(self.rows[i].to_batch())
        return out^

    def take_index(deinit self) -> HourIndex:
        """The index, giving up the rows."""
        return self.index^


struct EventParser(Movable):
    """NDJSON lines of an hour, fed a chunk of whole lines at a time, into
    `EventRows` of `ROWS_PER_BATCH` (each a file of `gharchive.events`)."""

    var out: List[EventRows]
    var cols: EventRows
    var rows: Int
    var bad: Int
    var index: HourIndex
    var indexing: Bool
    """Whether `index` takes every event (candidates, counts, releases)."""
    var keep_rows: Bool
    """Whether the events become rows; without them (`GHARCHIVE_EVENTS=off`)
    only `index` is filled and no file's rows are ever held."""

    def __init__(
        out self, indexing: Bool = False, keep_rows: Bool = True
    ) raises:
        self.out = List[EventRows]()
        self.cols = EventRows()
        self.rows = 0
        self.bad = 0
        self.index = HourIndex()
        self.indexing = indexing
        self.keep_rows = keep_rows

    def feed(mut self, data: Span[UInt8, _], begin: Int, n: Int) raises:
        """The lines in `data[begin:n]`; a last line without its newline is
        parsed as a whole one."""
        var start = begin
        while start < n:
            var end = find_newline(data, start, n)
            if end > start:
                self._line(data, Range(start, end))
            start = end + 1

    def _line(mut self, data: Span[UInt8, _], line: Range) raises:
        """One event: its fields are located by a single scan of the line
        (`jscan.scan_event`, no JSON tree), and each is copied into its
        column. The payload is kept as the event's raw JSON text."""
        var f = scan_event(data, line)
        if not (f.id.found() and f.created_at.found()):
            self.bad += 1
            return
        if not self.keep_rows:
            # The index alone, from the same fields as below.
            if self.indexing:
                var p = f.payload
                self.index.add(
                    text(data, f.type),
                    text(data, f.repo_name),
                    text(data, f.actor_login),
                    timestamp_micros(data, f.created_at),
                    data[p.start : p.end] if p.found() else data[0:0],
                )
            self.rows += 1
            return
        self.cols.id.add(_int(text(data, f.id)))
        _add_text(self.cols.type, data, f.type, False)
        var at = timestamp_micros(data, f.created_at)
        self.cols.created.add(at)
        _add_text(self.cols.repo, data, f.repo_name, False)
        _add_text(self.cols.actor, data, f.actor_login, True)
        var p = f.payload
        if self.indexing:
            self.index.add(
                text(data, f.type),
                text(data, f.repo_name),
                text(data, f.actor_login),
                at,
                data[p.start : p.end] if p.found() else data[0:0],
            )
        if p.found():
            self.cols.payload.add_bytes(data[p.start : p.end])
        else:
            self.cols.payload.add_null()
        self.rows += 1
        # A full file's rows are moved to `out` and fresh columns started;
        # `decode_index` drains `out` to the sink after every window, so full
        # files don't pile up.
        if self.rows % ROWS_PER_BATCH == 0:
            var full = EventRows()
            swap(full, self.cols)
            self.out.append(full^)

    def finish(deinit self) raises -> List[RecordBatch]:
        """The batches, with the last partial one, dropping the index."""
        var both = self^.finish_index()
        return both^.take_batches()

    def finish_index(deinit self) raises -> EventsAndIndex:
        """The last files' rows, and what `index` collected."""
        var out = self.out^
        if self.keep_rows and self.rows % ROWS_PER_BATCH != 0:
            out.append(self.cols^)
        else:
            _ = self.cols^
        if self.bad > 0:
            print("gharchive: skipped", self.bad, "lines without id or created_at")
        return EventsAndIndex(out^, self.index^)


def parse_events(data: Span[UInt8, _]) raises -> List[RecordBatch]:
    """One NDJSON hour, decompressed, as batches of `ROWS_PER_BATCH`."""
    var p = EventParser()
    p.feed(data, 0, len(data))
    return p^.finish()


comptime CHUNK = 1 << 23
"""JSON decoded per step (8 MiB): the window the parser reads lines from.
The decoder's output buffer is twice this and is compacted after each
window, so the decoded JSON in memory stays about this size however big
the hour is."""


struct NoRows(BatchSink, Movable):
    """A sink for a parser that builds no rows (`keep_rows=False`): it is
    never given any."""

    def __init__(out self):
        pass

    def put(mut self, var rows: EventRows) raises:
        raise Error("gharchive: rows for an hour that keeps none")


struct Collect(BatchSink, Movable):
    """Keeps the rows, as record batches in arrival order (a sink for tests
    and tools that want them all)."""

    var batches: List[RecordBatch]

    def __init__(out self):
        self.batches = List[RecordBatch]()

    def put(mut self, var rows: EventRows) raises:
        self.batches.append(rows.to_batch())


@fieldwise_init
struct Timing(Copyable, Movable):
    """Milliseconds in gunzip, in parsing (building columns included), and
    waiting for input still downloading."""

    var gunzip_ms: Int
    var parse_ms: Int
    var wait_ms: Int


# `decode_gz` and `decode_index` are generic over the input (`GzInput`: a
# whole buffer, or a download still arriving) and the sink (`BatchSink`: where
# full batches go), so the same loop serves tests, tools and the hour task.


def _drain[S: BatchSink](mut p: EventParser, mut sink: S) raises -> Int:
    """Hands the parser's full batches to `sink`; the time it took, in ns."""
    if len(p.out) == 0:
        return 0
    var t0 = perf_counter_ns()
    var full = List[EventRows]()
    swap(full, p.out)
    for i in range(len(full)):
        var b = EventRows()
        swap(b, full[i])
        sink.put(b^)
    return Int(perf_counter_ns() - t0)


def parse_gz[S: BatchSink](gz: Span[UInt8, _], mut sink: S) raises -> Timing:
    """A whole `.json.gz` hour into `sink` (see `decode_gz`)."""
    return decode_gz(Whole(gz), sink)


def decode_gz[
    I: GzInput, S: BatchSink
](input: I, mut sink: S) raises -> Timing:
    """`decode_index` without the index."""
    var none = HourIndex()
    return decode_index(input, sink, none, False)


def decode_index[
    I: GzInput, S: BatchSink
](
    input: I,
    mut sink: S,
    mut index: HourIndex,
    indexing: Bool,
    keep_rows: Bool = True,
) raises -> Timing:
    """A `.json.gz` hour, gunzipped a window at a time into the parser, so
    the hour's JSON is never in memory at once; each batch goes to `sink`
    as soon as it is full. The input may still be arriving: what is there
    is decoded, and the wait is only for what the inflater needs next.
    Without `keep_rows` the sink gets nothing and only `index` is built."""
    var t_start = perf_counter_ns()
    var inflate_ns = 0
    var sink_ns = 0
    var wait_ns = 0
    var gz = GzipReader(CHUNK * 2)
    var p = EventParser(indexing, keep_rows)
    # `lo` is where the parser has got to in the decoder's output: lines
    # before it are done and can be dropped. Each round inflates up to about
    # CHUNK more bytes of what has arrived, parses the whole lines among
    # them, moves the unparsed tail of a line to the front (`compact`), hands
    # finished batches to the sink, and, if the inflater ran out of input,
    # waits for the download to supply more.
    var lo = 0
    while True:
        var complete = input.complete()
        var have = input.have()
        var t0 = perf_counter_ns()
        # At least a little more than is there, should a line outgrow CHUNK.
        var st = gz.run(
            input.view(have), complete, max(lo + CHUNK, len(gz) + (1 << 20))
        )
        inflate_ns += Int(perf_counter_ns() - t0)
        input.release(gz.input_used())
        if st == InflateStatus.FINISHED:
            p.feed(gz.output(), lo, len(gz))
            break
        # The window ends mid-line: parse up to the last newline and keep
        # the partial line for the next round.
        var nl = len(gz) - 1
        while nl >= lo and gz.output()[nl] != 0x0A:
            nl -= 1
        if nl >= lo:
            p.feed(gz.output(), lo, nl + 1)
            lo = nl + 1
        lo -= gz.compact(lo)
        sink_ns += _drain(p, sink)
        if st == InflateStatus.NEED_INPUT:
            var t1 = perf_counter_ns()
            _ = input.wait(gz.input_used() + MARGIN)
            wait_ns += Int(perf_counter_ns() - t1)
    # The parser's index replaces the caller's by `swap`; the caller's
    # `marker` (set before parsing) is put back.
    var marker = index.marker
    var done = p^.finish_index()
    swap(index, done.index)
    index.marker = marker
    var rest = done^.take_rows()
    var t1 = perf_counter_ns()
    for i in range(len(rest)):
        var b = EventRows()
        swap(b, rest[i])
        sink.put(b^)
    sink_ns += Int(perf_counter_ns() - t1)
    var total = Int(perf_counter_ns() - t_start)
    return Timing(
        inflate_ns // 1_000_000,
        (total - inflate_ns - sink_ns - wait_ns) // 1_000_000,
        wait_ns // 1_000_000,
    )


def decode_hour[
    I: GzInput
](
    input: I,
    var events: Optional[TableWriter],
    candidates: Table,
    repo_hour: Table,
    releases: Table,
) raises -> DataFiles:
    """An hour's `.json.gz` into its files, uncommitted: the events through
    `events` if given, and the three index tables. Without `events`
    (`GHARCHIVE_EVENTS=off`) the parser builds only the index, from the
    same parse, so the index files are the same as with it."""
    # No marker rows: the step commits the index a day at a time.
    var index = HourIndex()
    var out: DataFiles
    var timing: Timing
    if events:
        var w = events.take()
        timing = decode_index(input, w, index, True)
        out = w^.finish()
    else:
        var none = NoRows()
        timing = decode_index(input, none, index, True, keep_rows=False)
        out = DataFiles()
        out.rows = index.events
    var t_index = perf_counter_ns()
    out.index = write_index(index, candidates, repo_hour, releases)
    out.index_ms = Int(perf_counter_ns() - t_index) // 1_000_000
    out.gunzip_ms = timing.gunzip_ms
    out.parse_ms = timing.parse_ms
    out.wait_ms = timing.wait_ms
    return out^


def fetch_hour(
    day: String,
    hour: Int,
    table: Optional[Table],
    candidates: Table,
    repo_hour: Table,
    releases: Table,
) raises -> DataFiles:
    """Downloads one hour of GH Archive and, as it arrives, decompresses
    and parses it and writes it into `table`'s data files (none without a
    `table`: `GHARCHIVE_EVENTS=off`) and the index tables'; returns them
    uncommitted."""
    var t0 = perf_counter_ns()
    # The download starts on its own thread here and the decoding below
    # overlaps it (`timing.wait_ms` is the time the decoder waited on it).
    var dl = Download(hour_url(day, hour))
    # Each 50,000-row file is in (repo, type) order: a repository's events
    # repeat its URLs, and rows that resemble each other share a page. On
    # real files that is 7% smaller than (type, repo), 18% than arrival order.
    var w = Optional[TableWriter]()
    if table:
        w = TableWriter(table.value())
    var out = decode_hour(dl, w^, candidates, repo_hour, releases)
    out.download_ms = dl.ms()
    out.total_ms = Int(perf_counter_ns() - t0) // 1_000_000
    return out^
