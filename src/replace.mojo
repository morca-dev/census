"""Replacing a table's rows by partition, so a rerun doesn't duplicate them.

morca.tables has `append` and `commit`; a step that recomputes some of a
table's rows reads the partitions those rows live in, keeps the rows it
didn't recompute, and commits one `overwrite` snapshot that removes the
partitions' files and adds the kept rows with the new ones. A retried
attempt finds the commit its earlier attempt made (`find_commit`) and
doesn't write again.

This is safe for one writer per table at a time; the pipelines that use it
run one run at a time (`max_runs=1`). Two writers that read before either
commits would both keep the other's rows (morca-dev/morca#120, morca's
replace mode, and magmalake/iceberg.mojo#83).
"""

from iceberg.catalog.filesystem import Table as IcebergTable
from iceberg.scan import FileScanTask
from morca import Ctx
from morca.tables import (
    FileChanges,
    Table,
    append,
    commit,
    find_commit,
    write_files,
)
from parquet import RecordBatch


@fieldwise_init
struct PartitionFiles(Copyable, Movable):
    """Data files found by `partition_files`: their paths, and the rows they
    hold according to the manifests (which callers compare with the rows they
    actually read, to be sure they read everything they are about to remove).
    `tasks` are the planned reads of those files (`read_partition_files`)."""

    var paths: List[String]
    var rows: Int64
    var tasks: List[FileScanTask]


def partition_files(
    t: IcebergTable, partitions: Dict[Int, Bool], filter: String = '["true"]'
) raises -> PartitionFiles:
    """The current snapshot's data files whose first partition value is one
    of `partitions`, and how many rows they hold. `filter`, a row filter the
    partitions' rows all match, lets planning skip the other manifests."""
    var out = PartitionFiles(List[String](), 0, List[FileScanTask]())
    if not t.metadata.has_current_snapshot:
        return out^
    # `plan_files` lists the files without reading them. The filter only
    # prunes what planning looks at; the partition value of each file decides
    # (`f.partition[0]` is the first partition field: the month, for the
    # tables replaced here, or the day).
    for task in t.scan().filter(filter).plan_files():
        ref f = task.data_file
        if len(f.partition) == 0 or not f.partition[0].valid:
            continue
        if Int(f.partition[0].i) in partitions:
            out.paths.append(f.file_path)
            out.rows += f.record_count
            out.tasks.append(task.copy())
    return out^


def read_partition_files(
    t: IcebergTable, files: PartitionFiles, filter: String = '["true"]'
) raises -> List[RecordBatch]:
    """The rows of the files `partition_files` found, read from its planned
    tasks: only those files, without planning the table again. `filter` is
    the one they were planned with."""
    if len(files.tasks) == 0:
        return List[RecordBatch]()
    return t.scan().filter(filter).to_batches_for_tasks(files.tasks.copy())


def already_committed(ctx: Ctx, t: Table) -> Bool:
    """Whether an earlier attempt of this step made its next commit to `t`
    (a retry then must not write or remove anything again)."""
    return find_commit(ctx, t) >= 0


def replace_files(
    mut ctx: Ctx,
    mut t: Table,
    removed: List[String],
    batches: List[RecordBatch],
) raises -> Int64:
    """One snapshot that removes `removed` and adds `batches`: an
    `overwrite`, or an `append` when nothing is removed. Returns its ID, the
    one an earlier attempt of this step committed, or -1 when there was
    nothing to add or remove (no snapshot)."""
    var some = List[RecordBatch]()
    for b in batches:
        if b.num_rows > 0:
            some.append(b.copy())
    # A retry whose first attempt got this far gets that snapshot's id back
    # from `append` (which recognises it) and writes nothing.
    if already_committed(ctx, t):
        return append(ctx, t, some)
    if len(removed) == 0 and len(some) == 0:
        return -1  # nothing to change, and no snapshot for it
    if len(removed) == 0:
        return append(ctx, t, some)
    # The new files and the removal of the old ones are one snapshot: a
    # reader sees the table before or after the replace, never with both
    # copies of a row or with neither.
    var files = FileChanges()
    if len(some) > 0:
        files.added_data = write_files(t, some)
    files.removed = removed.copy()
    return commit(ctx, t, "overwrite", files^)
