"""Checks that the index says what the events say: for a day of a local
warehouse, counts every repository's events from `gharchive.events` the old
way (`activity.add_event`) and reads the same repositories through
`day_activity` (`gharchive.repo_hour` and `gharchive.releases`), and fails on
any difference.

    mojo build -I src tools/compare_activity.mojo -o build/compare_activity
    MORCA_WAREHOUSE=build/wh ./build/compare_activity 2023-01-10 [every_nth]
"""

from std.sys import argv
from std.time import perf_counter_ns

from activity import Acc, ReleaseRow, add_event, day_activity, encode_job, finish
from cols import str_at, str_range
from days import day_text, days_of
from lake import load


def main() raises:
    var args = argv()
    var day = String(args[1])
    var nth = Int(args[2]) if len(args) > 2 else 1
    var d = days_of(day)
    var events = load("gharchive", "events")
    var filter = String(
        '["and",[">=","created_at","', day, 'T00:00:00Z"],',
        '["<","created_at","', day_text(d + 1), 'T00:00:00Z"]]',
    )
    var t0 = perf_counter_ns()
    var all = Dict[String, Int]()
    var accs = Dict[String, Acc]()
    var rels = List[ReleaseRow]()
    var seen = 0
    for b in (
        events.scan().filter(filter)
        .select(["type", "repo", "actor", "payload"]).to_batches()
    ):
        ref ty = b.column(0)
        ref rp = b.column(1)
        ref ac = b.column(2)
        ref pl = b.column(3)
        var pv = Span(pl.values)
        for r in range(b.num_rows):
            var repo = str_at(rp, r)
            if repo not in all:
                all[repo] = len(all)
            # every nth repository, by first appearance
            if all[repo] % nth != 0:
                continue
            if repo not in accs:
                accs[repo] = Acc(repo, d)
            var pr = str_range(pl, r)
            add_event(accs[repo], rels, str_at(ty, r), str_at(ac, r), pv[pr[0] : pr[1]])
            seen += 1
    var old_ms = Int(perf_counter_ns() - t0) // 1_000_000
    var names = List[String]()
    for e in accs.items():
        names.append(e.key)
    var want = finish(accs^)
    var hours = load("gharchive", "repo_hour")
    var gh = load("gharchive", "releases")
    var t1 = perf_counter_ns()
    var got = day_activity(
        encode_job(
            day, hours.metadata.current_snapshot_id,
            gh.metadata.current_snapshot_id, names,
        )
    )
    var new_ms = Int(perf_counter_ns() - t1) // 1_000_000
    print(len(names), "repositories,", seen, "events;", len(want), "rows from events in", old_ms, "ms,", len(got.rows), "from repo_hour in", new_ms, "ms")
    var bad = 0
    if len(want) != len(got.rows):
        print("row count differs")
        bad += 1
    else:
        for i in range(len(want)):
            ref a = want[i]
            ref b = got.rows.items[i]
            if (
                a.repo != b.repo or a.events != b.events or a.stars != b.stars
                or a.forks != b.forks or a.releases != b.releases
                or a.issues_opened != b.issues_opened or a.prs_opened != b.prs_opened
                or a.pushes != b.pushes or a.actors != b.actors or a.day != b.day
            ):
                print("differs:", a.repo, a.events, b.events, a.actors, b.actors)
                bad += 1
    if len(rels) != len(got.releases):
        print("releases:", len(rels), "vs", len(got.releases))
        bad += 1
    else:
        var tags = Dict[String, Bool]()
        for ref r in rels:
            tags[String(r.repo, "|", r.tag, "|", r.actor, "|", r.published_at)] = True
        for ref r in got.releases.items:
            if String(r.repo, "|", r.tag, "|", r.actor, "|", r.published_at) not in tags:
                print("release differs:", r.repo, r.tag)
                bad += 1
    if bad > 0:
        raise Error(bad, " differences")
    print("same:", len(want), "activity rows,", len(rels), "releases")
