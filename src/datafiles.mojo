"""Data files written on a dista worker, sent back to the step to commit.

An hour's task writes its Parquet files into the table's `data/` itself and
returns only their `DataFile` entries (`morca.tables.DataFiles`, which dista
carries as a `Codec`), which the step commits as one append
(`morca.tables.append_files`).
"""

from std.os import getenv
from std.time import perf_counter_ns

from morca.tables import DataFiles as FileEntries
from morca.tables import FileWriter, Table
from threads import num_cpus

from eventrows import (
    GROUP_BYTES,
    EventRows,
    arrival_order,
    order_by_repo_type,
    write_event_files,
)
from hourindex import IndexFiles


struct DataFiles(Copyable, Movable):
    """An hour's data files, its row count, and where its time went (ms).

    A plain struct: dista's reflection encodes its fields, `files` through
    its own `Codec`."""

    var files: FileEntries
    var rows: Int
    var download_ms: Int
    var gunzip_ms: Int
    var parse_ms: Int
    var sort_ms: Int
    """Putting each batch's rows in order, before they are written."""
    var write_ms: Int
    var wait_ms: Int
    """Decoding waiting for the download."""
    var total_ms: Int
    var index: IndexFiles
    """The hour's candidates, repository counts and releases."""
    var index_ms: Int
    """Building them and writing their files."""
    var missing: Bool
    """GH Archive has no file for the hour (`events.hour_overdue`): no
    rows and no files, and the step goes on without it."""

    def __init__(out self):
        self.files = FileEntries()
        self.rows = 0
        self.download_ms = 0
        self.gunzip_ms = 0
        self.parse_ms = 0
        self.sort_ms = 0
        self.write_ms = 0
        self.wait_ms = 0
        self.total_ms = 0
        self.index = IndexFiles()
        self.index_ms = 0
        self.missing = False


def write_threads() raises -> Int:
    """Threads that encode an hour's pages: `GHARCHIVE_WRITE_THREADS`, else
    the cores shared among the hours this worker runs at once
    (`DISTA_WORKER_SLOTS`, default 1; 0 is one per core). Each thread holds
    a zstd 9 context, about 36 MB, and threads beyond the cores only add
    those: on 4 vCPUs at 4 hours in flight, one thread an hour ran a day in
    39 s and 1.8 GB, four in 46 s and 2.1 GB (#37)."""
    var given = getenv("GHARCHIVE_WRITE_THREADS")
    if given:
        return max(1, Int(given))
    var slots = Int(getenv("DISTA_WORKER_SLOTS", "1"))
    if slots <= 0:
        return 1
    return max(1, num_cpus() // slots)


trait BatchSink:
    """Where `decode_index` puts each file's worth of rows as it fills."""

    def put(mut self, var rows: EventRows) raises:
        ...


struct TableWriter(BatchSink, Movable):
    """Writes each file's worth of rows into the table's data files as it
    comes, uncommitted, sorted by (repo, type) (see `sortrows`) or in the
    order the rows arrived, and keeps their entries and the time.

    A file is written a row group of `eventrows.GROUP_BYTES` at a time
    (`eventrows.write_event_files`), so the rows are never copied whole."""

    var writer: FileWriter
    var rows: Int
    var write_ns: Int
    var sort_ns: Int
    var sorted: Bool
    var group_bytes: Int

    def __init__(
        out self,
        table: Table,
        sorted: Bool = True,
        group_bytes: Int = GROUP_BYTES,
    ) raises:
        var w = FileWriter(table)
        # 4 MB pages: the JSON column's 20% growth at the 1 MB default is 4%
        # at 4 MB.
        w.options.num_workers = write_threads()
        if "write.parquet.page-size-bytes" not in table.metadata.properties:
            w.options.page_size = 4 * 1024 * 1024
        self.writer = w^
        self.rows = 0
        self.write_ns = 0
        self.sort_ns = 0
        self.sorted = sorted
        self.group_bytes = group_bytes

    def put(mut self, var rows: EventRows) raises:
        """Orders a file's rows if asked to (each file on its own: rows are
        in order within a file, not across the hour; only their row numbers
        move), then writes them."""
        var t_sort = perf_counter_ns()
        var order = order_by_repo_type(rows) if self.sorted else arrival_order(
            len(rows)
        )
        self.sort_ns += Int(perf_counter_ns() - t_sort)
        var t0 = perf_counter_ns()
        write_event_files(self.writer, rows, order, self.group_bytes)
        self.rows += len(rows)
        self.write_ns += Int(perf_counter_ns() - t0)

    def finish(deinit self) raises -> DataFiles:
        """Closes the last file and returns the entries of all of them, with
        the row count and the time spent sorting and writing."""
        var out = DataFiles()
        out.rows = self.rows
        out.sort_ms = self.sort_ns // 1_000_000
        out.write_ms = self.write_ns // 1_000_000
        out.files = self.writer^.finish()
        return out^
