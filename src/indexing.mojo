"""Committing files to the tables of a day, and replacing the day's earlier
files with the first commit.

`gharchive.events` gets a snapshot an hour (`commit_hour`). Its companions
(`candidates`, `repo_hour`, `releases`) get one snapshot a day from gharchive
(`commit_day`) and one an hour from gharchive_index (`commit_hour`). Each
table counts its own commits (`morca.tables.find_commit`), so a retried step
finds, per table, what it already committed.
"""

from morca import Ctx
from morca.tables import (
    DataFiles,
    FileChanges,
    Table,
    append,
    append_files,
    commit,
    find_commit,
)
from parquet import RecordBatch

from days import day_text, days_of
from replace import partition_files


def committed_hours(mut ctx: Ctx, mut t: Table, n_hours: Int) raises -> Int:
    """How many of the step's first hours `t` already has a commit for;
    their ids are recorded again."""
    # `find_commit` answers for the step's *next* commit to `t`, and an
    # empty `append` records the one it found, which moves on to the
    # following one: the loop counts commits in order until one is missing.
    var done = 0
    while done < n_hours and find_commit(ctx, t) >= 0:
        _ = append(ctx, t, List[RecordBatch]())
        done += 1
    return done


def day_files(t: Table, day: String, column: String) raises -> List[String]:
    """The paths of the files `t` holds for `day` (a day partition of the
    timestamp column `column`). These are what a rerun's first commit
    removes."""
    var dd = days_of(day)
    var parts = Dict[Int, Bool]()
    parts[Int(dd)] = True
    # The row filter is for planning only (it lets the scan skip the other
    # days' manifests); `partition_files` then keeps the files whose day
    # partition is `dd`.
    var f = partition_files(
        t,
        parts,
        String(
            '["and",[">=","', column, '","', day, 'T00:00:00Z"],',
            '["<","', column, '","', day_text(dd + 1), 'T00:00:00Z"]]',
        ),
    )
    return f.paths.copy()


def commit_hour(
    mut ctx: Ctx,
    mut t: Table,
    i: Int,
    done: Int,
    old: List[String],
    files: DataFiles,
) raises -> Int64:
    """Hour `i`'s files as `t`'s next snapshot: found again if an earlier
    attempt made it (`i < done`), an `overwrite` that also removes `old` if
    it is the first (`old` is only given when nothing was committed yet),
    else an append. Every hour has a file, empty if need be: a snapshot
    needs one, and one per hour keeps each table's numbering aligned."""
    if i < done:
        return append(ctx, t, List[RecordBatch]())
    # The first commit of a rerun is the one that replaces: later hours just
    # append to a table that by then holds only the new run's files.
    if i == done and len(old) > 0:
        var change = FileChanges()
        change.added_data = files.copy()
        change.removed = old.copy()
        return commit(ctx, t, "overwrite", change^)
    return append_files(ctx, t, files)


def commit_day(
    mut ctx: Ctx,
    mut t: Table,
    day: String,
    column: String,
    files: DataFiles,
) raises -> Int64:
    """All of the day's `files` as `t`'s one commit of the step: found again
    if an earlier attempt made it (it is the step's commit number 0 to `t`,
    which `find_commit` matches), else an `overwrite` that also removes the
    files an earlier run left for the day, else an append. `column` is
    the table's day-partitioned timestamp column."""
    if find_commit(ctx, t) >= 0:
        return append(ctx, t, List[RecordBatch]())
    # The day commit is "hour 0 of 0 done": the replacing overwrite if the day
    # has old files, else an append.
    return commit_hour(ctx, t, 0, 0, day_files(t, day, column), files)
