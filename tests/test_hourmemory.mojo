"""An hour in flight holds about one file's worth of rows, not several
(magmalake/mojo-census#37).

A synthetic hour of 2023-sized events (60,000 events of about 4 KB: a full
50,000-row file of about 210 MB and a short one) goes through what an hour's
task does, `decode_index` into a `TableWriter`, and the peak RSS it adds is
checked against the rows' own size. A file's JSON is 197 MB; the write
before #37 (each file's rows as one batch, sorted by copying it, written as
one row group) added 832 MB under Linux and 778 MB on macOS, and that was
without the builders' doubling. Now it adds about 340 MB under Linux and 250
MB on macOS: the rows in their pieces, a row group of `GROUP_BYTES` in the
writer, its zstd contexts, and the allocator's slack.

    pixi run test
"""

from std.os import getenv
from std.time import perf_counter_ns
from std.testing import TestSuite, assert_equal, assert_true

from deflate import gzip
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from morca.tables import Table

from datafiles import TableWriter
from events import ROWS_PER_BATCH, decode_index
from gzstream import Whole
from hourindex import HourIndex
from lake import EVENTS_SCHEMA, events_properties
from rss import peak_rss_bytes

comptime ROWS = 60_000
comptime MB = 1 << 20


def _line(i: Int) -> String:
    """An event of about 4.3 KB, its payload different for every event."""
    var text = String()
    var x = UInt64(i) * 0x9E3779B97F4A7C15 + 1
    while text.byte_length() < 4_000:
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        text += hex(x)
    return String(
        '{"id":"',
        10_000_000 + i,
        '","type":"T',
        (i * 7) % 9,
        '","actor":{"login":"u',
        i % 997,
        '"},"repo":{"name":"o/r',
        (i * 31) % 5003,
        '"},"payload":{"text":"',
        text,
        '"},"created_at":"2023-01-10T15:',
        (i // 1000) % 60,
        ':00Z"}\n',
    )


def _hour() raises -> Tuple[List[UInt8], Int]:
    """The hour gzipped, a member every 2,000 events (GH Archive's files
    are one member, which decodes the same), and the JSON bytes of its
    first `ROWS_PER_BATCH` events: the biggest file's rows."""
    var gz = List[UInt8]()
    var first = 0
    var i = 0
    while i < ROWS:
        var json = String()
        for k in range(i, min(i + 2_000, ROWS)):
            var l = _line(k)
            if k < ROWS_PER_BATCH:
                first += l.byte_length()
            json += l
        gz.extend(Span(gzip(json.as_bytes())))
        i += 2_000
    return (gz^, first)


def test_an_hour_holds_about_one_file() raises:
    var made = _hour()
    ref gz = made[0]
    var file_json = made[1]
    var dir = String(
        getenv("TMPDIR", "/tmp"), "/census-test-hourmemory-", perf_counter_ns()
    )
    var io = FileIO.local()
    # The events table, made with iceberg (a step's `ensure_table` needs a
    # run) and written through morca's tables; 4 MB pages, TableWriter's
    # default without the table property.
    var events = FilesystemCatalog.local(dir).create_table(
        "gharchive",
        "events",
        Schema.parse(EVENTS_SCHEMA),
        PartitionSpec(
            0,
            [PartitionField.single(3, 1000, "created_day", parse_transform("day"))],
        ),
        events_properties(),
    )
    var w = TableWriter(Table.load(events.metadata.location))
    # Two encoding threads, as on a 4-vCPU server at two hours in flight:
    # each holds a zstd 9 context, so the figure doesn't depend on the cores.
    w.writer.options.num_workers = 2
    var before = peak_rss_bytes()
    var index = HourIndex()
    _ = decode_index(Whole(Span(gz)), w, index, True)
    var added = peak_rss_bytes() - before
    _ = len(gz)  # `Whole` holds only the address: keep the bytes until here
    var out = w^.finish()
    assert_equal(out.rows, ROWS)
    assert_equal(len(out.files), 2)
    for f in out.files.files():
        io.delete(f.file_path)
    print(
        "hour of",
        ROWS,
        "events: file JSON",
        file_json // MB,
        "MB, peak RSS +",
        added // MB,
        "MB",
    )
    # The rows (about their JSON), the decode window, and the writer's row
    # group a few times over with its two zstd contexts: under twice the
    # file's JSON, where the old write took four times.
    var bound = 2 * file_json + 64 * MB
    assert_true(
        added < bound,
        String("peak RSS +", added // MB, " MB, over ", bound // MB, " MB"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
