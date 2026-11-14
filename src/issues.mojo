"""A repository's issues and pull requests from GitHub, for `mojo.issues`.

`parse_issues` reads a page of `GET /repos/{owner}/{repo}/issues` (which
lists pull requests too, marked by a `pull_request` field); `issues_of`
asks for every page updated since a time, oldest first, waiting out rate
limits as mojo_stats does (`stats.limited`, `stats.wait_seconds`).
"""

from std.time import sleep

from morca.tables import BatchBuilder
from parquet import RecordBatch

from cols import col, i64_at, str_at, strs_at
from detect import long_of
from fetch import github
from jscan import Range, each, field, micros_to_iso, text, timestamp_micros
from lake import (
    add_str_or_null,
    add_strs,
    add_ts_or_null,
    issues_schema,
    try_load,
)
from morca.civil import now
from overview import BASE_MONTH, DAY_US, Overview, month_of_days
from stats import limited, state_of, wait_seconds


comptime PER_PAGE = 100
comptime TITLE_MAX = 300
"""Bytes of a title kept; GitHub allows 256 characters."""


@fieldwise_init
struct IssueRow(Copyable, Movable):
    var repo: String
    var number: Int64
    var kind: String
    """`issue` or `pr`."""
    var state: String
    """`open` or `closed`."""
    var title: String
    var labels: List[String]
    var author: String
    var comments: Int64
    var created_at: Int64
    """Microseconds since the epoch; 0 for none (closed_at, merged_at)."""
    var updated_at: Int64
    var closed_at: Int64
    var merged_at: Int64
    var fetched_at: Int64


def _cut(s: String, n: Int) -> String:
    """`s` to at most `n` bytes, on a codepoint boundary."""
    if s.byte_length() <= n:
        return s
    var out = String()
    for cp in s.codepoint_slices():
        if out.byte_length() + cp.byte_length() > n:
            break
        out += cp
    return out^


def parse_issues(repo: String, body: String, fetched_at: Int64) -> List[IssueRow]:
    """The rows of one page of GitHub's issues list for `repo`."""
    var out = List[IssueRow]()
    var b = body.as_bytes()
    for it in each(b, Range(0, len(b))):
        var pr = field(b, it, "pull_request")
        # A pull request has a `pull_request` object; an issue has none.
        var is_pr = pr.found() and pr.end > pr.start and b[pr.start] == UInt8(ord("{"))
        var labels = List[String]()
        for l in each(b, field(b, it, "labels")):
            var name = text(b, field(b, l, "name"))
            if name.byte_length() > 0:
                labels.append(name^)
        out.append(
            IssueRow(
                repo,
                long_of(text(b, field(b, it, "number"))),
                String("pr") if is_pr else String("issue"),
                text(b, field(b, it, "state")),
                _cut(text(b, field(b, it, "title")), TITLE_MAX),
                labels^,
                text(b, field(b, field(b, it, "user"), "login")),
                long_of(text(b, field(b, it, "comments"))),
                timestamp_micros(b, field(b, it, "created_at")),
                timestamp_micros(b, field(b, it, "updated_at")),
                timestamp_micros(b, field(b, it, "closed_at")),
                timestamp_micros(b, field(b, pr, "merged_at")) if is_pr else Int64(0),
                fetched_at,
            )
        )
    return out^


@fieldwise_init
struct Fetched(Movable):
    """What `issues_of` found: the rows, `ok` or the state of a reply that
    wasn't (`gone`, `blocked`, `error HTTP n`), the requests made, the
    seconds waited on the rate limit, and what was left of it."""

    var rows: List[IssueRow]
    var state: String
    var calls: Int
    var waited_s: Int
    var remaining: Int


def issues_of(repo: String, since: Int64, max_wait_s: Int, max_pages: Int) raises -> Fetched:
    """Every issue and pull request of `repo` updated at `since` or later
    (microseconds; 0 for all), oldest update first, in at most `max_pages`
    pages. Waits out rate limits for at most `max_wait_s` seconds in all
    and raises when that isn't enough."""
    var rows = List[IssueRow]()
    var calls = 0
    var waited = 0
    var remaining = -1
    var page = 1
    var attempt = 0
    var q = String("?state=all&sort=updated&direction=asc&per_page=", PER_PAGE)
    if since > 0:
        q += String("&since=", micros_to_iso(since))
    while page <= max_pages:
        var r = github(String("/repos/", repo, "/issues", q, "&page=", page))
        calls += 1
        remaining = r.remaining
        if limited(r):
            var w = wait_seconds(r, Int(now()), attempt)
            if waited + w > max_wait_s:
                raise Error(
                    repo, ": GitHub's rate limit (HTTP ", r.status,
                    ") would take ", w, " s more after ", waited, " s",
                )
            sleep(Float64(w))
            waited += w
            attempt += 1
            continue
        if r.status >= 500 and attempt < 3:
            sleep(Float64(5 * (attempt + 1)))
            waited += 5 * (attempt + 1)
            attempt += 1
            continue
        if r.status != 200:
            # Issues turned off is a 410; a repo that is gone a 404.
            return Fetched(rows^, state_of(r.status), calls, waited, remaining)
        attempt = 0
        var got = parse_issues(repo, r.body, now() * 1_000_000)
        var n = len(got)
        for ref x in got:
            rows.append(x.copy())
        if n < PER_PAGE:
            break
        page += 1
    return Fetched(rows^, String("ok"), calls, waited, remaining)


def issue_rows(b: RecordBatch) raises -> List[IssueRow]:
    """The rows of a scanned `mojo.issues` batch."""
    var c = List[Int]()
    for name in [
        "repo", "number", "kind", "state", "title", "labels", "author",
        "comments", "created_at", "updated_at", "closed_at", "merged_at",
        "fetched_at",
    ]:
        c.append(col(b, name))
    var out = List[IssueRow]()
    for r in range(b.num_rows):
        out.append(
            IssueRow(
                str_at(b.column(c[0]), r),
                i64_at(b.column(c[1]), r),
                str_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r),
                str_at(b.column(c[4]), r),
                strs_at(b, c[5], r),
                str_at(b.column(c[6]), r),
                i64_at(b.column(c[7]), r),
                i64_at(b.column(c[8]), r),
                i64_at(b.column(c[9]), r),
                i64_at(b.column(c[10]), r),
                i64_at(b.column(c[11]), r),
                i64_at(b.column(c[12]), r),
            )
        )
    return out^


def issues_batch(rows: List[IssueRow]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.issues`."""
    var b = BatchBuilder(issues_schema())
    var cs = b.roots.copy()  # repo ... fetched_at, the labels at 5
    var label = b.col("labels.element")
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_int(cs[1], r.number)
        b.add_str(cs[2], r.kind)
        b.add_str(cs[3], r.state)
        b.add_str(cs[4], r.title)
        add_strs(b, cs[5], label, r.labels)
        add_str_or_null(b, cs[6], r.author)
        b.add_int(cs[7], r.comments)
        b.add_int(cs[8], r.created_at)
        b.add_int(cs[9], r.updated_at)
        add_ts_or_null(b, cs[10], r.closed_at)
        add_ts_or_null(b, cs[11], r.merged_at)
        b.add_int(cs[12], r.fetched_at)
    return b^.build()


def merge_issues(var old: List[IssueRow], new: List[IssueRow]) -> List[IssueRow]:
    """`old` with each row of `new` in place of the row of the same repo and
    number (or added)."""
    var at = Dict[String, Int]()
    for i in range(len(old)):
        at[String(old[i].repo, "#", old[i].number)] = i
    for ref r in new:
        var k = String(r.repo, "#", r.number)
        var i = at.get(k, -1)
        if i >= 0:
            old[i] = r.copy()
        else:
            at[k] = len(old)
            old.append(r.copy())
    return old^


comptime ISSUES_SHOWN = 10
"""How many open issues and pull requests a repo's page lists."""


struct RepoIssues(Copyable, Movable):
    """What a repo's page shows of mojo.issues: the counts, its most recently
    updated open issues and its newest pull requests."""

    var open_issues: Int
    var closed_issues: Int
    var open_prs: Int
    var merged_prs: Int
    var closed_prs: Int
    """Closed without being merged."""
    var issues: List[IssueRow]
    """Open, most recently updated first, at most `ISSUES_SHOWN`."""
    var prs: List[IssueRow]
    """Newest first (by created_at), at most `ISSUES_SHOWN`."""

    def __init__(out self):
        self.open_issues = 0
        self.closed_issues = 0
        self.open_prs = 0
        self.merged_prs = 0
        self.closed_prs = 0
        self.issues = List[IssueRow]()
        self.prs = List[IssueRow]()

    def total(self) -> Int:
        return self.open_issues + self.closed_issues + self.open_prs + self.merged_prs + self.closed_prs

    def add(mut self, r: IssueRow):
        if r.kind == "pr":
            if r.state == "open":
                self.open_prs += 1
            elif r.merged_at > 0:
                self.merged_prs += 1
            else:
                self.closed_prs += 1
            _top(self.prs, r, r.created_at)
            return
        if r.state != "open":
            self.closed_issues += 1
            return
        self.open_issues += 1
        _top(self.issues, r, r.updated_at)


def _top(mut top: List[IssueRow], r: IssueRow, key: Int64):
    """Keeps `top` the `ISSUES_SHOWN` rows with the largest `key` (created_at
    for pull requests, updated_at for issues), largest first."""
    var pr = r.kind == "pr"
    var i = len(top)
    while i > 0 and (top[i - 1].created_at if pr else top[i - 1].updated_at) < key:
        i -= 1
    if i >= ISSUES_SHOWN:
        return
    top.insert(i, r.copy())
    if len(top) > ISSUES_SHOWN:
        _ = top.pop()


def summarize(rows: List[IssueRow]) -> Dict[String, RepoIssues]:
    var out = Dict[String, RepoIssues]()
    for ref r in rows:
        if r.repo not in out:
            out[r.repo] = RepoIssues()
        try:
            out[r.repo].add(r)
        except:
            pass
    return out^


def read_issue_rows() raises -> List[IssueRow]:
    """mojo.issues' current snapshot; empty when the table doesn't exist
    yet."""
    var rows = List[IssueRow]()
    var t = try_load("mojo", "issues")
    if not t or not t.value().metadata.has_current_snapshot:
        return rows^
    for b in t.value().scan().to_batches():
        for ref r in issue_rows(b):
            rows.append(r.copy())
    return rows^


def read_issues() raises -> Dict[String, RepoIssues]:
    """`summarize` of mojo.issues' current snapshot."""
    return summarize(read_issue_rows())


def add_issue_months(mut ov: Overview, rows: List[IssueRow]):
    """Fills `ov`'s issue curves, one value per month of `ov.months`: issues
    opened and closed, and pull requests opened and merged, in that month.
    An event before the first month counts in it; one after the last isn't
    counted."""
    var n = len(ov.months)
    ov.issues_opened = List[Int64](length=n, fill=0)
    ov.issues_closed = List[Int64](length=n, fill=0)
    ov.prs_opened = List[Int64](length=n, fill=0)
    ov.prs_merged = List[Int64](length=n, fill=0)
    if n == 0:
        return
    var first = _month_index(ov.months[0])
    for ref r in rows:
        var opened = _slot(r.created_at, first, n)
        if r.kind == "pr":
            if opened >= 0:
                ov.prs_opened[opened] += 1
            var merged = _slot(r.merged_at, first, n)
            if merged >= 0:
                ov.prs_merged[merged] += 1
        else:
            if opened >= 0:
                ov.issues_opened[opened] += 1
            var closed = _slot(r.closed_at, first, n)
            if closed >= 0:
                ov.issues_closed[closed] += 1


def _month_index(label: String) -> Int:
    """Months since 1970-01 of a `month_label` (`2025-07`)."""
    try:
        var parts = label.split("-")
        return (Int(parts[0]) - 1970) * 12 + Int(parts[1]) - 1
    except:
        return BASE_MONTH


def _slot(at: Int64, first: Int, n: Int) -> Int:
    """The index in the curves of the month of `at` (microseconds since the
    epoch), counting from month `first`; -1 for none (0) or after the last."""
    if at <= 0:
        return -1
    var k = max(month_of_days(Int(at // DAY_US)) - first, 0)
    return k if k < n else -1
