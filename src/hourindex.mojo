"""What gharchive learns from an hour's events while it parses them.

`HourIndex.add` sees every event once and keeps three small summaries, each
written as a table beside `gharchive.events` (same hour task, same snapshot
per hour):

- `gharchive.candidates`: the Mojo candidates `detect.scan_event` finds
  (the rules mojo_repos used to apply to the whole day),
- `gharchive.repo_hour`: counts per (repository, actor, hour) of every
  repository, which is what mojo_activity needs to give a repository found
  later its whole history without reading events again. Only a candidate can
  ever enter `mojo.repos` (`detect.verify` runs on candidates alone), but
  which repository that will be isn't known until a later day, so every
  repository is counted,
- `gharchive.releases`: the published ReleaseEvents.
"""

from std.time import perf_counter_ns

from morca.tables import BatchBuilder
from morca.tables import DataFiles as FileEntries
from morca.tables import FileWriter, Table
from parquet import RecordBatch

from activity import parse_release
from cols import col, i64_at, str_at
from detect import Candidate, note, scan_event
from jscan import Range, field, text
from lake import (
    add_str_or_null,
    add_ts_or_null,
    candidates_schema,
    gh_releases_schema,
    repo_hour_schema,
)

comptime HOUR_MICROS: Int64 = 3_600_000_000
"""An hour in microseconds, the unit of every timestamp in the tables."""


@fieldwise_init
struct Cell(Copyable, Movable):
    """One (repository, actor, hour)'s counts."""

    var repo: String
    var actor: String
    var hour: Int64
    var events: Int64
    var stars: Int64
    var forks: Int64
    var releases: Int64
    var issues_opened: Int64
    var prs_opened: Int64
    var pushes: Int64


@fieldwise_init
struct ReleaseEvent(Copyable, Movable):
    """One published release, as a row of `gharchive.releases`: when the
    event happened (`at`) and when the release was published."""

    var repo: String
    var at: Int64
    var actor: String
    var tag: String
    var name: String
    var published_at: Int64
    var prerelease: Bool


def _action_is(p: Span[UInt8, _], want: StringSlice) -> Bool:
    """Whether the payload's `action` is `want`."""
    return text(p, field(p, Range(0, len(p)), "action")) == want


struct HourIndex(Movable):
    """The three summaries of one hour, filled by `add` as the events are
    parsed and turned into batches by the `*_batch` methods. `at` and
    `cells` together are a hash map with stable positions: `at` finds a
    cell's place by its key and `cells` keeps them in insertion order."""

    var found: Dict[String, Candidate]
    """Candidates by repository, in the order they were first noticed."""
    var at: Dict[String, Int]
    """Key of a cell -> its place in `cells`."""
    var cells: List[Cell]
    var releases: List[ReleaseEvent]
    var events: Int
    var marker: Int64
    """The hour's start, when the batches of an hour with nothing to put in
    a table carry one row for no repository (`repo` is empty) instead: a
    snapshot needs a data file, and one commit per table and hour keeps a
    retry's numbering aligned. Nothing matches that row."""

    def __init__(out self, marker: Int64 = 0):
        """`marker` of 0 writes no marker rows (gharchive's hour tasks, which
        leave a day's empty tables to `write_marker`)."""
        self.marker = marker
        self.found = Dict[String, Candidate]()
        self.at = Dict[String, Int]()
        self.cells = List[Cell]()
        self.releases = List[ReleaseEvent]()
        self.events = 0

    def add(
        mut self,
        type: String,
        repo: String,
        actor: String,
        at: Int64,
        payload: Span[UInt8, _],
    ) raises:
        """Counts one event and notes the candidates it points at."""
        self.events += 1
        scan_event(self.found, type, repo, at, payload)
        var hour = at - at % HOUR_MICROS
        # One cell per (repository, actor, hour), which is the grain of
        # `repo_hour`: keeping the actor lets mojo_activity count distinct
        # actors over a day. The key joins the parts with an ASCII unit
        # separator, which can't occur in a name, and sorts the same way as
        # (repo, actor, hour) in `repo_hour_batch`.
        var key = String(repo, "\x1f", actor, "\x1f", hour)
        var i: Int
        if key in self.at:
            i = self.at[key]
        else:
            i = len(self.cells)
            self.at[key^] = i
            self.cells.append(
                Cell(repo, actor, hour, 0, 0, 0, 0, 0, 0, 0)
            )
        ref c = self.cells[i]
        c.events += 1
        if type == "WatchEvent":
            c.stars += 1
        elif type == "ForkEvent":
            c.forks += 1
        elif type == "PushEvent":
            c.pushes += 1
        # Issues and pull requests count only when opened, as in
        # `activity.add_event` (the two must agree: mojo_activity reads these
        # counts in place of the events).
        elif type == "IssuesEvent":
            if _action_is(payload, "opened"):
                c.issues_opened += 1
        elif type == "PullRequestEvent":
            if _action_is(payload, "opened"):
                c.prs_opened += 1
        elif type == "ReleaseEvent":
            var rel = parse_release(repo, 0, actor, payload)
            if rel:
                var r = rel.take()
                c.releases += 1
                self.releases.append(
                    ReleaseEvent(
                        repo, at, actor, r.tag, r.name, r.published_at,
                        r.prerelease,
                    )
                )

    def candidate_batch(self) raises -> RecordBatch:
        """One row per (repository, hour, reason)."""
        var b = BatchBuilder(candidates_schema())
        var cs = b.roots.copy()
        for e in self.found.items():
            ref c = e.value
            var hour = c.first_seen - c.first_seen % HOUR_MICROS
            for reason in c.signals.split(","):
                b.add_str(cs[0], c.repo)
                b.add_int(cs[1], hour)
                b.add_str(cs[2], String(reason))
                b.add_int(cs[3], c.first_seen)
                add_str_or_null(b, cs[4], c.sha)
        if b.rows() == 0 and self.marker > 0:
            b.add_str(cs[0], "")
            b.add_int(cs[1], self.marker)
            b.add_str(cs[2], "hour")
            b.add_int(cs[3], self.marker)
            b.add_null(cs[4])
        return b^.build()

    def repo_hour_batch(self) raises -> RecordBatch:
        """The cells sorted by (repository, actor, hour)."""
        var keys = List[String]()
        for e in self.at.items():
            keys.append(e.key)
        sort(keys)
        var b = BatchBuilder(repo_hour_schema())
        var cs = b.roots.copy()
        for ref k in keys:
            ref c = self.cells[self.at[k]]
            b.add_str(cs[0], c.repo)
            b.add_int(cs[1], c.hour)
            add_str_or_null(b, cs[2], c.actor)
            b.add_int(cs[3], c.events)
            b.add_int(cs[4], c.stars)
            b.add_int(cs[5], c.forks)
            b.add_int(cs[6], c.releases)
            b.add_int(cs[7], c.issues_opened)
            b.add_int(cs[8], c.prs_opened)
            b.add_int(cs[9], c.pushes)
        if len(keys) == 0 and self.marker > 0:
            b.add_str(cs[0], "")
            b.add_int(cs[1], self.marker)
            b.add_null(cs[2])
            for i in range(3, 10):
                b.add_int(cs[i], 0)
        return b^.build()

    def releases_batch(self) raises -> RecordBatch:
        """One row per published ReleaseEvent, in the order seen."""
        var b = BatchBuilder(gh_releases_schema())
        var cs = b.roots.copy()
        for ref r in self.releases:
            b.add_str(cs[0], r.repo)
            b.add_int(cs[1], r.at)
            add_str_or_null(b, cs[2], r.actor)
            b.add_str(cs[3], r.tag)
            add_str_or_null(b, cs[4], r.name)
            add_ts_or_null(b, cs[5], r.published_at)
            b.add_bool(cs[6], r.prerelease)
        if len(self.releases) == 0 and self.marker > 0:
            b.add_str(cs[0], "")
            b.add_int(cs[1], self.marker)
            b.add_null(cs[2])
            b.add_str(cs[3], "")
            b.add_null(cs[4])
            b.add_null(cs[5])
            b.add_bool(cs[6], False)
        return b^.build()


struct IndexFiles(Copyable, Movable):
    """An hour's index files, written but not committed: a plain struct for
    dista's reflection, the `FileEntries` through their own `Codec`. Also
    the answer of the day-level merge task, which fills only `repo_hour`."""

    var candidates: FileEntries
    var repo_hour: FileEntries
    var releases: FileEntries
    var candidate_rows: Int
    var repo_hour_rows: Int
    var release_rows: Int
    var write_ms: Int

    def __init__(out self):
        self.candidates = FileEntries()
        self.repo_hour = FileEntries()
        self.releases = FileEntries()
        self.candidate_rows = 0
        self.repo_hour_rows = 0
        self.release_rows = 0
        self.write_ms = 0


def _write(table: Table, var batch: RecordBatch) raises -> FileEntries:
    """A batch into a table's data files, uncommitted. An empty batch writes
    no file."""
    var w = FileWriter(table)
    if batch.num_rows > 0:
        w.put(batch^)
    return w^.finish()


def write_index(
    index: HourIndex, candidates: Table, repo_hour: Table, releases: Table
) raises -> IndexFiles:
    """On a worker: the hour's three summaries into their tables."""
    var t0 = perf_counter_ns()
    var out = IndexFiles()
    # The files are written into each table's own `data/` on the worker, and
    # only their entries travel back; the step commits them.
    var cb = index.candidate_batch()
    out.candidate_rows = cb.num_rows
    out.candidates = _write(candidates, cb^)
    var hb = index.repo_hour_batch()
    out.repo_hour_rows = hb.num_rows
    out.repo_hour = _write(repo_hour, hb^)
    var rb = index.releases_batch()
    out.release_rows = rb.num_rows
    out.releases = _write(releases, rb^)
    out.write_ms = Int(perf_counter_ns() - t0) // 1_000_000
    return out^


def write_marker(day_start: Int64, which: Int, table: Table) raises -> FileEntries:
    """A day with nothing at all for a table (`which`: 0 candidates, 1
    repo_hour, 2 releases) commits one file anyway, since a snapshot needs
    one: the marker row of `HourIndex`, for the day's first hour."""
    var index = HourIndex(day_start)
    if which == 0:
        return _write(table, index.candidate_batch())
    if which == 1:
        return _write(table, index.repo_hour_batch())
    return _write(table, index.releases_batch())


def candidates_from(batches: List[RecordBatch]) raises -> Dict[String, Candidate]:
    """Candidates from rows of `gharchive.candidates` (columns repo, reason,
    first_seen, sha), merged the way `detect.scan_event` merges them over a
    day's events: signals added in the order they were noticed, the earliest
    `first_seen`, the first `sha`."""
    # Rows of all the batches are gathered first and then replayed through
    # `note` in event order, which is what makes the result equal to what
    # `scan_event` produced over the original events.
    var repos = List[String]()
    var reasons = List[String]()
    var seen = List[Int64]()
    var shas = List[String]()
    for ref b in batches:
        var c_repo = col(b, "repo")
        var c_reason = col(b, "reason")
        var c_seen = col(b, "first_seen")
        var c_sha = col(b, "sha")
        for r in range(b.num_rows):
            repos.append(str_at(b.column(c_repo), r))
            reasons.append(str_at(b.column(c_reason), r))
            seen.append(i64_at(b.column(c_seen), r))
            shas.append(str_at(b.column(c_sha), r))
    # Event order: by first_seen (ms), then as the rows were read. Each key
    # packs the millisecond into the high bits and the row number (20 bits)
    # into the low ones, so one sort of integers does both.
    var keys = List[Int64]()
    for i in range(len(repos)):
        keys.append(((seen[i] // 1000) << 20) | Int64(i & 0xFFFFF))
    sort(keys)
    var found = Dict[String, Candidate]()
    for k in keys:
        var i = Int(k & 0xFFFFF)
        note(found, repos[i], reasons[i], seen[i], shas[i])
    return found^
