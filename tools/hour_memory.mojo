"""Peak memory of one local GH Archive hour, a stage at a time.

    mojo build -I src tools/hour_memory.mojo -o build/hour_memory
    MORCA_WAREHOUSE=build/warehouse ./build/hour_memory 2023-01-10-15.json.gz full

The stages add up: `read` holds the whole `.json.gz` (which `fetch.Download`
no longer does: it gives decoded input back as it goes, so subtract the
file's size for the pipeline's figure),
`gunzip` decodes it a window at a time, `parse` builds the batches and drops
each, `index` also builds the hour's `HourIndex`, `sort` also sorts each
batch, `write` also writes the events (into `MORCA_WAREHOUSE`, whose tables a
gharchive run made), and `full` also writes the index tables, which is what
an hour's task does. `noevents` is what an hour's task does with
`GHARCHIVE_EVENTS=off`: the parse builds no rows, only the index, and writes
the index tables. Prints the peak RSS (`getrusage`) at the end, in MB
(magmalake/mojo-census#37 has the figures).
"""

from std.os import stat
from std.sys import argv
from std.time import perf_counter_ns

from deflate import GzipReader, InflateStatus
from morca.tables import load_dataset

from datafiles import BatchSink, TableWriter
from eventrows import EventRows, order_by_repo_type
from events import CHUNK, NoRows, decode_index
from gzstream import Whole
from hourindex import HourIndex, write_index
from rss import peak_rss_bytes
from lake import CANDIDATES, EVENTS, GH_RELEASES, REPO_HOUR


def peak_rss_mb() -> Int:
    return peak_rss_bytes() >> 20


struct Drop(BatchSink, Movable):
    var rows: Int
    var sort: Bool

    def __init__(out self, sort: Bool):
        self.rows = 0
        self.sort = sort

    def put(mut self, var rows: EventRows) raises:
        self.rows += len(rows)
        if self.sort:
            _ = order_by_repo_type(rows)


def main() raises:
    var args = argv()
    var path = String(args[1])
    var mode = String(args[2])
    var t0 = perf_counter_ns()
    var f = open(path, "r")
    var gz = f.read_bytes(stat(path).st_size)
    f^.close()
    var rows = 0
    if mode == "gunzip":
        var r = GzipReader(CHUNK * 2)
        while True:
            var st = r.run(Span(gz), True, len(r) + CHUNK)
            rows += len(r)  # bytes, for this stage
            _ = r.compact(len(r))
            if st == InflateStatus.FINISHED:
                break
    elif mode == "parse" or mode == "index" or mode == "sort":
        var sink = Drop(mode == "sort")
        var index = HourIndex()
        _ = decode_index(Whole(Span(gz)), sink, index, mode != "parse")
        rows = sink.rows
    elif mode == "write" or mode == "full":
        var w = TableWriter(load_dataset(EVENTS))
        var index = HourIndex()
        _ = decode_index(Whole(Span(gz)), w, index, True)
        var out = w^.finish()
        rows = out.rows
        if mode == "full":
            _ = write_index(
                index,
                load_dataset(CANDIDATES),
                load_dataset(REPO_HOUR),
                load_dataset(GH_RELEASES),
            )
    elif mode == "noevents":
        var none = NoRows()
        var index = HourIndex()
        _ = decode_index(Whole(Span(gz)), none, index, True, keep_rows=False)
        rows = index.events
        _ = write_index(
            index,
            load_dataset(CANDIDATES),
            load_dataset(REPO_HOUR),
            load_dataset(GH_RELEASES),
        )
    elif mode != "read":
        raise Error("hour_memory: unknown stage ", mode)
    print(
        mode,
        "gz_mb",
        len(gz) >> 20,
        "rows",
        rows,
        "ms",
        Int(perf_counter_ns() - t0) // 1_000_000,
        "peak_rss_mb",
        peak_rss_mb(),
    )
