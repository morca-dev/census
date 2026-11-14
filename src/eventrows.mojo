"""An hour's events, a file's worth at a time, held so they take no more
memory than their bytes (magmalake/mojo-census#37).

A 2023 or 2025 hour of GH Archive is about 900 MB to 1 GB of JSON, 200-260K
events, so a file's 50,000 rows hold about 200 MB of payloads. Built as Arrow
columns, a payload column doubles as it grows (a 205 MB column peaked at
485 MB resident), sorting it copied it whole, and the Parquet writer copied
the sorted column again into its one row group: about 1.2-1.4 GB of peak RSS
for one hour, 2 GB or more on the server.

`EventRows` keeps each string column in `CHUNK_BYTES` pieces that never move,
so it holds the rows' bytes and little else. `write_event_files` puts the rows
in (repo, type) order without copying them (a list of row numbers), and writes
each file a row group of at most `GROUP_BYTES` at a time: only that row
group's slice is ever built as Arrow columns, and the writer's own copy is of
the slice. A file has the same rows in the same order as before, in a few row
groups instead of one.
"""

from std.memory import unsafe_memcpy

from iceberg.batch import ColumnBuilder, is_var_width_array
from iceberg.io import FileIO, join_path
from iceberg.kernels import arrow_type_for
from iceberg.manifest import DataFile
from iceberg.schema import Schema
from iceberg.transforms import PartitionSpec
from iceberg.util import uuid4, zero_pad
from iceberg.values import Datum
from iceberg.write import (
    WriteOptions,
    codec_value,
    data_file_from_footer,
    partition_path,
)
from parquet import ListSink, ParquetWriter, RecordBatch, WriterOptions
from parquet.arrow import ArrayData
from parquet_full import AllCodecs

from lake import EVENTS_SCHEMA, ts

comptime CHUNK_BYTES = 1 << 22
"""A string column grows a 4 MB piece at a time (a longer value gets a piece
of its own), so it never reallocates and copies what it has."""

comptime GROUP_BYTES = 1 << 24
"""A row group of an events file holds at most this many bytes of strings
(and at least one row): 16 MB, four 4 MB pages of payload. The Arrow slice,
the Parquet writer's copy of it and its encoding buffers, about six times
this, are what an hour holds beyond its rows. 32 MB made an hour 100-130 MB
bigger and its files 0.5% smaller; 16 MB makes them 1-1.5% bigger than one
row group a file."""

comptime HOUR_MEMORY_MB = 450
"""Memory per hour of GH Archive in flight, in MB, for morca's resource grants
(morca-dev/morca#171: `GHARCHIVE_PARALLEL = "auto"`): a run needs about
300 MB for itself plus this per hour (`GHARCHIVE_PARALLEL`).

Measured on the busiest hours there are (2023-2025: 880 MB-1 GB of JSON,
200-260K events an hour; 2026 hours are a fifth of that) under Linux, 4 vCPUs
and 8 GB (a CAX21's shape), all of 2023-01-10 with GHARCHIVE_PARALLEL equal
to DISTA_WORKER_SLOTS: peak 1.16 GB at 2 hours in flight and 1.83 GB at 4,
where it was 1.97 GB at 2, 2.73 GB at 3 and 3.20 GB at 4 before #37 (about
620-760 MB an hour). One hour alone peaks at 450-510 MB in its own process
(`tools/hour_memory.mojo`), against 1.0-1.35 GB before."""

comptime HOUR_INDEX_MEMORY_MB = 200
"""`HOUR_MEMORY_MB` with `GHARCHIVE_EVENTS=off`: the hour is parsed into
its `HourIndex` alone, with no rows, row groups or zstd contexts, so what
an hour holds is the decode window and the index (a busy hour's 100-150K
repo_hour cells).

Measured with `tools/hour_memory.mojo ... noevents` on 2023-01-10 15:00
(108 MB gzipped, 205,981 events), against `full` on the same hour: peak 285
MB under Linux (aarch64, in Docker) and 297 MB on macOS, against 590 and 545
MB; less the 108 MB of `.json.gz` the tool holds whole, about 180-190 MB an
hour, against 440-480 MB."""


def _meta(schema: Schema, field_id: Int) raises -> ArrayData:
    """An empty column of `schema`'s field, as `ColumnBuilder` types it."""
    var b = ColumnBuilder.of(schema, field_id)
    var a = ArrayData(
        arrow_type_for(b.kind, b.precision, b.scale, b.length), b.name
    )
    a.nullable = b.nullable
    a.field_id = Int32(field_id)
    return a^


struct TextColumn(Movable, Sized):
    """A string column in pieces that never move: row `r` is `size[r]`
    bytes at `at[r]` (piece << 32 | offset) of `pieces`, or null when
    `size[r]` is -1."""

    var meta: ArrayData
    var pieces: List[List[UInt8]]
    var at: List[Int64]
    var size: List[Int32]
    var nulls: Int
    var bytes: Int

    def __init__(out self, schema: Schema, field_id: Int) raises:
        self.meta = _meta(schema, field_id)
        if not is_var_width_array(self.meta):
            raise Error("eventrows: field ", field_id, " is not a string")
        self.pieces = List[List[UInt8]]()
        self.at = List[Int64]()
        self.size = List[Int32]()
        self.nulls = 0
        self.bytes = 0

    def __len__(self) -> Int:
        return len(self.size)

    @always_inline
    def add_bytes(mut self, s: Span[UInt8, _]) raises:
        var n = len(s)
        if n > 0x7FFFFFFF:
            raise Error("gharchive: a string passed 2 GiB")
        var k = len(self.pieces) - 1
        if k < 0 or len(self.pieces[k]) + n > self.pieces[k].capacity():
            self.pieces.append(List[UInt8](capacity=max(CHUNK_BYTES, n)))
            k += 1
        self.at.append((Int64(k) << 32) | Int64(len(self.pieces[k])))
        self.pieces[k].extend(s)
        self.size.append(Int32(n))
        self.bytes += n

    @always_inline
    def add_null(mut self):
        self.at.append(0)
        self.size.append(-1)
        self.nulls += 1

    @always_inline
    def length(self, row: Int) -> Int:
        return max(Int(self.size[row]), 0)

    def array(self, order: Span[Int32, _]) raises -> ArrayData:
        """Rows `order[0]`, `order[1]`, ... as an Arrow string column: a
        validity bit a row, 32-bit offsets, the bytes end to end."""
        var n = len(order)
        var out = ArrayData(self.meta.type.copy(), self.meta.name.copy())
        out.nullable = self.meta.nullable
        out.field_id = self.meta.field_id
        out.length = n
        out.offsets.resize(n + 1, 0)
        out.validity.resize((n + 7) >> 3, 0)
        var total = 0
        for k in range(n):
            total += self.length(Int(order[k]))
        if total > 0x7FFFFFFF:
            raise Error("gharchive: a string column passed 2 GiB in a batch")
        out.values.resize(unsafe_uninit_length=total)
        var dst = out.values.unsafe_ptr()
        var at = 0
        var nulls = 0
        for k in range(n):
            var r = Int(order[k])
            var len_ = Int(self.size[r])
            if len_ < 0:
                nulls += 1
            else:
                out.validity[k >> 3] |= UInt8(1) << UInt8(k & 7)
                if len_ > 0:
                    var a = self.at[r]
                    unsafe_memcpy(
                        dest=dst.unsafe_offset(at),
                        src=self.pieces[Int(a >> 32)]
                        .unsafe_ptr()
                        .unsafe_offset(Int(a & 0xFFFFFFFF)),
                        count=len_,
                    )
                    at += len_
            out.offsets[k + 1] = Int32(at)
        out.null_count = nulls
        return out^


struct LongColumn(Movable):
    """A required 64-bit column (`long`, `timestamptz`)."""

    var meta: ArrayData
    var values: List[Int64]

    def __init__(out self, schema: Schema, field_id: Int) raises:
        self.meta = _meta(schema, field_id)
        self.values = List[Int64]()

    @always_inline
    def add(mut self, v: Int64):
        self.values.append(v)

    def array(self, order: Span[Int32, _]) raises -> ArrayData:
        var n = len(order)
        var out = ArrayData(self.meta.type.copy(), self.meta.name.copy())
        out.nullable = self.meta.nullable
        out.field_id = self.meta.field_id
        out.length = n
        out.validity.resize((n + 7) >> 3, 0)
        for k in range(n):
            out.validity[k >> 3] |= UInt8(1) << UInt8(k & 7)
        out.values.resize(unsafe_uninit_length=n * 8)
        var dst = out.values.unsafe_ptr().unsafe_bitcast[Int64]()
        for k in range(n):
            dst.unsafe_store[alignment=1](k, self.values[Int(order[k])])
        return out^


struct EventRows(Movable, Sized):
    """Rows of `gharchive.events`, in the order they arrived."""

    var id: LongColumn
    var type: TextColumn
    var created: LongColumn
    var repo: TextColumn
    var actor: TextColumn
    var payload: TextColumn

    def __init__(out self) raises:
        var s = Schema.parse(EVENTS_SCHEMA)  # iceberg's, for its builders
        self.id = LongColumn(s, 1)
        self.type = TextColumn(s, 2)
        self.created = LongColumn(s, 3)
        self.repo = TextColumn(s, 4)
        self.actor = TextColumn(s, 5)
        self.payload = TextColumn(s, 6)

    def __len__(self) -> Int:
        return len(self.id.values)

    def row_bytes(self, row: Int) -> Int:
        """What row `row` adds to a row group: its strings and 16 bytes."""
        return (
            16
            + self.type.length(row)
            + self.repo.length(row)
            + self.actor.length(row)
            + self.payload.length(row)
        )

    def batch(self, order: Span[Int32, _]) raises -> RecordBatch:
        """Rows `order[0]`, `order[1]`, ... as a record batch, in the
        schema's column order."""
        var b = RecordBatch()
        b.num_rows = len(order)
        b.roots.append(b.arena.add(self.id.array(order)))
        b.roots.append(b.arena.add(self.type.array(order)))
        b.roots.append(b.arena.add(self.created.array(order)))
        b.roots.append(b.arena.add(self.repo.array(order)))
        b.roots.append(b.arena.add(self.actor.array(order)))
        b.roots.append(b.arena.add(self.payload.array(order)))
        return b^

    def to_batch(self) raises -> RecordBatch:
        """Every row, in arrival order."""
        return self.batch(Span(arrival_order(len(self))))


def arrival_order(n: Int) -> List[Int32]:
    var order = List[Int32](capacity=n)
    for i in range(n):
        order.append(Int32(i))
    return order^


comptime _Bytes = Pointer[UInt8, ImmUntrackedOrigin]


@always_inline
def _compare(a: _Bytes, an: Int, b: _Bytes, bn: Int) -> Int:
    var n = min(an, bn)
    for k in range(n):
        var x = a[unsafe_offset=k]
        var y = b[unsafe_offset=k]
        if x != y:
            return -1 if x < y else 1
    return an - bn


def _keys(c: TextColumn) -> Tuple[List[Int], List[Int]]:
    """Each row's address and length in `c`."""
    var n = len(c)
    var addr = List[Int](capacity=n)
    var size = List[Int](capacity=n)
    for r in range(n):
        var len_ = c.length(r)
        size.append(len_)
        if len_ > 0:
            var a = c.at[r]
            addr.append(
                Int(c.pieces[Int(a >> 32)].unsafe_ptr()) + Int(a & 0xFFFFFFFF)
            )
        else:
            addr.append(0)
    return (addr^, size^)


def order_by_repo_type(rows: EventRows) -> List[Int32]:
    """Row numbers in (repo, type) order, bytewise, as
    `sortrows.order_by_text(batch, "repo", "type")` orders a batch: equal
    keys keep their arrival order (a null sorts as ""), so the same rows
    always make the same file."""
    var order = arrival_order(len(rows))
    var ra = _keys(rows.repo)
    var ta = _keys(rows.type)
    # The closure captures the four arrays by address: `ra` and `ta` live
    # until the sort is done (below).
    var rp = Int(ra[0].unsafe_ptr())
    var rs = Int(ra[1].unsafe_ptr())
    var tp = Int(ta[0].unsafe_ptr())
    var tsz = Int(ta[1].unsafe_ptr())

    def before(x: Int32, y: Int32) {imm rp, imm rs, imm tp, imm tsz} -> Bool:
        var i = Int(x)
        var j = Int(y)
        var pa = Pointer[Int, ImmUntrackedOrigin](unsafe_from_address=rp)
        var sa = Pointer[Int, ImmUntrackedOrigin](unsafe_from_address=rs)
        var c = _compare(
            _Bytes(unsafe_from_address=pa[unsafe_offset=i]),
            sa[unsafe_offset=i],
            _Bytes(unsafe_from_address=pa[unsafe_offset=j]),
            sa[unsafe_offset=j],
        )
        if c != 0:
            return c < 0
        var pb = Pointer[Int, ImmUntrackedOrigin](unsafe_from_address=tp)
        var sb = Pointer[Int, ImmUntrackedOrigin](unsafe_from_address=tsz)
        c = _compare(
            _Bytes(unsafe_from_address=pb[unsafe_offset=i]),
            sb[unsafe_offset=i],
            _Bytes(unsafe_from_address=pb[unsafe_offset=j]),
            sb[unsafe_offset=j],
        )
        if c != 0:
            return c < 0
        return x < y

    sort[stable=True](Span(order), before)
    _ = ra^
    _ = ta^
    return order^


struct FileTarget(Movable):
    """Where `write_event_files` writes: a table's data directory, schema,
    spec and write properties (the fields of an `morca.tables.FileWriter`)."""

    var io: FileIO
    var location: String
    var schema: Schema
    var spec: PartitionSpec
    var sort_order_id: Int
    var options: WriteOptions

    def __init__(
        out self,
        var io: FileIO,
        location: String,
        var schema: Schema,
        var spec: PartitionSpec,
        sort_order_id: Int,
        var options: WriteOptions,
    ):
        self.io = io^
        self.location = location
        self.schema = schema^
        self.spec = spec^
        self.sort_order_id = sort_order_id
        self.options = options^


def _partition(t: FileTarget, rows: EventRows, row: Int) raises -> List[Datum]:
    var values = List[Datum]()
    for ref f in t.spec.fields:
        var v: Datum
        if f.source_id == 3:
            v = ts(rows.created.values[row])
        elif f.source_id == 1:
            v = Datum.long_(rows.id.values[row])
        else:
            raise Error("eventrows: can't partition on field ", f.source_id)
        values.append(f.transform.apply(v))
    return values^


def _key(values: List[Datum]) -> String:
    var k = String()
    for ref v in values:
        k += String("|", Int(v.valid), ":", v.i)
    return k^


def write_event_files(
    t: FileTarget,
    rows: EventRows,
    order: List[Int32],
    group_bytes: Int = GROUP_BYTES,
) raises -> List[DataFile]:
    """Rows `order[0]`, `order[1]`, ... of `rows` into one Parquet file per
    partition they fall in (in the order each partition first appears),
    each file in row groups of at most `group_bytes` of strings. What
    iceberg's `write_data_files` writes of the batch `rows.batch(order)`,
    row for row and in the same order, file for file, but in row groups."""
    var out = List[DataFile]()
    if len(order) == 0:
        return out^
    var keys = Dict[String, Int]()
    var values = List[List[Datum]]()
    var members = List[List[Int32]]()
    for r in order:
        var v = _partition(t, rows, Int(r))
        var k = _key(v)
        var g: Int
        if k in keys:
            g = keys[k]
        else:
            g = len(members)
            keys[k^] = g
            values.append(v^)
            members.append(List[Int32]())
        members[g].append(r)
    var opts = WriterOptions()
    opts.codec = codec_value(t.options.codec)
    opts.row_group_size = t.options.row_group_rows
    opts.data_page_size = t.options.page_size
    opts.compression_level = t.options.compression_level
    opts.use_dictionary = t.options.use_dictionary
    opts.num_workers = t.options.num_workers
    var schema_json = t.schema.to_json()
    for g in range(len(members)):
        ref these = members[g]
        var writer = ParquetWriter[AllCodecs](opts.copy())
        writer.add_metadata("iceberg.schema", schema_json)
        var sink = ListSink()
        var lo = 0
        while lo < len(these):
            var hi = lo
            var size = 0
            while hi < len(these) and hi - lo < opts.row_group_size:
                var b = rows.row_bytes(Int(these[hi]))
                if hi > lo and size + b > group_bytes:
                    break
                size += b
                hi += 1
            var slice = rows.batch(Span(these)[lo:hi])
            writer.write_batch_to(slice.arena, slice.roots, sink)
            lo = hi
        var written = writer^.finish_to(sink)
        var dir = join_path(t.location, "data")
        var rel = partition_path(t.spec, values[g])
        if rel != "":
            dir = join_path(dir, rel)
        var path = join_path(dir, uuid4() + "-" + zero_pad(g, 5) + ".parquet")
        t.io.write_all(path, Span(sink.bytes))
        out.append(
            data_file_from_footer(
                written.metadata,
                written.file_size,
                path,
                t.schema,
                t.spec,
                values[g],
                t.sort_order_id,
                t.options,
            )
        )
    return out^
