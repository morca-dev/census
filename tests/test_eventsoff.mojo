"""With `GHARCHIVE_EVENTS=off` an hour's index files are the ones it has with
the events on, byte for byte, and no event file is written.

One synthetic hour (the kinds of events the index looks at, escapes, null
actors, a line without an id, more than one events file's worth of rows)
goes through `events.decode_hour` twice, as an hour's task runs it: with an
events writer, and without. Each way writes the three index tables into a
catalog of its own; their files must hold the same bytes and the same rows.

    pixi run test
"""

from std.os import getenv, setenv, unsetenv
from std.time import perf_counter_ns
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from deflate import gzip
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.io import FileIO
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from morca.tables import DataFiles as FileEntries
from morca.tables import Table
from parquet import ParquetReader
from parquet_full import AllCodecs

from datafiles import TableWriter
from events import ROWS_PER_BATCH, decode_hour, keep_events
from gzstream import Whole
from lake import (
    CANDIDATES_SCHEMA,
    EVENTS_SCHEMA,
    GH_RELEASES_SCHEMA,
    REPO_HOUR_SCHEMA,
    events_properties,
    index_properties,
    repo_hour_properties,
)

comptime ROWS = ROWS_PER_BATCH + 7_000
"""Events in the hour: a full events file and a short one."""


def _line(i: Int) -> String:
    """Event `i`: a mix of every type `HourIndex.add` counts or scans."""
    var minute = String((i // 1000) % 60)
    if minute.byte_length() < 2:
        minute = String("0", minute)
    var at = String("2024-06-12T15:", minute, ":", "0", i % 10, "Z")
    var repo = String("o", i % 7, "/r", (i * 31) % 4999)
    var actor = String() if i % 41 == 0 else String("u", (i * 13) % 997)
    var k = i % 11
    var type: String
    var payload: String
    if k == 0:
        type = "WatchEvent"
        payload = '{"action":"started"}'
    elif k == 1:
        type = "ForkEvent"
        payload = String(
            '{"forkee":{"full_name":"f/x', i, '","language":"',
            "Mojo" if i % 3 == 0 else "Python", '"}}',
        )
    elif k == 2:
        type = "PushEvent"
        payload = String(
            '{"commits":[{"sha":"s', i, '","message":"add k', i,
            '.mojo \\"quoted\\" and \\u00e9"},{"sha":"t', i,
            '","message":"fix"}]}',
        )
    elif k == 3:
        type = "IssuesEvent"
        payload = '{"action":"opened"}' if i % 2 == 0 else '{"action":"closed"}'
    elif k == 4:
        type = "PullRequestEvent"
        payload = String(
            '{"action":"', "opened" if i % 2 == 0 else "closed",
            '","pull_request":{"base":{"repo":{"full_name":"', repo,
            '","language":"Mojo"}},"head":{"repo":{"full_name":"h/',
            i, '","language":"Mojo"}}}}',
        )
    elif k == 5:
        type = "ReleaseEvent"
        payload = String(
            '{"action":"', "published" if i % 3 != 0 else "created",
            '","release":{"tag_name":"v', i, '","name":',
            "null" if i % 4 == 0 else String('"Rel \\"', i, '\\""'),
            ',"prerelease":', "true" if i % 2 == 0 else "false",
            ',"published_at":"2024-06-12T15:00:0', i % 10, 'Z"}}',
        )
    elif k == 6:
        type = "CreateEvent"
        payload = String('{"description":"A Mojo ', i, ' thing"}')
    else:
        type = String("T", k)
        payload = String('{"n":', i, ',"text":"', String('a\\"b') * (i % 9), '"}')
    var a = String('"actor":{"login":"', actor, '"},') if actor else String()
    return String(
        '{"id":"', 90_000_000 + i, '","type":"', type, '",', a,
        '"repo":{"name":"', repo, '"},"payload":', payload,
        ',"created_at":"', at, '"}\n',
    )


def _hour() raises -> List[UInt8]:
    """The hour gzipped, a member every 5,000 events, with a line that has
    no id (skipped both ways)."""
    var gz = List[UInt8]()
    var i = 0
    while i < ROWS:
        var json = String()
        for k in range(i, min(i + 5_000, ROWS)):
            json += _line(k)
            if k == 1234:
                json += '{"type":"WatchEvent","created_at":"2024-06-12T15:00:00Z"}\n'
        gz.extend(Span(gzip(json.as_bytes())))
        i += 5_000
    return gz^


def _by_day(
    mut cat: FilesystemCatalog,
    name: String,
    schema: String,
    source_id: Int,
    part: String,
    var props: Dict[String, String],
) raises -> Table:
    """A table partitioned by the day of field `source_id`, as lake's specs
    are, made with iceberg (a step's `ensure_table` needs a run) and used
    through morca's tables."""
    var spec = PartitionSpec(
        0, [PartitionField.single(source_id, 1000, part, parse_transform("day"))]
    )
    var t = cat.create_table(
        "gharchive", name, Schema.parse(schema), spec, props^
    )
    return Table.load(t.metadata.location)


struct Tables(Movable):
    var candidates: Table
    var repo_hour: Table
    var releases: Table

    def __init__(out self, dir: String) raises:
        var cat = FilesystemCatalog.local(dir)
        self.candidates = _by_day(
            cat, "candidates", CANDIDATES_SCHEMA, 2, "hour_day",
            index_properties(),
        )
        self.repo_hour = _by_day(
            cat, "repo_hour", REPO_HOUR_SCHEMA, 2, "hour_day",
            repo_hour_properties(),
        )
        self.releases = _by_day(
            cat, "releases", GH_RELEASES_SCHEMA, 2, "created_day",
            index_properties(),
        )


def _same_files(a: FileEntries, b: FileEntries, what: String) raises:
    """The same number of files, each with the same bytes and rows."""
    var io = FileIO.local()
    assert_equal(len(a), len(b), what)
    var af = a.files()
    var bf = b.files()
    for i in range(len(a)):
        ref x = af[i]
        ref y = bf[i]
        assert_equal(x.record_count, y.record_count, what)
        var bx = io.read_all(x.file_path)
        var by = io.read_all(y.file_path)
        assert_equal(len(bx), len(by), what)
        assert_true(bx == by, String(what, ": file ", i, " differs"))
        # And the rows read back, column by column.
        var px = ParquetReader[AllCodecs](bx^)
        var py = ParquetReader[AllCodecs](by^)
        var tx = px.read_table()
        var ty = py.read_table()
        assert_equal(len(tx.batches), len(ty.batches), what)
        var n = 0
        for k in range(len(tx.batches)):
            ref rx = tx.batches[k]
            ref ry = ty.batches[k]
            assert_equal(rx.num_rows, ry.num_rows, what)
            n += rx.num_rows
            for c in range(len(rx.roots)):
                assert_true(rx.column(c).values == ry.column(c).values, what)
                assert_true(rx.column(c).offsets == ry.column(c).offsets, what)
                assert_true(rx.column(c).validity == ry.column(c).validity, what)
        assert_equal(n, Int(x.record_count), what)


def test_index_files_are_the_same_without_the_events() raises:
    var gz = _hour()
    var base = String(
        getenv("TMPDIR", "/tmp"), "/census-test-eventsoff-", perf_counter_ns()
    )
    var io = FileIO.local()
    var on_t = Tables(String(base, "/on"))
    var off_t = Tables(String(base, "/off"))

    # 4 MB pages: TableWriter's default without the table property.
    var ev_cat = FilesystemCatalog.local(String(base, "/events"))
    var w = TableWriter(
        _by_day(ev_cat, "events", EVENTS_SCHEMA, 3, "created_day", events_properties())
    )
    var on = decode_hour(
        Whole(Span(gz)), Optional(w^), on_t.candidates, on_t.repo_hour,
        on_t.releases,
    )
    var off = decode_hour(
        Whole(Span(gz)), Optional[TableWriter](), off_t.candidates,
        off_t.repo_hour, off_t.releases,
    )
    _ = len(gz)  # `Whole` holds only the address

    # The events: two files with them on, none without; the same count.
    assert_equal(on.rows, ROWS)
    assert_equal(off.rows, ROWS)
    assert_equal(len(on.files), 2)
    assert_equal(len(off.files), 0)
    assert_equal(off.write_ms, 0)

    # The index: the same rows, in files of the same bytes.
    assert_equal(on.index.candidate_rows, off.index.candidate_rows)
    assert_equal(on.index.repo_hour_rows, off.index.repo_hour_rows)
    assert_equal(on.index.release_rows, off.index.release_rows)
    assert_true(on.index.candidate_rows > 0)
    assert_true(on.index.repo_hour_rows > 1000)
    assert_true(on.index.release_rows > 0)
    _same_files(on.index.candidates, off.index.candidates, "candidates")
    _same_files(on.index.repo_hour, off.index.repo_hour, "repo_hour")
    _same_files(on.index.releases, off.index.releases, "releases")
    for f in on.files.files():
        io.delete(f.file_path)


def test_the_switch() raises:
    _ = unsetenv("GHARCHIVE_EVENTS")
    assert_true(keep_events())
    _ = setenv("GHARCHIVE_EVENTS", "on")
    assert_true(keep_events())
    _ = setenv("GHARCHIVE_EVENTS", "off")
    assert_false(keep_events())
    _ = setenv("GHARCHIVE_EVENTS", "no")
    with assert_raises(contains="GHARCHIVE_EVENTS"):
        _ = keep_events()
    _ = unsetenv("GHARCHIVE_EVENTS")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
