"""A digest of a gharchive table, for comparing two warehouses: the number of
rows that are not marker rows (no repository), an order-independent hash of
those, how many marker rows there are, and the number of snapshots.

    MORCA_WAREHOUSE=build/warehouse pixi run mojo run -I src tools/dump_index.mojo gharchive.candidates [2024-06-12]

`scripts/test-daily.sh` compares these across runs. Tables: gharchive.candidates,
gharchive.repo_hour, gharchive.releases, gharchive.events (a day, optionally).
"""

from std.sys import argv

from cols import bool_at, col, i64_at, str_at
from days import day_text, days_of
from lake import load


def _names(dataset: String) raises -> List[String]:
    if dataset == "gharchive.candidates":
        return ["repo", "hour", "reason", "first_seen", "sha"]
    if dataset == "gharchive.repo_hour":
        return [
            "repo", "hour", "actor", "events", "stars", "forks", "releases",
            "issues_opened", "prs_opened", "pushes",
        ]
    if dataset == "gharchive.releases":
        return [
            "repo", "created_at", "actor", "tag", "name", "published_at",
            "prerelease",
        ]
    if dataset == "gharchive.events":
        return ["created_at", "repo"]
    raise Error("unknown table ", dataset)


def _kinds(dataset: String) raises -> String:
    """One letter a column, in the same order: S string, I long or
    timestamp, B boolean."""
    if dataset == "gharchive.candidates":
        return "SISIS"
    if dataset == "gharchive.repo_hour":
        return "SISIIIIIII"
    if dataset == "gharchive.events":
        return "IS"
    return "SISSSIB"


def main() raises:
    var dataset = String(argv()[1])
    var dot = dataset.find(".").or_else(-1)
    var t = load(String(dataset[byte=:dot]), String(dataset[byte = dot + 1 :]))
    var kinds = _kinds(dataset)
    var names = _names(dataset)
    var scan = t.scan().select(names.copy())
    if len(argv()) > 2:
        # Only one day: the table's day column is the first timestamp.
        var day = String(argv()[2])
        var column = "created_at"
        if dataset == "gharchive.candidates" or dataset == "gharchive.repo_hour":
            column = "hour"
        var dd = days_of(day)
        scan = scan.filter(String(
            '["and",[">=","', column, '","', day, 'T00:00:00Z"],',
            '["<","', column, '","', day_text(dd + 1), 'T00:00:00Z"]]',
        ))
    var reader = scan.to_batch_reader()
    var rows = 0
    var markers = 0
    var digest = UInt64(0)
    while True:
        var next = reader.next_batch()
        if not next:
            break
        var b = next.take()
        for r in range(b.num_rows):
            var line = String()
            for c in range(len(names)):
                ref a = b.column(col(b, names[c]))
                var k = kinds[byte=c]
                if k == "S":
                    line.write(str_at(a, r), "\x1f")
                elif k == "I":
                    line.write(i64_at(a, r), "\x1f")
                else:
                    line.write(bool_at(a, r), "\x1f")
            rows += 1
            if str_at(b.column(col(b, "repo")), r).byte_length() == 0:
                markers += 1
                continue
            digest += UInt64(hash(line))
    print(
        dataset, ": rows ", rows - markers, " digest ", digest, " markers ",
        markers, " snapshots ", len(t.metadata.snapshots), sep="",
    )
