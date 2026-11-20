"""How it works' By the numbers (#124): mojo.measures' rows and the newest of
each, the GH Archive day's hour to published from the snapshots, the
console's memory and image size, and the block that shows them.

    pixi run test test_measures
"""

from std.os import getenv, setenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from iceberg.batch import ColumnBuilder, batch_of
from iceberg.catalog.filesystem import FilesystemCatalog
from iceberg.schema import Schema
from iceberg.values import Datum
from morca.tables import Table as LakeTable

from console_how import Numbers, by_the_numbers
from live import Freshness
from measures import (
    EMBED_LOAD,
    EMBED_RATE,
    Measure,
    Published,
    archive_published,
    image_bytes,
    latest_of,
    measure_key,
    measure_rows,
    measures_batch,
    vmrss_bytes,
)


def test_measures_round_trip() raises:
    var rows: List[Measure] = [
        Measure("mojo_embed", 7, EMBED_RATE, 812.5, "texts/s", 1_000),
        Measure("mojo_embed", 7, EMBED_LOAD, 1.25, "s", 1_000),
        Measure("mojo_embed", 9, EMBED_RATE, 790.0, "texts/s", 2_000),
    ]
    var back = measure_rows(measures_batch(rows))
    assert_equal(len(back), 3)
    assert_equal(back[0].pipeline, "mojo_embed")
    assert_equal(back[0].run, 7)
    assert_equal(back[0].value, 812.5)
    assert_equal(back[1].unit, "s")
    assert_equal(back[2].at, 2_000)
    var latest = latest_of(back)
    assert_equal(len(latest), 2)
    # The newest of each name: run 9's rate, run 7's load time.
    assert_equal(latest[measure_key("mojo_embed", EMBED_RATE)].run, 9)
    assert_equal(latest[measure_key("mojo_embed", EMBED_RATE)].value, 790.0)
    assert_equal(latest[measure_key("mojo_embed", EMBED_LOAD)].run, 7)


def _table(
    mut cat: FilesystemCatalog,
    name: String,
    keys: List[String],
    at_ms: List[Int64],
    runs: List[Int],
    pipeline: String,
) raises -> LakeTable:
    """A table with a snapshot per entry of `keys`, naming those partitions,
    committed at `at_ms` by `pipeline`'s runs `runs`, as morca's are."""
    var s = Schema.parse(
        '{"schema-id":0,"type":"struct","fields":['
        '{"id":1,"name":"n","required":false,"type":"long"}]}'
    )
    var t = cat.create_table("gharchive", name, s)
    for _ in range(len(keys)):
        var c = ColumnBuilder.of(s, 1)
        c.add(Datum.long_(1))
        _ = t.append([batch_of([c^])])
    var m = LakeTable.load(t.metadata.location)
    for i in range(len(keys)):
        m.metadata.snapshots[i].summary["orca.partitions"] = keys[i]
        m.metadata.snapshots[i].summary["orca.run"] = String(runs[i])
        m.metadata.snapshots[i].summary["orca.pipeline"] = pipeline
        m.metadata.snapshots[i].timestamp_ms = at_ms[i]
    return m^


comptime DAY_MS = Int64(86_400_000)
comptime NOV19 = Int64(20_776)
"""2026-11-19, in days since 1970-01-01."""


def test_archive_published() raises:
    var dir = String(getenv("TMPDIR", "/tmp"), "/census-test-measures-", perf_counter_ns())
    var cat = FilesystemCatalog.local(dir)
    var end = (NOV19 + 1) * DAY_MS  # 2026-11-20 00:00 UTC
    # gharchive loaded the 19th at 03:12 the next day (run 41), and a rerun
    # named it again later (run 50): the first commit counts.
    var rh = _table(
        cat, "repo_hour", ["2026-11-18", "2026-11-19", "2026-11-19"],
        [end - DAY_MS + 11_000_000, end + 11_520_000, end + 40_000_000], [40, 41, 50], "gharchive",
    )
    var p = archive_published("2026-11-19", Optional(rh.copy()), None)
    assert_equal(p.day, "2026-11-19")
    assert_equal(p.lag_s, 11_520)
    assert_equal(p.run, 41)
    assert_equal(p.pipeline, "gharchive")
    # mojo_activity committed the day's counts 20 minutes after: that commit
    # is when the day showed on the site.
    var act = _table(
        cat, "activity", ["2026-11-19"], [end + 12_720_000], [77], "mojo_activity"
    )
    var q = archive_published("2026-11-19", Optional(rh.copy()), Optional(act.copy()))
    assert_equal(q.lag_s, 12_720)
    assert_equal(q.run, 77)
    assert_equal(q.pipeline, "mojo_activity")
    # An activity table that hasn't got the day yet leaves repo_hour's.
    var old = _table(cat, "activity_old", ["2026-11-18"], [end - 3_600_000], [70], "mojo_activity")
    assert_equal(archive_published("2026-11-19", Optional(rh.copy()), Optional(old^)).run, 41)
    # A day no snapshot names (expired), or none loaded: nothing to show.
    assert_equal(archive_published("2026-11-17", Optional(rh.copy()), None).day, "")
    assert_equal(archive_published("", Optional(rh^), None).day, "")


def test_vmrss_bytes() raises:
    var status = String(
        "Name:\tconsole\nVmPeak:\t  900000 kB\nVmRSS:\t  123456 kB\nThreads:\t5\n"
    )
    assert_equal(vmrss_bytes(status), 123456 * 1024)
    assert_equal(vmrss_bytes("Name:\tconsole\n"), -1)


def test_image_bytes() raises:
    var before = getenv("MORCA_IMAGE_BYTES")
    _ = setenv("MORCA_IMAGE_BYTES", "")
    assert_equal(image_bytes(), -1)
    _ = setenv("MORCA_IMAGE_BYTES", "812345678")
    assert_equal(image_bytes(), 812345678)
    _ = setenv("MORCA_IMAGE_BYTES", "big")
    assert_equal(image_bytes(), -1)
    _ = setenv("MORCA_IMAGE_BYTES", before)


def test_by_the_numbers_before_any_measure() raises:
    var h = by_the_numbers(Numbers(None, None, Published.none(), Freshness(0, 0, 0), -1, -1))
    assert_true("By the numbers" in h)
    assert_true("not reported" in h)
    assert_true("not measured yet" in h)
    # Never a 0 for a number nobody reported.
    assert_false(">0 MB<" in h)
    assert_true("https://orca.mojourney.dev/pipelines/mojo_embed" in h)


def test_by_the_numbers_links_the_runs() raises:
    var h = by_the_numbers(Numbers(
        Measure("mojo_embed", 12, EMBED_RATE, 812.4, "texts/s", 1),
        Measure("mojo_embed", 12, EMBED_LOAD, 1.234, "s", 1),
        Published("2026-11-19", 11_520, "gharchive", 41),
        Freshness(30, 540, 900),
        512_000_000,
        1_234_000_000,
    ))
    assert_true("812 texts/s" in h)
    assert_true("1.23 s" in h)
    assert_true("<a href='https://orca.mojourney.dev/runs/12' rel=noopener>mojo_embed run 12</a>" in h)
    assert_true("3 h 12 min" in h)
    assert_true("for 2026-11-19" in h)
    assert_true("https://orca.mojourney.dev/runs/41" in h)
    assert_true("9 min" in h)
    assert_true("https://orca.mojourney.dev/pipelines/mojo_live" in h)
    assert_true("512 MB" in h)
    assert_true("1.2 GB" in h)
    assert_false("not reported" in h)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
