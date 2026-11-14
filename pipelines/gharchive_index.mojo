"""Builds the candidates, repo_hour and releases tables from stored events, for
days loaded before gharchive built them.

The gharchive_index pipeline fills `gharchive.candidates`,
`gharchive.repo_hour` and `gharchive.releases` for days whose events were
loaded before gharchive wrote them.

A one-off, run by hand (`morca backfill gharchive_index 2026-10-01..2026-11-04`).
For each day, a dista task per hour reads that hour of `gharchive.events` once
and builds the same three tables gharchive builds from the download
(`hourindex.HourIndex`); the step commits an hour as one snapshot of each
table, in order, and a first commit replaces what an earlier run left for the
day, exactly as gharchive does. `gharchive.events` isn't touched. Days with no
events are skipped.

    ./build/gharchive_index run --partitions 2026-11-03
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task
from morca import Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, morca_main
from morca.tables import ensure_table, scan, table

from hourindex import IndexFiles
from indexing import commit_hour, committed_hours, day_files
from lake import (
    CANDIDATES,
    EVENTS,
    GH_RELEASES,
    REPO_HOUR,
    candidates_schema,
    candidates_spec,
    gh_releases_schema,
    gh_releases_spec,
    index_properties,
    repo_hour_properties,
    repo_hour_schema,
    repo_hour_spec,
)
from reindex import index_hour, index_job


# A dista `Task` is a function that runs on a worker process; `Tasks[...]` is
# the list of them this pipeline's run starts a runtime for (morca forks the
# head and workers before the first step, and `ctx.runtime` hands it to the
# step). `IndexHour` takes a job string (`reindex.index_job`) and returns the
# hour's index files, written to the tables but not committed.
comptime IndexHour = Task[String, IndexFiles, index_hour]
comptime IndexTasks = Tasks[IndexHour]


def index_day(mut ctx: Ctx, d: Day) raises -> Int64:
    """Rebuilds one day's candidates, repo_hour and releases rows from its
    stored events, committed in hour order.
    Returns the day's `repo_hour` row count (0 for a day with no events)."""
    var day = String(d)
    var events = table(ctx, EVENTS)
    if len(day_files(events, day, "created_at")) == 0:
        ctx.log(String(day, ": no events loaded, nothing to index"))
        return 0
    # Every hour's task reads `gharchive.events` at this one snapshot, so
    # commits made while the day runs can't change what the tasks see.
    var pinned = scan(ctx, events).snapshot_id()
    var props = index_properties()
    var cand_t = ensure_table(
        ctx, CANDIDATES, candidates_schema(), candidates_spec(), props
    )
    var hour_t = ensure_table(
        ctx,
        REPO_HOUR,
        repo_hour_schema(),
        repo_hour_spec(),
        repo_hour_properties(),
    )
    var rel_t = ensure_table(
        ctx, GH_RELEASES, gh_releases_schema(), gh_releases_spec(), props
    )
    ref rt = ctx.runtime[IndexTasks]()
    # At most `window` hour tasks are in flight (the same knob as gharchive's
    # download tasks); the step commits hour i while the later hours are
    # already being read.
    var window = max(1, Int(getenv("GHARCHIVE_PARALLEL", "16")))
    var n = 24
    # Idempotency: each table counts its own commits, and a retry of a
    # failed attempt finds, per table, how many hours that attempt got in.
    # The attempt may have died between two tables' commits for an hour, so
    # resume at the hour every table has (`done`), and let `commit_hour`
    # recognise the hours a table has already (`i < d_*`) rather than append
    # them twice.
    var d_cand = committed_hours(ctx, cand_t, n)
    var d_hour = committed_hours(ctx, hour_t, n)
    var d_rel = committed_hours(ctx, rel_t, n)
    var done = min(d_cand, min(d_hour, d_rel))
    # A new run of a day (a rerun, not a retry) finds files from an earlier
    # run: its first commit to each table is an `overwrite` that removes them,
    # so a day always holds the rows of one run. `old_*` stay empty when this
    # is a retry that already made its first commit.
    var old_cand = List[String]()
    var old_hour = List[String]()
    var old_rel = List[String]()
    if d_cand == 0:
        old_cand = day_files(cand_t, day, "hour")
    if d_hour == 0:
        old_hour = day_files(hour_t, day, "hour")
    if d_rel == 0:
        old_rel = day_files(rel_t, day, "created_at")
    # A sliding window of futures: `rt.remote` starts a task and returns an
    # `ObjectRef`; `rt.get` waits for its result and `rt.release` frees it on
    # the worker. Refs are consumed in hour order (the commits must be in
    # hour order), and each consumed ref makes room to start the next hour.
    var refs = List[ObjectRef[IndexFiles]]()
    var next = done
    while next < n and next - done < window:
        refs.append(rt.remote[IndexHour](index_job(day, next, pinned, True)))
        next += 1
    var rows = Int64(0)
    for i in range(done, n):
        var got = rt.get(refs[i - done])
        rt.release(refs[i - done])
        if next < n:
            refs.append(rt.remote[IndexHour](index_job(day, next, pinned, True)))
            next += 1
        # One snapshot per table and hour, so the tables' commit numbers stay
        # aligned with the hours (an hour with nothing still has a marker row).
        try:
            _ = commit_hour(ctx, cand_t, i, d_cand, old_cand, got.candidates)
            _ = commit_hour(ctx, hour_t, i, d_hour, old_hour, got.repo_hour)
            _ = commit_hour(ctx, rel_t, i, d_rel, old_rel, got.releases)
        except e:
            raise Error(day, " hour ", i, ": committing: ", e)
        rows += Int64(got.repo_hour_rows)
        ctx.log(String(
            day, " hour ", i, ": ", got.candidate_rows, " candidates, ",
            got.repo_hour_rows, " repo-hours, ", got.release_rows,
            " releases (write ", got.write_ms, " ms)",
        ))
    ctx.log(String(day, ": ", rows, " repo-hour rows in ", n - done, " hours"))
    return rows


# A `Step` wraps `index_day` with its name, input and output types and kind.
# `Mapped` runs it once per partition (here a `Day`) of a run. `reads` and
# `writes` are checked by `morca.tables` (a scan or commit of an undeclared
# table is refused) and give the lineage graph in the UI. `retries=2` re-runs
# a failed attempt in the same run; the commit recognition above makes that
# safe.
comptime IndexDay = Step[
    "index_day",
    Day,
    Int64,
    index_day,
    Mapped,
    retries=2,
    reads=[EVENTS],
    writes=[CANDIDATES, REPO_HOUR, GH_RELEASES],
]
# No `schedule`, so nothing fires it: run it with `morca backfill`.
comptime GhArchiveIndex = Pipeline[
    "gharchive_index",
    IndexDay,
    tasks=IndexTasks,
    partitions=Daily["2023-01-01"],
    max_runs=3,  # days are disjoint partitions; the step's commits are serial
    workers=8,
]


def main() raises:
    # Local runs without MORCA_WAREHOUSE write under ./build/warehouse.
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[GhArchiveIndex]()
