"""Loads each day of GH Archive and builds the candidates, repo_hour and
releases tables from it.

Daily from 2023-01-01, at 03:00 UTC for the day before. A day's step fans
its hours out as dista tasks, at most `GHARCHIVE_PARALLEL` (default 16: 4 instances of 4 worker processes) at a time. A
task streams its hour in on a reader thread while it gunzips and parses
what has arrived, a window at a time, and writes the Parquet data files
into the table itself; it sends back only
their entries, which the step commits to `gharchive.events`, an hour as one
append, in hour order. An hour is one snapshot; a retried step finds the
hours its earlier attempt committed and skips them without downloading again.

The same tasks build the hour's rows of `gharchive.candidates`,
`gharchive.repo_hour` and `gharchive.releases`; the step keeps their files and
commits each of those tables once, at the end, with all the day's hours (one
snapshot a table and day, not an hour). The files of an hour a retry skips
died with the failed attempt, so the retry builds their rows again from
`gharchive.events` (`reindex.index_hour`, as gharchive_index does), and finds
the day's index commits, if the attempt got as far as making them.

A new run of a day that has rows already (`morca backfill --rerun`)
replaces them: its first hour's commit to the events, and the day commit to
each index table, is an `overwrite` that also removes every data file the
day's partition had, so a day's rows always come from one run.

    GHARCHIVE_HOURS=16-17 ./build/gharchive run --partitions 2025-09-15

An hour in flight takes about `eventrows.HOUR_MEMORY_MB` (450 MB on the
busiest hours, 2023-2025) and the run about 300 MB more, so a run's memory is
about 300 + 450 * `GHARCHIVE_PARALLEL` MB (magmalake/mojo-census#37): the
rows of one 50,000-row file at a time, written a 16 MB row group at a time,
and the compressed hour only as far as it is decoded.

`GHARCHIVE_EVENTS=off` (default `on`) keeps the index and drops the events:
each hour's task parses the hour into the three index tables' rows only, as
it does with them on (the same rows, byte for byte: tests/test_eventsoff.mojo),
and nothing is written to `gharchive.events`, which was 97% of the bucket
(about 1.1 GB a day). The day's index commits are as with it on, and so is a
retry's recognition of them (`find_commit` on each index table): with
nothing committed hour by hour, a retry before the index commits downloads
every hour again, and one after them downloads none. A rerun of a day loaded
with the events on leaves that day's events where they are. An hour in
flight then takes `eventrows.HOUR_INDEX_MEMORY_MB` (about 200 MB) rather
than `HOUR_MEMORY_MB`, so a run about 300 + 200 * `GHARCHIVE_PARALLEL` MB. The step still declares `gharchive.events` in `writes=`, so
the pipeline's `registry_hash` (and its lineage) is the same either way: a
declared write the step doesn't make fails nothing.

GH Archive never published a few hours, such as 2025-06-12's 17:00. A 404
for an hour that ended more than `GHARCHIVE_MISSING_AFTER_HOURS` (48) ago is
such a gap (`events.hour_overdue`): with the events off the day is loaded
without it and the log names it; a 404 for a more recent hour still fails
the day, since it may only be late. With the events on, a gap fails the day
too, because a retry finds the committed hours by their position (#77).

`GHARCHIVE_HOURS` (`A-B` or `A,B,...`; default all 24) limits the hours, for
trying it locally. `GHARCHIVE_FAIL_AFTER=k` (or `end`, after the index
commits) makes the first attempt of a step fail after it committed k hours of
events (with the events off: after k hours came back), to try a retry
(`scripts/test-daily.sh`).
"""

from std.os import getenv, setenv
from std.time import perf_counter_ns

from dista import ObjectRef, Task, Task2
from morca.civil import now
from morca import Cron, Ctx, Daily, Day, Mapped, Pipeline, Step, Tasks, morca_main
from morca.tables import DataFiles as FileEntries
from morca.tables import Table, ensure_table, find_commit, load_dataset

from datafiles import DataFiles
from daymerge import merge_job, merge_repo_hour
from days import days_of
from eventrows import HOUR_INDEX_MEMORY_MB, HOUR_MEMORY_MB
from events import fetch_hour, hour_overdue, hour_url, keep_events, not_found, parse_hours
from hourindex import IndexFiles, write_marker
from indexing import commit_day, commit_hour, committed_hours, day_files
from lake import (
    CANDIDATES,
    EVENTS,
    GH_RELEASES,
    REPO_HOUR,
    candidates_schema,
    candidates_spec,
    events_properties,
    events_schema,
    events_spec,
    gh_releases_schema,
    gh_releases_spec,
    index_properties,
    repo_hour_properties,
    repo_hour_schema,
    repo_hour_spec,
)
from reindex import index_hour, index_job


def hour_task(day: String, hour: Int) raises -> DataFiles:
    """Downloads and parses one hour of GH Archive on a worker and writes its
    rows, uncommitted.
    The event files and the hour's three index files come back as entries
    (`DataFiles`), which the step commits; nothing else crosses back. With
    `GHARCHIVE_EVENTS=off` there are no event files. An hour GH Archive
    never published comes back empty with `missing` set (`hour_overdue`)."""
    try:
        var events = Optional[Table]()
        if keep_events():
            events = load_dataset(EVENTS)
        return fetch_hour(
            day,
            hour,
            events,
            load_dataset(CANDIDATES),
            load_dataset(REPO_HOUR),
            load_dataset(GH_RELEASES),
        )
    except e:
        var err = String(e)
        if not_found(err) and hour_overdue(day, hour, Int(now())):
            var gone = DataFiles()
            gone.missing = True
            return gone^
        raise Error(day, " hour ", hour, ": ", err)


# A dista `Task` is a function that runs on a worker process (`Task2` takes
# two arguments). The step starts them with `rt.remote[...]`, which returns an
# `ObjectRef`: a future for the result, read with `rt.get`. `Hour` is the
# main one, a download and parse of one hour; `IndexHour` rebuilds an hour's
# index files from `gharchive.events` when a retry skipped it; `MergeHours`
# writes a day's `repo_hour` files as one. `Tasks[...]` lists them all, and
# morca starts one dista runtime for the run before its first step, which the
# step reaches through `ctx.runtime`.
comptime IndexHour = Task[String, IndexFiles, index_hour]
comptime Hour = Task2[String, Int, DataFiles, hour_task]
comptime MergeHours = Task[String, IndexFiles, merge_repo_hour]
comptime GhTasks = Tasks[Hour, IndexHour, MergeHours]


def _marker_if_empty(
    mut files: FileEntries, day: String, which: Int, t: Table
) raises:
    """A day with no rows for `t` at all: its commit needs a file, since a
    snapshot needs one, so it gets the marker row `hourindex.HourIndex`
    describes."""
    if len(files) == 0:
        files = write_marker(days_of(day) * 86_400_000_000, which, t)


def load_day(mut ctx: Ctx, d: Day) raises -> Int64:
    """Loads one day of GH Archive into the candidates, repo_hour and
    releases tables, and into the events when they are kept. Hours are read
    on workers, `window` at a time, and committed here in hour order.
    Returns the number of events committed by this attempt (a retry that
    skipped hours counts only the rest); with `GHARCHIVE_EVENTS=off`, the
    number of events it parsed into the index."""
    var day = String(d)
    var hours = parse_hours(getenv("GHARCHIVE_HOURS"))
    var props = index_properties()
    # `GHARCHIVE_EVENTS=off`: no events table is made, loaded or committed.
    var keep = keep_events()
    var events_t = Optional[Table]()
    if keep:
        events_t = ensure_table(
            ctx, EVENTS, events_schema(), events_spec(), events_properties()
        )
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
    ref rt = ctx.runtime[GhTasks]()
    # Hours in flight at once. Memory is what limits it: an hour in flight
    # takes about HOUR_MEMORY_MB (HOUR_INDEX_MEMORY_MB without the events),
    # so the default of 16 is sized for several machines; morca.toml sets 4
    # for the 8 GB Hetzner server.
    var window = max(1, Int(getenv("GHARCHIVE_PARALLEL", "16")))
    var in_flight = min(window, len(hours))
    var per_hour_mb = HOUR_MEMORY_MB if keep else HOUR_INDEX_MEMORY_MB
    ctx.log(String(
        day, ": ", in_flight, " hours in flight, about ",
        300 + in_flight * per_hour_mb, " MB",
        "" if keep else " (GHARCHIVE_EVENTS=off: the index only)",
    ))

    # Hours an earlier attempt of this step already committed to the events
    # come first in its commit order; recognise them without fetching
    # anything. The three index tables get one commit a day, at the end: an
    # attempt that got that far has made commit 0 to each (`find_commit`).
    # Without the events nothing is committed by the hour, so no hour counts
    # as done and only the index commits are recognised.
    var d_ev = 0
    if keep:
        d_ev = committed_hours(ctx, events_t.value(), len(hours))
    var indexed = (
        find_commit(ctx, cand_t) >= 0
        and find_commit(ctx, hour_t) >= 0
        and find_commit(ctx, rel_t) >= 0
    )
    if d_ev > 0:
        ctx.log(String(day, ": ", d_ev, " hours already committed"))

    # Rows an earlier run left for this day, which this run's first commit
    # to the events replaces (the index tables' day commit does the same).
    var old = List[String]()
    if keep and d_ev == 0:
        old = day_files(events_t.value(), day, "created_at")
        if len(old) > 0:
            ctx.log(String(
                day, ": replacing the ", len(old),
                " event files an earlier run committed",
            ))

    # The index files of every hour, in hour order, committed together at
    # the end. An hour whose events an earlier attempt committed lost its
    # index files with that attempt: build them again from the events, as
    # gharchive_index does, unless the index was committed too.
    var idx = List[IndexFiles]()
    for _ in range(len(hours)):
        idx.append(IndexFiles())
    if d_ev > 0 and not indexed:
        var pinned = events_t.value().metadata.current_snapshot_id
        ctx.log(String(
            day, ": rebuilding the index of the ", d_ev,
            " committed hours from the events (snapshot ", pinned, ")",
        ))
        var t_re = perf_counter_ns()
        var back = List[ObjectRef[IndexFiles]]()
        var sent = 0
        while sent < d_ev and sent < window:
            back.append(
                rt.remote[IndexHour](index_job(day, hours[sent], pinned, False))
            )
            sent += 1
        for i in range(d_ev):
            var got = rt.get(back[i])
            rt.release(back[i])
            if sent < d_ev:
                back.append(
                    rt.remote[IndexHour](
                        index_job(day, hours[sent], pinned, False)
                    )
                )
                sent += 1
            idx[i] = got^
        ctx.log(String(
            day, ": rebuilt ", d_ev, " hours of the index in ",
            Int(perf_counter_ns() - t_re) // 1_000_000, " ms",
        ))

    # A sliding window of futures: start `window` hours, then each time the
    # oldest finishes (`rt.get`) and is released (`rt.release` frees its
    # result on the worker), start the next one. Results are consumed in hour
    # order because the commits must be, so a slow hour holds up the commit of
    # the later ones (their tasks keep running meanwhile).
    # Without the events, a retry after the index commits has nothing left
    # to do but recognise them below: no hour is fetched (`first`).
    var first = d_ev
    if not keep and indexed:
        first = len(hours)
        ctx.log(String(day, ": the index is committed already"))
    var refs = List[ObjectRef[DataFiles]]()
    var next = first
    while next < len(hours) and next - first < window:
        refs.append(rt.remote[Hour](day, hours[next]))
        next += 1
    var rows = Int64(0)
    var missing = List[Int]()
    var fail = getenv("GHARCHIVE_FAIL_AFTER")
    var fail_after = Int(fail) if fail and fail != "end" else 0
    for i in range(first, len(hours)):
        var got = rt.get(refs[i - first])
        rt.release(refs[i - first])
        if next < len(hours):
            refs.append(rt.remote[Hour](day, hours[next]))
            next += 1
        # An hour GH Archive never published (#77): with the events off the
        # day goes on without it, its index files left empty. With them on
        # every hour is one snapshot of the events and a retry counts the
        # committed hours by position, so a gap there still fails the day.
        if got.missing:
            if keep:
                raise Error(
                    day, " hour ", hours[i], ": GH Archive has no file for",
                    " it (HTTP 404), and with GHARCHIVE_EVENTS=on every hour",
                    " is one snapshot of the events; load the day with",
                    " GHARCHIVE_EVENTS=off",
                )
            missing.append(hours[i])
            ctx.log(String(
                day, " hour ", hours[i], ": GH Archive has no file for it",
                " (HTTP 404, ", hour_url(day, hours[i]), "); the day goes on",
                " without it",
            ))
            continue
        # The task read GHARCHIVE_EVENTS itself: the step and its workers
        # must agree, or event files would go uncommitted (or be missing).
        if not keep and len(got.files) > 0:
            raise Error(
                day, " hour ", hours[i], ": GHARCHIVE_EVENTS=off here but",
                " the task wrote ", len(got.files), " event files",
            )
        if keep and got.rows > 0 and len(got.files) == 0:
            raise Error(
                day, " hour ", hours[i], ": GHARCHIVE_EVENTS is on here but",
                " the task wrote no event files",
            )
        # One snapshot of the events per hour: the first one of a rerun
        # replaces the day's old files, a retry's recommit is recognised.
        var t0 = perf_counter_ns()
        var id = Int64(-1)
        if keep:
            try:
                id = commit_hour(
                    ctx, events_t.value(), i, d_ev, old, got.files
                )
            except e:
                raise Error(day, " hour ", hours[i], ": committing: ", e)
        var commit_ms = Int(perf_counter_ns() - t0) // 1_000_000
        rows += Int64(got.rows)
        ctx.log(
            String(
                day, " hour ", hours[i], ": ", got.rows, " events in ",
                len(got.files), " files, snapshot ",
                String(id) if keep else String("none"), " (task ",
                got.total_ms, " ms: download ", got.download_ms,
                " ms overlapping gunzip ", got.gunzip_ms, " ms, parse ",
                got.parse_ms, " ms, sort ", got.sort_ms, " ms, write ",
                got.write_ms, " ms, index ",
                got.index_ms, " ms: ", got.index.candidate_rows,
                " candidates, ", got.index.repo_hour_rows, " repo-hours, ",
                got.index.release_rows, " releases; waiting ", got.wait_ms,
                " ms; commit ", commit_ms, " ms)",
            )
        )
        idx[i] = got.index.copy()
        # A test hook: the first attempt fails after this many hours.
        if fail_after > 0 and ctx.attempt <= 1 and i + 1 == fail_after:
            raise Error(day, ": GHARCHIVE_FAIL_AFTER=", fail_after)

    if len(missing) > 0:
        var names = String()
        for h in missing:
            names.write(", " if names else "", h)
        ctx.log(String(
            day, ": loaded without ", len(missing), " hour",
            "s" if len(missing) > 1 else "", " GH Archive never published (",
            names, ")",
        ))

    # One commit a day to each index table, all 24 hours' files in hour order.
    var t1 = perf_counter_ns()
    var cand = FileEntries()
    var per_hour = FileEntries()
    var rel = FileEntries()
    for ref f in idx:
        cand.add(f.candidates)
        per_hour.add(f.repo_hour)
        rel.add(f.releases)
    if not indexed and len(per_hour) > 1:
        # The day's repo_hour rows as one file: a dictionary needs more rows
        # than an hour has to pay for itself.
        var paths = List[String]()
        for f in per_hour.files():
            paths.append(f.file_path)
        var merging = rt.remote[MergeHours](merge_job(paths))
        var merged = rt.get(merging)
        rt.release(merging)
        per_hour = merged.repo_hour.copy()
        ctx.log(String(
            day, ": repo_hour merged from ", len(paths), " files to ",
            len(per_hour), " (", merged.repo_hour_rows, " rows, ",
            merged.write_ms, " ms)",
        ))
    if not indexed:
        _marker_if_empty(cand, day, 0, cand_t)
        _marker_if_empty(per_hour, day, 1, hour_t)
        _marker_if_empty(rel, day, 2, rel_t)
    try:
        _ = commit_day(ctx, cand_t, day, "hour", cand)
        _ = commit_day(ctx, hour_t, day, "hour", per_hour)
        _ = commit_day(ctx, rel_t, day, "created_at", rel)
    except e:
        raise Error(day, ": committing the index: ", e)
    ctx.log(String(
        day, ": index committed in ",
        Int(perf_counter_ns() - t1) // 1_000_000, " ms (",
        len(cand), " + ", len(per_hour), " + ", len(rel), " files)",
    ))
    if fail == "end" and ctx.attempt <= 1:
        raise Error(day, ": GHARCHIVE_FAIL_AFTER=end")
    ctx.log(String(
        day, ": ", rows, " events in ", len(hours) - first, " hours",
        "" if keep else " (not kept: GHARCHIVE_EVENTS=off)",
    ))
    return rows


# A `Step` wraps `load_day` with its name, input and output types and kind.
# `Mapped` runs it once per partition of a run, here a `Day`. `writes` lists
# the datasets it commits to (a commit to any other is refused, and the
# lineage in the UI is drawn from it). EVENTS stays in it with
# GHARCHIVE_EVENTS=off: `writes` allows commits, it doesn't require them, and
# the list is part of the registry hash, which decides which runs of a day
# count as done; the replace-the-day logic is done by
# hand in `indexing.commit_hour` rather than by morca's `replaces=`. `retries=2`
# re-runs a failed attempt in the same run, which the commit recognition
# above makes cheap.
comptime LoadDay = Step[
    "load_day",
    Day,
    Int64,
    load_day,
    Mapped,
    retries=2,
    writes=[EVENTS, CANDIDATES, REPO_HOUR, GH_RELEASES],
]
# `Daily["2023-01-01"]` makes the partitions days from that date; the `Cron`
# schedule fires the day's run, and the pipeline is not a sensor, so it is the
# root of the chain: mojo_repos and mojo_activity are sensors on what it
# commits.
comptime GhArchive = Pipeline[
    "gharchive",
    LoadDay,
    tasks=GhTasks,
    partitions=Daily["2023-01-01"],
    schedule=Cron["0 3 * * *"],  # 03:00 UTC, for the day before
    max_runs=2,  # two days at once: a day's commits (the events an hour) are serial
    workers=8,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[GhArchive]()
