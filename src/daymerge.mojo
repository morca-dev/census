"""A day of `gharchive.repo_hour` as one file.

The hour tasks each write their rows of the table, sorted by (repo, actor,
hour). A dictionary needs many rows to pay for itself, and ~70k-100k rows an
hour do not: the day's 24 files are 35.7 MB, and merged into one file in the
same order, with dictionaries and zstd 9, 20.9 MB (magmalake/mojo-census#28).
The step commits the index tables once a day, so nothing has to look at the
hourly files: this reads the 24 that are not yet committed, writes the one
that replaces them, and deletes them.
"""

from std.time import perf_counter_ns

from morca.tables import FileWriter, concat_batches, load_dataset
from parquet import RecordBatch

from hourindex import IndexFiles
from lake import REPO_HOUR
from sortrows import sorted_by_text


def merge_job(paths: List[String]) -> String:
    """The `merge_repo_hour` job for files of the table, in hour order: the
    paths, one a line, as one string (the single argument of a dista task
    here)."""
    var job = String()
    for i in range(len(paths)):
        if i > 0:
            job += "\n"
        job += paths[i]
    return job^


def merged_rows(batches: List[RecordBatch]) raises -> RecordBatch:
    """`batches` as one batch, rows in the order given."""
    var some = List[RecordBatch]()
    for ref b in batches:
        if b.num_rows > 0:
            some.append(b.copy())
    if len(some) == 0:
        return RecordBatch()
    return concat_batches(some)


def merge_repo_hour(job: String) raises -> IndexFiles:
    """Merges a day's uncommitted repo_hour files into one sorted file on a
    worker.
    The files are the paths in `job` (one a line, in hour order); the new
    file is sorted by (repo, actor, hour) and replaces them. `repo_hour` of
    the answer is that file's entry, none if the files had no rows."""
    var t0 = perf_counter_ns()
    # Files are read back through the table's own IO, the way they were
    # written: they are not in any snapshot yet, so a scan can't find them.
    var table = load_dataset(REPO_HOUR)
    var paths = List[String]()
    for p in job.split("\n"):
        paths.append(String(p))
    var batches = List[RecordBatch]()
    for ref p in paths:
        batches.extend(table.read_file(p))
    var out = IndexFiles()
    var all = merged_rows(batches)
    batches.clear()
    if all.num_rows > 0:
        # The hours were appended in order and the sort is stable, so rows
        # with the same (repo, actor) stay in hour order.
        # Repository first, so mojo_activity's scan for a handful of
        # repositories (it filters on `repo`) can skip most row groups; then
        # actor, with hours left in order by the stable sort.
        var w = FileWriter(table)
        w.put(sorted_by_text(all, "repo", "actor"))
        out.repo_hour_rows = w.rows
        out.repo_hour = w^.finish()
    # The hourly files were never committed, so nothing references them; the
    # merged file replaces them in the day's commit. A task that dies before
    # this point leaves them, and the step's retry builds them again.
    for ref p in paths:
        table.delete_file(p)
    out.write_ms = Int(perf_counter_ns() - t0) // 1_000_000
    return out^
