"""Which repositories mojo_refresh reads again, and its record of them.

A repository is due when the default-branch head mojo_live last saw
(`mojo.live_heads`) isn't the head its rows were read for:

- with a row in `mojo.refreshed`, the `head` of its last good read;
- without one (read only by mojo_history, mojo_retool or mojo_versions),
  the newest commit `mojo.commits` has for it and the `head_sha` of its
  `mojo.repo_versions` row: due unless both are the live head.

A repository mojo_history hasn't read (no commits) is left to it, one with
no live head (empty, gone, or not polled yet) has nothing to compare, and
one over `MOJO_HISTORY_MAX_KB` is skipped as mojo_history skips it. A due
repository also waits since its last try: `min_hours` after a good read
(`big_hours` for one over `big_kb`, modular/modular), and after a failed one
`retry_hours` doubling with each failure in a row, up to `max_retry_hours`,
so a repository that can't be read is tried less and less often, not every
run. The due ones go longest stale first (the oldest last good read, or
for one without a row the date of its newest commit), by name on a tie,
and a run takes the first `max_repos`.

Times are microseconds since the epoch, as in the tables.
"""

from std.os import getenv

from morca.tables import BatchBuilder
from parquet import RecordBatch

from cols import col, i64_at, str_at
from lake import add_str_or_null, add_ts_or_null, refreshed_schema

comptime HOUR = Int64(3_600_000_000)
"""An hour in microseconds."""
comptime OK = "ok"
comptime FAILED = "failed"


@fieldwise_init
struct Refreshed(Copyable, Movable):
    """A row of `mojo.refreshed`."""

    var repo: String
    var head: String
    """The live head of the last good read; empty if none was good."""
    var read_at: Int64
    """When that read was; 0 if none was good."""
    var tried_at: Int64
    var outcome: String
    """`ok` or `failed`."""
    var failures: Int64
    """Failed tries since the last good one."""
    var error: String


@fieldwise_init
struct Known(Copyable, Movable):
    """What the history tables hold of a repository that has no row in
    `mojo.refreshed`."""

    var commit_head: String
    """The newest commit of `mojo.commits` (highest `seq`)."""
    var commit_at: Int64
    """Its committer time."""
    var version_head: String
    """`head_sha` of its `mojo.repo_versions` row; empty if none."""


@fieldwise_init
struct Policy(Copyable, Movable):
    """How many repositories a run reads and how long one waits, from the
    environment (`from_env`) with these defaults."""

    var max_repos: Int
    """MOJO_REFRESH_MAX_REPOS (60): repositories read a run."""
    var min_hours: Int64
    """MOJO_REFRESH_MIN_HOURS (6): after a good read, before the next."""
    var big_kb: Int64
    """MOJO_REFRESH_BIG_KB (1000000, about 1 GB of GitHub's `size`): a
    repository over it waits `big_hours` instead."""
    var big_hours: Int64
    """MOJO_REFRESH_BIG_HOURS (24)."""
    var retry_hours: Int64
    """MOJO_REFRESH_RETRY_HOURS (6): after the first failure, doubled for
    each more in a row."""
    var max_retry_hours: Int64
    """MOJO_REFRESH_MAX_RETRY_HOURS (168): the longest wait after failures."""
    var max_kb: Int64
    """MOJO_HISTORY_MAX_KB (0, no limit): mojo_history's size limit."""

    @staticmethod
    def default() -> Self:
        return Self(60, 6, 1_000_000, 24, 6, 168, 0)

    @staticmethod
    def from_env() raises -> Self:
        var d = Self.default()
        return Self(
            Int(getenv("MOJO_REFRESH_MAX_REPOS", String(d.max_repos))),
            Int64(Int(getenv("MOJO_REFRESH_MIN_HOURS", String(d.min_hours)))),
            Int64(Int(getenv("MOJO_REFRESH_BIG_KB", String(d.big_kb)))),
            Int64(Int(getenv("MOJO_REFRESH_BIG_HOURS", String(d.big_hours)))),
            Int64(Int(getenv("MOJO_REFRESH_RETRY_HOURS", String(d.retry_hours)))),
            Int64(Int(getenv("MOJO_REFRESH_MAX_RETRY_HOURS", String(d.max_retry_hours)))),
            Int64(Int(getenv("MOJO_HISTORY_MAX_KB", "0"))),
        )


@fieldwise_init
struct Due(Copyable, Movable):
    """A repository to read again, for the live head `head`."""

    var repo: String
    var head: String
    var since: Int64
    """Its last good read (or newest commit): the order's key."""


@fieldwise_init
struct Selection(Movable):
    """The repositories a run reads, and why the others aren't read."""

    var due: List[Due]
    """In order, at most `max_repos`."""
    var waiting: Int
    """Due but not read: over `max_repos`, for a later run."""
    var current: Int
    """Read for their live head already."""
    var resting: Int
    """Moved, but their last try was too recent (`min_hours`, `big_hours`)."""
    var backing_off: Int
    """Moved, but their last try failed too recently."""
    var unread: Int
    """No commits yet: mojo_history's."""
    var no_head: Int
    """No live head to compare with."""
    var too_big: Int
    """Over `MOJO_HISTORY_MAX_KB`."""


def wait_hours(r: Refreshed, size_kb: Int64, p: Policy) -> Int64:
    """How long after `r.tried_at` the repository may be tried again."""
    if r.outcome != OK and r.failures > 0:
        var h = p.retry_hours
        var n = Int64(1)
        while n < r.failures and h < p.max_retry_hours:
            h *= 2
            n += 1
        return min(h, p.max_retry_hours)
    if p.big_kb > 0 and size_kb > p.big_kb:
        return p.big_hours
    return p.min_hours


def select_due(
    repos: List[String],
    sizes: Dict[String, Int64],
    heads: Dict[String, String],
    records: Dict[String, Refreshed],
    known: Dict[String, Known],
    now: Int64,
    p: Policy,
) raises -> Selection:
    """The repositories of `repos` to read again at `now`, longest stale
    first, at most `p.max_repos` (see the module's docstring). `known` has
    the repositories with commits; `heads` the live heads."""
    var all = List[Due]()
    var out = Selection(List[Due](), 0, 0, 0, 0, 0, 0, 0)
    var seen = Dict[String, Bool]()
    for ref repo in repos:
        if repo in seen:
            continue
        seen[repo] = True
        var size = sizes.get(repo, Int64(0))
        if p.max_kb > 0 and size > p.max_kb:
            out.too_big += 1
            continue
        var head = heads.get(repo, String())
        if head.byte_length() == 0:
            out.no_head += 1
            continue
        if repo not in known:
            out.unread += 1
            continue
        if repo in records:
            ref r = records[repo]
            if r.head == head:
                out.current += 1
                continue
            if now < r.tried_at + wait_hours(r, size, p) * HOUR:
                if r.outcome == OK:
                    out.resting += 1
                else:
                    out.backing_off += 1
                continue
            all.append(Due(repo, head, r.read_at))
            continue
        ref k = known[repo]
        if k.commit_head == head and k.version_head == head:
            out.current += 1
            continue
        all.append(Due(repo, head, k.commit_at))

    var order = List[Int](capacity=len(all))
    for i in range(len(all)):
        order.append(i)

    def before(x: Int, y: Int) {imm all} -> Bool:
        if all[x].since != all[y].since:
            return all[x].since < all[y].since
        return all[x].repo < all[y].repo

    sort[stable=True](Span(order), before)
    for i in order:
        if len(out.due) < p.max_repos:
            out.due.append(all[i].copy())
        else:
            out.waiting += 1
    return out^


def after_try(
    old: Optional[Refreshed], due: Due, now: Int64, error: String
) -> Refreshed:
    """The new row of a repository tried at `now` for `due.head`: `ok` when
    `error` is empty, else `failed`, keeping the last good read's head."""
    if error.byte_length() == 0:
        return Refreshed(due.repo, due.head, now, now, OK, 0, String())
    if old:
        ref o = old.value()
        return Refreshed(due.repo, o.head, o.read_at, now, FAILED, o.failures + 1, error)
    return Refreshed(due.repo, String(), 0, now, FAILED, 1, error)


def refreshed_rows(b: RecordBatch) raises -> List[Refreshed]:
    """The rows of a scanned `mojo.refreshed` batch."""
    var out = List[Refreshed]()
    var c = List[Int]()
    for name in ["repo", "head", "read_at", "tried_at", "outcome", "failures", "error"]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            Refreshed(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                i64_at(b.column(c[3]), r),
                str_at(b.column(c[4]), r),
                i64_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
            )
        )
    return out^


def refreshed_batch(rows: List[Refreshed]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.refreshed`."""
    var b = BatchBuilder(refreshed_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        add_str_or_null(b, cs[1], r.head)
        add_ts_or_null(b, cs[2], r.read_at)
        b.add_int(cs[3], r.tried_at)
        b.add_str(cs[4], r.outcome)
        b.add_int(cs[5], r.failures)
        add_str_or_null(b, cs[6], r.error)
    return b^.build()
