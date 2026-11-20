"""Removes the rows one morca run appended to one partition of a table: one
`delete` snapshot that drops exactly the data files that run's snapshots
added for it. For repairing a day a rerun appended twice (before gharchive
replaced a day's rows on a rerun).

    pixi run mojo run -I src tools/drop_run.mojo gharchive.events 133 2026-10-13
    pixi run mojo run -I src tools/drop_run.mojo gharchive.events 133 2026-10-13 --commit

With `MORCA_WAREHOUSE` (and AWS credentials for `s3://`). Without
`--commit` it only reports. The snapshot's summary carries
`orca.partitions`, so sensors downstream rerun that partition.
"""

from std.sys import argv

from iceberg.commit import FileChanges, prepare_commit
from iceberg.manifest import STATUS_ADDED, read_manifest_io, read_manifest_list_io

from lake import load


def main() raises:
    var args = argv()
    if len(args) < 4:
        raise Error("usage: drop_run <namespace.table> <run> <partition> [--commit]")
    var dataset = String(args[1])
    var run = String(args[2])
    var partition = String(args[3])
    var do_commit = len(args) > 4 and String(args[4]) == "--commit"
    var dot = dataset.find(".").or_else(-1)
    var t = load(String(dataset[byte=:dot]), String(dataset[byte = dot + 1 :]))

    # The snapshots that run committed for that partition, and the files each
    # one added.
    var paths = List[String]()
    var rows = Int64(0)
    var snaps = 0
    var other_rows = Int64(0)
    for s in t.metadata.snapshots:
        var p = s.summary.get("orca.partition", String())
        if p != partition:
            continue
        var r = s.summary.get("orca.run", String())
        if r != run:
            other_rows += s.summary_int("added-records", 0)
            continue
        snaps += 1
        for mf in read_manifest_list_io(t.io, s.manifest_list):
            if mf.added_snapshot_id != s.snapshot_id:
                continue
            var m = read_manifest_io(t.io, mf.manifest_path, mf)
            for ref e in m.entries:
                if e.status == STATUS_ADDED and e.snapshot_id == s.snapshot_id:
                    paths.append(e.data_file.file_path)
                    rows += e.data_file.record_count
    print(
        dataset, " run ", run, " partition ", partition, ": ", snaps,
        " snapshots added ", len(paths), " files, ", rows, " rows; other runs",
        " added ", other_rows, " rows to it",
    )

    # Every one of them must still be live, or this isn't the repair it was.
    var live = Dict[String, Bool]()
    for task in t.scan().plan_files():
        live[task.data_file.file_path] = True
    for ref p in paths:
        if p not in live:
            raise Error("not in the current snapshot: ", p)
    if len(paths) == 0:
        print("nothing to remove")
        return
    if not do_commit:
        print("dry run; add --commit to remove them")
        return
    var change = FileChanges()
    change.removed = paths.copy()
    var summary = Dict[String, String]()
    summary["orca.partitions"] = partition
    summary["mojo-census.dropped-run"] = run
    var result = prepare_commit(t.io, t.metadata, "delete", change^, summary^)
    t.commit(result)
    print("committed snapshot ", result.snapshot_id)
