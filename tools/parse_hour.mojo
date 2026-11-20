"""Parses one local GH Archive hour and prints rows and timings.

    mojo build -I src tools/parse_hour.mojo -o build/parse_hour
    ./build/parse_hour 2025-09-15-16.json.gz

`whole` gunzips the hour at once with deflate-mojo and parses that, as the
pipeline did before 0.2; `stream` is what the pipeline does, a window at a
time.
"""

from std.sys import argv
from std.time import perf_counter_ns

from deflate import gunzip
from events import Collect, parse_events, parse_gz
from parquet import RecordBatch


def _rows(batches: List[RecordBatch]) -> Int:
    var rows = 0
    for b in batches:
        rows += b.num_rows
    return rows


def _ms(t0: Int, t1: Int) -> Int:
    return (t1 - t0) // 1_000_000


def main() raises:
    var args = argv()
    var t0 = perf_counter_ns()
    var f = open(String(args[1]), "r")
    var gz = f.read_bytes()
    f^.close()
    var t1 = perf_counter_ns()
    var data = gunzip(Span(gz))
    var t2 = perf_counter_ns()
    var batches = parse_events(Span(data))
    var t3 = perf_counter_ns()
    var n = len(data)
    _ = data^
    var sink = Collect()
    var timing = parse_gz(Span(gz), sink)
    var t4 = perf_counter_ns()
    var streamed = List[RecordBatch]()
    swap(streamed, sink.batches)
    print("bytes", len(gz), "->", n, "rows", _rows(batches), "stream rows", _rows(streamed))
    print("read", _ms(t0, t1), "ms whole: gunzip", _ms(t1, t2), "ms parse", _ms(t2, t3), "ms; stream:", _ms(t3, t4), "ms (gunzip", timing.gunzip_ms, "ms parse", timing.parse_ms, "ms)")
