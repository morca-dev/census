"""An hour's data files come back from a worker as they were written.

    pixi run test
"""

from std.os import getenv
from std.time import perf_counter_ns
from dista.codec import decode, encode
from std.testing import TestSuite, assert_equal, assert_true

from datafiles import DataFiles
from events import parse_events
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from lake import EVENTS_SCHEMA
from morca.tables import Table, write_files


def _lines() -> List[UInt8]:
    var s = String()
    for i in range(300):
        s += String(
            '{"id":"', 1000 + i, '","type":"PushEvent","actor":{"login":"a',
            i % 7, '"},"repo":{"name":"o/r', i % 5, '"},"payload":{"n":', i,
            '},"created_at":"2025-01-0', 1 + i % 2, 'T0', i % 10, ':00:00Z"}\n',
        )
    return List[UInt8](s.as_bytes())


def test_round_trip() raises:
    var dir = String(
        getenv("TMPDIR", "/tmp"), "/census-test-datafiles-", perf_counter_ns()
    )
    # The table is made with iceberg (a step's `ensure_table` needs a run)
    # and written through morca's tables, as a worker writes it.
    var made = FilesystemCatalog.local(dir).create_table(
        "t",
        "events",
        Schema.parse(EVENTS_SCHEMA),
        PartitionSpec(  # lake.events_spec, as iceberg's
            0,
            [PartitionField.single(3, 1000, "created_day", parse_transform("day"))],
        ),
    )
    var t = Table.load(made.metadata.location)
    var entries = write_files(t, parse_events(Span(_lines())))
    var files = entries.files()
    assert_equal(len(files), 2)  # two days, two partitions
    # The struct crosses by dista's reflection: its plain fields as they
    # are, `files` through morca's `DataFiles` Codec (iceberg's wire form).
    var sent = DataFiles()
    sent.files = entries.copy()
    sent.rows = 300
    sent.parse_ms = 7
    # The hour's index files ride along, nested.
    sent.index.repo_hour = entries.copy()
    sent.index.repo_hour_rows = 42
    sent.index_ms = 9
    sent.missing = True
    var bytes = List[UInt8]()
    encode(sent, bytes)
    var pos = 0
    var back = decode[DataFiles](Span(bytes), pos)
    assert_equal(pos, len(bytes))
    assert_equal(back.rows, 300)
    assert_equal(back.parse_ms, 7)
    assert_equal(back.index.repo_hour_rows, 42)
    assert_equal(back.index_ms, 9)
    assert_true(back.missing)
    assert_equal(len(back.index.repo_hour), len(files))
    assert_equal(len(back.index.candidates), 0)
    # The entries come back byte for byte: metrics, sizes and all.
    assert_true(back.files.bytes == entries.bytes)
    assert_true(back.index.repo_hour.bytes == entries.bytes)
    var got = back.files.files()
    assert_equal(len(got), len(files))
    var io = FileIO.local()
    for k in range(len(files)):
        ref a = files[k]
        ref b = got[k]
        assert_equal(a.file_path, b.file_path)
        assert_equal(a.record_count, b.record_count)
        assert_equal(a.file_size_in_bytes, b.file_size_in_bytes)
        assert_equal(len(a.partition), len(b.partition))
        assert_equal(a.partition[0].i, b.partition[0].i)
        assert_equal(a.partition[0].kind, b.partition[0].kind)
        io.delete(a.file_path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
