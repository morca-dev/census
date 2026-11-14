"""Activity over time from GH Archive, with no API calls: per repository and
day, the stars (WatchEvent), forks, published releases, issues and pull
requests opened, pushes and distinct actors, and each published release.

`day_activity` reads one day of `gharchive.repo_hour` and
`gharchive.releases` for a set of repositories (a dista task in
mojo_activity); gharchive's hour tasks wrote those tables with `add_event`'s
counting (`hourindex.HourIndex.add` does the same per hour, and
`parse_release` reads a ReleaseEvent's payload).
"""

from std.time import perf_counter_ns

from dista import Seq
from iceberg.json import json_quote
from morca.tables import BatchBuilder, load_dataset
from parquet import RecordBatch

from cols import bool_at, col, i32_at, i64_at, str_at, str_range
from days import day_text, days_of
from jscan import Range, field, text, timestamp_micros
from lake import (
    GH_RELEASES,
    REPO_HOUR,
    activity_schema,
    add_str_or_null,
    add_ts_or_null,
    releases_schema,
)


@fieldwise_init
struct ActivityRow(Copyable, Movable):
    """One repository's counts on one day: a row of `mojo.activity`."""

    var repo: String
    var day: Int64
    """Days since 1970-01-01."""
    var events: Int64
    var stars: Int64
    var forks: Int64
    var releases: Int64
    var issues_opened: Int64
    var prs_opened: Int64
    var pushes: Int64
    var actors: Int64


@fieldwise_init
struct ReleaseRow(Copyable, Movable):
    """One published release: a row of `mojo.releases`."""

    var repo: String
    var day: Int64
    var tag: String
    var name: String
    var published_at: Int64
    var prerelease: Bool
    var actor: String


@fieldwise_init
struct DayActivity(Copyable, Movable):
    """What a day's task sends back. A plain struct of `Seq`s, which dista
    sends by reflection."""

    var day: Int64
    var rows: Seq[ActivityRow]
    var releases: Seq[ReleaseRow]
    var scanned: Int
    """Events read, of every repository."""
    var ms: Int


struct Acc(Copyable, Movable):
    """One repository's counts on one day so far. The distinct actors are a
    set because an actor repeats across hours (`repo_hour` has a row per
    actor and hour); `finish` puts its size in the row's `actors`."""

    var row: ActivityRow
    var actors: Dict[String, Bool]

    def __init__(out self, repo: String, day: Int64):
        self.row = ActivityRow(repo, day, 0, 0, 0, 0, 0, 0, 0, 0)
        self.actors = Dict[String, Bool]()


def _action(p: Span[UInt8, _]) -> String:
    """The `action` field of an event payload (`opened`, `published`, ...)."""
    return text(p, field(p, Range(0, len(p)), "action"))


def parse_release(
    repo: String, day: Int64, actor: String, p: Span[UInt8, _]
) -> Optional[ReleaseRow]:
    """The release a ReleaseEvent published, or None for another action
    (`created`, `edited`, ...) or a payload without a tag."""
    if _action(p) != "published":
        return None
    var r = field(p, Range(0, len(p)), "release")
    if not r.found():
        return None
    var tag = text(p, field(p, r, "tag_name"))
    if tag.byte_length() == 0:
        return None
    return ReleaseRow(
        repo,
        day,
        tag,
        text(p, field(p, r, "name")),
        timestamp_micros(p, field(p, r, "published_at")),
        text(p, field(p, r, "prerelease")) == "true",
        actor,
    )


def add_event(
    mut acc: Acc,
    mut releases: List[ReleaseRow],
    type: StringSlice,
    actor: String,
    payload: Span[UInt8, _],
):
    """Counts one event of the repository `acc` is for. Stars are
    WatchEvents (GitHub's name for starring), and an issue or pull request
    counts only when it is `opened`, not for each comment or label."""
    acc.row.events += 1
    if actor.byte_length() > 0:
        acc.actors[actor] = True
    if type == "WatchEvent":
        acc.row.stars += 1
    elif type == "ForkEvent":
        acc.row.forks += 1
    elif type == "PushEvent":
        acc.row.pushes += 1
    elif type == "IssuesEvent":
        if _action(payload) == "opened":
            acc.row.issues_opened += 1
    elif type == "PullRequestEvent":
        if _action(payload) == "opened":
            acc.row.prs_opened += 1
    elif type == "ReleaseEvent":
        var rel = parse_release(acc.row.repo, acc.row.day, actor, payload)
        if rel:
            acc.row.releases += 1
            releases.append(rel.take())


def finish(var accs: Dict[String, Acc]) -> List[ActivityRow]:
    """The rows, by repository name (sorted, so the same input always gives
    the same rows whatever order the `Dict` iterates in)."""
    var out = List[ActivityRow]()
    for e in accs.items():
        var row = e.value.row.copy()
        row.actors = Int64(len(e.value.actors))
        out.append(row^)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].repo > out[j].repo:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def fold_hours(
    b: RecordBatch,
    day: Int64,
    repos: Dict[String, Bool],
    mut accs: Dict[String, Acc],
) raises:
    """Adds a batch of `gharchive.repo_hour` rows of `repos` (columns repo,
    actor, events, stars, forks, releases, issues_opened, prs_opened,
    pushes): the counts `add_event` makes from the events themselves. Each
    row is one (repository, actor, hour), so the counts add up and the actor
    joins the set. The scan's filter keeps whole row groups, so rows of other
    repositories still arrive and are dropped here."""
    ref rp = b.column(col(b, "repo"))
    ref ac = b.column(col(b, "actor"))
    ref ev = b.column(col(b, "events"))
    ref st = b.column(col(b, "stars"))
    ref fk = b.column(col(b, "forks"))
    ref rl = b.column(col(b, "releases"))
    ref io = b.column(col(b, "issues_opened"))
    ref po = b.column(col(b, "prs_opened"))
    ref ps = b.column(col(b, "pushes"))
    for r in range(b.num_rows):
        var repo = str_at(rp, r)
        if repo not in repos:
            continue
        if repo not in accs:
            accs[repo] = Acc(repo, day)
        ref a = accs[repo]
        a.row.events += i64_at(ev, r)
        a.row.stars += i64_at(st, r)
        a.row.forks += i64_at(fk, r)
        a.row.releases += i64_at(rl, r)
        a.row.issues_opened += i64_at(io, r)
        a.row.prs_opened += i64_at(po, r)
        a.row.pushes += i64_at(ps, r)
        var actor = str_at(ac, r)
        if actor.byte_length() > 0:
            a.actors[actor] = True


def encode_job(
    day: String, hours: Int64, releases: Int64, repos: List[String]
) -> String:
    """A day's task argument: the day, the snapshots of `gharchive.repo_hour`
    and `gharchive.releases`, the repositories. One string, a line each, which
    `day_activity` takes apart again. A negative snapshot means the table has
    none."""
    var s = String(day, "\n", hours, "\n", releases)
    for r in repos:
        s += "\n"
        s += r
    return s^


def _in_filter(column: String, repos: Dict[String, Bool]) -> String:
    """An `["in", column, [...]]` row filter of the repositories, in
    iceberg's JSON filter syntax."""
    var s = String('["in","', column, '",[')
    var first = True
    for e in repos.items():
        if not first:
            s += ","
        first = False
        s += json_quote(e.key)
    s += "]]"
    return s^


def day_activity(job: String) raises -> DayActivity:
    """Counts one day's activity and releases for a list of repositories on a
    worker.
    It reads `gharchive.repo_hour` and `gharchive.releases` (at the step's
    pinned snapshots) for the repositories in `job` (`encode_job`)."""
    var t0 = perf_counter_ns()
    var lines = job.split("\n")
    var day = String(lines[0])
    var hours_snapshot = Int64(Int(lines[1]))
    var releases_snapshot = Int64(Int(lines[2]))
    var repos = Dict[String, Bool]()
    for i in range(3, len(lines)):
        repos[String(lines[i])] = True
    var d = days_of(day)
    var accs = Dict[String, Acc]()
    var releases = List[ReleaseRow]()
    var scanned = 0
    # The day's time range with `@` for the column, since the two tables
    # name it differently (`hour` in repo_hour, `created_at` in releases).
    var within = String(
        '["and",[">=","', "@", '","', day, 'T00:00:00Z"],',
        '["<","', "@", '","', day_text(d + 1), 'T00:00:00Z"]]',
    )
    try:
        # On a worker there is no `Ctx`: the table is loaded by dataset name
        # and read at the snapshot the step pinned. `repo_hour` is partitioned
        # by day and sorted by repository, so the day and `in` filters let
        # the scan read only the few row groups where these repositories are,
        # not the ~100K rows an hour of every repository.
        var hours = load_dataset(REPO_HOUR)
        var by_repo = _in_filter("repo", repos)
        var filter = String(
            '["and",', within.replace("@", "hour"), ",", by_repo, "]"
        )
        var reader = (
            hours.scan()
            .use_snapshot(hours_snapshot)
            .filter(filter)
            .select([
                "repo", "actor", "events", "stars", "forks", "releases",
                "issues_opened", "prs_opened", "pushes",
            ])
            .to_batch_reader()
        )
        while True:
            var next = reader.next_batch()
            if not next:
                break
            var b = next.take()
            scanned += b.num_rows
            fold_hours(b, d, repos, accs)
        # The same day and repository filter on the releases, unless the
        # table has no snapshot yet.
        if releases_snapshot >= 0:
            var rels = load_dataset(GH_RELEASES)
            var rfilter = String(
                '["and",', within.replace("@", "created_at"), ",", by_repo, "]"
            )
            var rreader = (
                rels.scan()
                .use_snapshot(releases_snapshot)
                .filter(rfilter)
                .select([
                    "repo", "actor", "tag", "name", "published_at",
                    "prerelease",
                ])
                .to_batch_reader()
            )
            while True:
                var next = rreader.next_batch()
                if not next:
                    break
                var b = next.take()
                for r in range(b.num_rows):
                    var repo = str_at(b.column(col(b, "repo")), r)
                    if repo not in repos:
                        continue
                    releases.append(
                        ReleaseRow(
                            repo,
                            d,
                            str_at(b.column(col(b, "tag")), r),
                            str_at(b.column(col(b, "name")), r),
                            i64_at(b.column(col(b, "published_at")), r),
                            bool_at(b.column(col(b, "prerelease")), r),
                            str_at(b.column(col(b, "actor")), r),
                        )
                    )
    except e:
        raise Error(day, ": reading ", REPO_HOUR, ": ", e)
    # `Seq` is dista's sendable list, so the results can cross to the step.
    var rows = Seq[ActivityRow]()
    for ref r in finish(accs^):
        rows.append(r.copy())
    var rels = Seq[ReleaseRow]()
    for ref r in releases:
        rels.append(r.copy())
    return DayActivity(
        d, rows^, rels^, scanned, Int(perf_counter_ns() - t0) // 1_000_000
    )


# ── rows to and from the tables ─────────────────────────────────────────────


def activity_rows(b: RecordBatch) raises -> List[ActivityRow]:
    """The rows of a scanned `mojo.activity` batch (`day` is a `date`)."""
    var out = List[ActivityRow]()
    var c = List[Int]()
    for name in [
        "repo", "day", "events", "stars", "forks", "releases",
        "issues_opened", "prs_opened", "pushes", "actors",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            ActivityRow(
                str_at(b.column(c[0]), r),
                i32_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                i64_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                i64_at(b.column(c[5]), r),
                i64_at(b.column(c[6]), r),
                i64_at(b.column(c[7]), r),
                i64_at(b.column(c[8]), r),
                i64_at(b.column(c[9]), r),
            )
        )
    return out^


def activity_batch(rows: List[ActivityRow]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.activity`."""
    var b = BatchBuilder(activity_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_int(cs[1], r.day)
        b.add_int(cs[2], r.events)
        b.add_int(cs[3], r.stars)
        b.add_int(cs[4], r.forks)
        b.add_int(cs[5], r.releases)
        b.add_int(cs[6], r.issues_opened)
        b.add_int(cs[7], r.prs_opened)
        b.add_int(cs[8], r.pushes)
        b.add_int(cs[9], r.actors)
    return b^.build()


def release_rows(b: RecordBatch) raises -> List[ReleaseRow]:
    """The rows of a scanned `mojo.releases` batch."""
    var out = List[ReleaseRow]()
    var c = List[Int]()
    for name in ["repo", "day", "tag", "name", "published_at", "prerelease", "actor"]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            ReleaseRow(
                str_at(b.column(c[0]), r),
                i32_at(b.column(c[1]), r),
                str_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                bool_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
            )
        )
    return out^


def releases_batch(rows: List[ReleaseRow]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.releases`."""
    var b = BatchBuilder(releases_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_int(cs[1], r.day)
        b.add_str(cs[2], r.tag)
        add_str_or_null(b, cs[3], r.name)
        add_ts_or_null(b, cs[4], r.published_at)
        b.add_bool(cs[5], r.prerelease)
        add_str_or_null(b, cs[6], r.actor)
    return b^.build()
