"""Contributors of a repository: the distinct people who authored or
co-authored its commits, by month.

`read_authors` runs one `git log` over every commit reachable from HEAD
(merged branches too, not only the first-parent history mojo.commits has)
and keeps, per month and person, how many commits they wrote: the author's
and each `Co-authored-by:` trailer's. A person is a hash of their email
(`author_id`), so mojo.contributors holds no email or name; bots
(`is_bot`) are left out. `contributor_counts` turns a repository's rows
into the numbers the console shows: distinct contributors in total, and
per month the active and the new ones.
"""

from morca.tables import BatchBuilder
from objectstore.crypto import sha256_hex
from parquet import RecordBatch

from cols import col, i32_at, i64_at, str_at
from command import git
from days import day_text, days_of
from lake import contributors_schema, try_load


comptime AUTHOR_FORMAT = (
    "%x1e%at%x1f%aN%x1f%aE%x1f"
    "%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1d)"
)
"""A commit in the authors' `git log`: a record separator, then the author
time, name and email (`%aN`/`%aE` follow the repository's `.mailmap`) and
its co-author trailers, unit-separated. git matches the trailer key without
regard to case."""

comptime ID_HEX = 16
"""Hex digits of the sha256 an `author_id` keeps (64 bits)."""


@fieldwise_init
struct AuthorMonth(Copyable, Movable):
    """One person's commits to a repository in one month, a row of
    `mojo.contributors`."""

    var repo: String
    var month: Int64
    """The first day of the month (days since 1970-01-01), by author time."""
    var author: String
    """`author_id`: a hash of the email, never the email."""
    var commits: Int64
    """Commits they authored or co-authored that month."""


def normalize_email(email: StringSlice) -> String:
    """`email` trimmed and lowercased, and a GitHub noreply address
    (`123+login@users.noreply.github.com`) without its numeric id, so the
    old and new forms of the same address are one person."""
    var e = String(email.strip()).lower()
    comptime NOREPLY = "@users.noreply.github.com"
    if e.endswith(NOREPLY):
        var plus = e.find("+")
        if plus > 0:
            var digits = True
            for c in e.as_bytes()[:plus]:
                if c < 48 or c > 57:
                    digits = False
            if digits:
                var rest = String(e[byte = plus + 1 :])
                e = rest^
    return e^


def author_id(name: StringSlice, email: StringSlice) -> String:
    """The first `ID_HEX` hex digits of the sha256 of the normalized email
    (of the lowercased name when there is no email): stable across runs
    and repositories, and not the email itself."""
    var e = normalize_email(email)
    var key = String("email:", e) if e.byte_length() > 0 else String(
        "name:", String(name.strip()).lower()
    )
    var h = sha256_hex(key)
    return String(h[byte=:ID_HEX])


def is_bot(name: StringSlice, email: StringSlice) -> Bool:
    """Whether a commit's author or co-author is a bot: a name ending in
    `[bot]` (`dependabot[bot]`, `github-actions[bot]`), an email of one
    (`...[bot]@users.noreply.github.com`), or the names dependabot and
    github-actions go by without the suffix."""
    var n = String(name.strip()).lower()
    var e = String(email.strip()).lower()
    if n.endswith("[bot]") or "[bot]@" in e:
        return True
    return n.startswith("dependabot") or n.startswith("github-actions")


def parse_coauthor(value: StringSlice) -> Tuple[String, String]:
    """A `Co-authored-by:` value, `Name <email>`, as (name, email); a value
    without `<...>` is all name."""
    var v = String(value.strip())
    var lt = v.find("<")
    var gt = v.rfind(">")
    if lt < 0 or gt < lt:
        return (v^, String())
    return (String(v[byte=:lt].strip()), String(v[byte = lt + 1 : gt].strip()))


def month_start(at_seconds: Int64) raises -> Int64:
    """The first day of the month (days since 1970-01-01) of a time in
    seconds since the epoch."""
    var day = at_seconds // 86_400
    if at_seconds < 0 and at_seconds % 86_400 != 0:
        day -= 1
    return days_of(String(day_text(day)[byte=:7], "-01"))


def parse_author_log(repo: String, log: String) raises -> List[AuthorMonth]:
    """`git log --format=AUTHOR_FORMAT` output as one row per (month,
    person), sorted by month then person. A person co-authoring a commit
    they also authored counts once for it; bots and records without a time
    are skipped."""
    var at = Dict[String, Int]()  # month|id -> index in rows
    var rows = List[AuthorMonth]()
    for rec in log.split("\x1e"):
        var f = String(rec).strip().split("\x1f")
        if len(f) < 3:
            continue
        var secs: Int64
        try:
            secs = Int64(Int(String(f[0]).strip()))
        except:
            continue
        var month = month_start(secs)
        var people = List[Tuple[String, String]]()
        people.append((String(f[1]), String(f[2])))
        if len(f) > 3:
            for v in f[3].split("\x1d"):
                if v.strip().byte_length() > 0:
                    people.append(parse_coauthor(v))
        var seen = Dict[String, Bool]()
        for ref p in people:
            if is_bot(p[0], p[1]):
                continue
            if p[0].strip().byte_length() == 0 and p[1].strip().byte_length() == 0:
                continue
            var id = author_id(p[0], p[1])
            if id in seen:
                continue
            seen[id] = True
            var key = String(month, "|", id)
            if key in at:
                rows[at[key]].commits += 1
            else:
                at[key] = len(rows)
                rows.append(AuthorMonth(repo, month, id, 1))
    sort_author_months(rows)
    return rows^


def sort_author_months(mut rows: List[AuthorMonth]):
    """By month, then person: the same rows always come out in one order."""
    var order = List[Int](capacity=len(rows))
    for i in range(len(rows)):
        order.append(i)

    def before(x: Int, y: Int) {imm rows} -> Bool:
        if rows[x].month != rows[y].month:
            return rows[x].month < rows[y].month
        return rows[x].author < rows[y].author

    sort[stable=True](Span(order), before)
    var out = List[AuthorMonth](capacity=len(rows))
    for i in order:
        out.append(rows[i].copy())
    rows = out^


def read_authors(repo: String, dir: String) raises -> List[AuthorMonth]:
    """The contributors of the clone in `dir`, every commit reachable from
    HEAD. Needs commit objects only, so a clone without file contents does
    (a `.mailmap` is then fetched if there is one)."""
    var r = git(["-C", dir, "log", "--use-mailmap", String("--format=", AUTHOR_FORMAT), "HEAD"])
    if r[0] != 0:
        raise Error("git log of the authors failed: ", r[1].strip())
    return parse_author_log(repo, r[1])


@fieldwise_init
struct ContributorMonth(Copyable, Movable):
    var month: String
    """`YYYY-MM`."""
    var active: Int
    """Distinct people with a commit that month."""
    var new: Int
    """Of them, the ones with no commit in an earlier month."""


@fieldwise_init
struct RepoContributors(Copyable, Movable):
    var total: Int
    """Distinct people over the whole history."""
    var months: List[ContributorMonth]
    """Only the months with a commit, oldest first."""

    @staticmethod
    def empty() -> Self:
        return Self(0, List[ContributorMonth]())


def contributor_counts(rows: List[AuthorMonth]) -> RepoContributors:
    """One repository's rows (any order) as its distinct contributors in
    total and per month, and the new ones per month."""
    var sorted = rows.copy()
    sort_author_months(sorted)
    var first_seen = Dict[String, Bool]()
    var out = RepoContributors.empty()
    var i = 0
    while i < len(sorted):
        var m = sorted[i].month
        var active = 0
        var new = 0
        var seen = Dict[String, Bool]()
        while i < len(sorted) and sorted[i].month == m:
            ref a = sorted[i].author
            if a not in seen:
                seen[a] = True
                active += 1
                if a not in first_seen:
                    first_seen[a] = True
                    new += 1
            i += 1
        out.months.append(ContributorMonth(String(day_text(m)[byte=:7]), active, new))
    out.total = len(first_seen)
    return out^


def counts_by_repo(rows: List[AuthorMonth]) raises -> Dict[String, RepoContributors]:
    """`contributor_counts` of each repository in `rows`."""
    var by = Dict[String, List[AuthorMonth]]()
    for ref r in rows:
        if r.repo not in by:
            by[r.repo] = List[AuthorMonth]()
        by[r.repo].append(r.copy())
    var out = Dict[String, RepoContributors]()
    for e in by.items():
        out[e.key] = contributor_counts(e.value)
    return out^


def contributor_rows(b: RecordBatch) raises -> List[AuthorMonth]:
    """The rows of a scanned `mojo.contributors` batch."""
    var out = List[AuthorMonth]()
    var c_repo = col(b, "repo")
    var c_month = col(b, "month")
    var c_author = col(b, "author")
    var c_commits = col(b, "commits")
    for r in range(b.num_rows):
        out.append(
            AuthorMonth(
                str_at(b.column(c_repo), r),
                i32_at(b.column(c_month), r),
                str_at(b.column(c_author), r),
                i64_at(b.column(c_commits), r),
            )
        )
    return out^


def contributors_batch(rows: List[AuthorMonth]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.contributors`."""
    var b = BatchBuilder(contributors_schema())
    var repo = b.col("repo")
    var month = b.col("month")
    var author = b.col("author")
    var commits = b.col("commits")
    for ref r in rows:
        b.add_str(repo, r.repo)
        b.add_int(month, r.month)
        b.add_str(author, r.author)
        b.add_int(commits, r.commits)
    return b^.build()


def read_contributors() raises -> Dict[String, RepoContributors]:
    """`counts_by_repo` of mojo.contributors' current snapshot; empty when
    the table doesn't exist yet."""
    var rows = List[AuthorMonth]()
    var t = try_load("mojo", "contributors")
    if t and t.value().metadata.has_current_snapshot:
        for b in t.value().scan().to_batches():
            for ref r in contributor_rows(b):
                rows.append(r.copy())
    return counts_by_repo(rows)
