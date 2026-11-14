"""An hour's files have the rows they had before #37, in the same order.

`write_event_files` writes a file a row group at a time from rows held in
pieces; before, the whole batch was sorted (`sortrows.sorted_by_text`) and
written by iceberg's `write_data_files` as one row group. The same rows go
in, so the same files must come out, row for row.

    pixi run test
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from iceberg.io import FileIO
from iceberg.manifest import DataFile
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from iceberg.write import WriteOptions, write_data_files
from parquet import ParquetReader, RecordBatch
from parquet_full import AllCodecs

from cols import i64_at, is_valid, str_at
from eventrows import (
    CHUNK_BYTES,
    EventRows,
    FileTarget,
    TextColumn,
    order_by_repo_type,
    write_event_files,
)
from events import EventParser
from lake import EVENTS_SCHEMA, events_properties
from sortrows import order_by_text, sorted_by_text



def events_schema() raises -> Schema:
    """gharchive.events' schema as iceberg's, which the events writer
    (`eventrows`) and `write_data_files` take."""
    return Schema.parse(EVENTS_SCHEMA)


def events_spec() raises -> PartitionSpec:
    """`lake.events_spec`, as iceberg's."""
    return PartitionSpec(
        0,
        [PartitionField.single(3, 1000, "created_day", parse_transform("day"))],
    )

def _lines(n: Int) -> List[UInt8]:
    """Events over two days, with escapes, null actors, missing and
    repeated payloads, repositories and types in no order."""
    var s = String()
    for i in range(n):
        var payload: String
        if i % 17 == 0:
            payload = ""
        elif i % 5 == 0:
            payload = String(',"payload":{"action":"started"}')
        else:
            payload = String(
                ',"payload":{"n":',
                i,
                ',"text":"',
                String('a\\"b') * (i % 31),
                String("x") * ((i * 37) % 900),
                '"}',
            )
        s += String(
            '{"id":"',
            7000 + i,
            '","type":"T',
            (i * 7) % 6,
            '","actor":{"login":"',
            "" if i % 9 == 0 else String("u", i % 23),
            '"},"repo":{"name":"o/r',
            (i * 11) % 97,
            '"}',
            payload,
            ',"created_at":"2025-01-0',
            2 if i % 3 == 0 else 1,
            "T23:0",
            i % 10,
            ':00Z"}\n',
        )
    return List[UInt8](s.as_bytes())


def _rows(json: List[UInt8]) raises -> List[EventRows]:
    var p = EventParser()
    p.feed(Span(json), 0, len(json))
    var done = p^.finish_index()
    return done^.take_rows()


def _row(b: RecordBatch, r: Int) -> String:
    var out = String()
    for c in range(b.num_columns()):
        ref a = b.column(c)
        if not is_valid(a, r):
            out += "<null>|"
        elif len(a.offsets) > 0:
            out += str_at(a, r) + "|"
        else:
            out += String(i64_at(a, r), "|")
    return out^


def _file_rows(io: FileIO, f: DataFile) raises -> Tuple[List[String], Int]:
    """A file's rows in order, and its row groups."""
    var reader = ParquetReader[AllCodecs](io.read_all(f.file_path))
    var groups = reader.num_row_groups()
    var t = reader.read_table()
    var out = List[String]()
    for ref b in t.batches:
        for r in range(b.num_rows):
            out.append(_row(b, r))
    return (out^, groups)


def _options() raises -> WriteOptions:
    var o = WriteOptions.from_properties(events_properties())
    o.page_size = 4096
    o.num_workers = 0
    return o^


def test_same_files_row_for_row() raises:
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-eventrows")
    var io = FileIO.local()
    var all = _rows(_lines(7_000))
    assert_equal(len(all), 1)
    ref rows = all[0]
    var batch = rows.to_batch()
    var order = order_by_repo_type(rows)
    var want = order_by_text(batch, "repo", "type")
    assert_true(order == want)

    var old_files = write_data_files(
        io,
        dir + "/old",
        [sorted_by_text(batch, "repo", "type")],
        events_schema(),
        events_spec(),
        0,
        _options(),
    )
    var target = FileTarget(
        io.copy(), dir + "/new", events_schema(), events_spec(), 0, _options()
    )
    var new_files = write_event_files(target, rows, order, 64 * 1024)
    assert_equal(len(old_files), 2)  # two days
    assert_equal(len(new_files), len(old_files))
    var groups = 0
    for k in range(len(old_files)):
        ref a = old_files[k]
        ref b = new_files[k]
        assert_equal(a.record_count, b.record_count)
        assert_equal(a.partition[0].i, b.partition[0].i)
        var x = _file_rows(io, a)
        var y = _file_rows(io, b)
        assert_equal(x[1], 1)
        groups += y[1]
        assert_equal(len(x[0]), len(y[0]))
        for r in range(len(x[0])):
            assert_equal(x[0][r], y[0][r])
        # The column metrics the manifests carry are the same.
        assert_equal(len(a.metrics), len(b.metrics))
        for m in range(len(a.metrics)):
            assert_equal(a.metrics[m].value_count, b.metrics[m].value_count)
            assert_equal(
                a.metrics[m].null_value_count, b.metrics[m].null_value_count
            )
            assert_true(a.metrics[m].lower_bound == b.metrics[m].lower_bound)
            assert_true(a.metrics[m].upper_bound == b.metrics[m].upper_bound)
        io.delete(a.file_path)
        io.delete(b.file_path)
    # 64 KB row groups: several a file, which is the point.
    assert_true(groups > 2 * len(new_files))


def test_pieces_stay_bounded() raises:
    """A string column's pieces are `CHUNK_BYTES` (a longer value gets its
    own) and are filled before a new one starts: what a column holds is its
    bytes, not a doubled buffer."""
    var c = TextColumn(events_schema(), 6)
    var small = List[UInt8](length=1000, fill=0x61)
    var big = List[UInt8](length=CHUNK_BYTES + 5, fill=0x62)
    for i in range(10_000):
        if i == 5_000:
            c.add_bytes(Span(big))
        elif i % 100 == 0:
            c.add_null()
        else:
            c.add_bytes(Span(small))
    var held = 0
    for ref p in c.pieces:
        assert_true(p.capacity() <= max(CHUNK_BYTES, len(big)))
        held += p.capacity()
    assert_equal(c.bytes, 9_900 * 1000 + len(big))
    assert_true(held < c.bytes + 3 * CHUNK_BYTES)
    assert_equal(c.nulls, 99)
    var a = c.array(Span([Int32(5_000), Int32(100), Int32(1)]))
    assert_equal(a.length, 3)
    assert_equal(Int(a.offsets[1]), len(big))
    assert_equal(Int(a.offsets[2]), len(big))  # the null
    assert_equal(Int(a.offsets[3]), len(big) + 1000)
    assert_equal(a.null_count, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
