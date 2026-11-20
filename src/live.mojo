"""The live poller's GitHub side (#123): which census repos' default branches
moved since the last look, and the commits that moved them.

One GraphQL query asks for the heads of `HEADS_BATCH` repositories at once
(`heads_query`; 1 rate-limit point, a few seconds), so a look at every census
repo is about 26 queries. A repo whose head moved is asked for its latest
`HISTORY_N` commits with their subjects (`history_query`), and the commits
newer than the head seen before are the new ones (`new_since`). A repo seen
for the first time only records its head: its history is mojo_history's.
"""

from jscan import Range, each, field, text, timestamp_micros
from retry import backoff_ms, nap_ms, retryable_status

comptime HEADS_BATCH = 50
"""Repos a heads query asks for. 100 timed out on GitHub's side (502) on prod
(#158); a batch that fails is split further (mojo_live's `ask_heads`)."""
comptime HEADS_MIN_SPLIT = 10
"""A failing batch this small isn't split again: it is skipped this poll."""
comptime HEADS_TRIES = 2
"""Attempts at one batch before it is split."""
comptime HISTORY_N = 30
"""Commits asked for per moved repo; a push of more is cut to these."""


def _json_string(s: String) -> String:
    """`s` as a JSON string literal."""
    var out = String('"')
    for cp in s.codepoint_slices():
        if cp == '"':
            out += '\\"'
        elif cp == "\\":
            out += "\\\\"
        elif cp == "\n":
            out += "\\n"
        else:
            out += cp
    out += '"'
    return out^


def _owner_name(repo: String) -> Tuple[String, String]:
    var slash = repo.find("/").or_else(-1)
    if slash < 0:
        return (repo, String())
    return (String(repo[byte=:slash]), String(repo[byte = slash + 1 :]))


def _gql_string(s: String) -> String:
    """`s` as a GraphQL string literal (repo names are `[A-Za-z0-9._-]`, but
    nothing here relies on it)."""
    return _json_string(s)


def heads_query(repos: List[String]) -> String:
    """The request body asking for the default-branch head of each of `repos`
    (aliases `r0`, `r1`, ...), and the query's cost."""
    var q = String("query{rateLimit{cost remaining}")
    for i in range(len(repos)):
        var on = _owner_name(repos[i])
        q.write(
            "r", i, ":repository(owner:", _gql_string(on[0]), ",name:",
            _gql_string(on[1]), "){defaultBranchRef{target{oid}}}",
        )
    q += "}"
    return String('{"query":', _json_string(q), "}")


def history_query(repo: String, n: Int = HISTORY_N) -> String:
    """The request body asking for the latest `n` commits of `repo`'s default
    branch: sha, subject and committer time."""
    var on = _owner_name(repo)
    var q = String(
        "query{rateLimit{cost remaining}repository(owner:", _gql_string(on[0]),
        ",name:", _gql_string(on[1]), "){defaultBranchRef{target{... on Commit{",
        "history(first:", n, "){nodes{oid messageHeadline committedDate}}}}}}}",
    )
    return String('{"query":', _json_string(q), "}")


@fieldwise_init
struct Heads(Movable):
    var heads: Dict[String, String]
    """repo -> head sha, for the repos that have one (a repo gone or empty
    has none)."""
    var cost: Int
    var remaining: Int


def parse_heads(body: String, repos: List[String]) -> Heads:
    """The heads in a reply to `heads_query(repos)`. A repo GitHub couldn't
    resolve (renamed, gone, private) comes back null and is left out."""
    var out = Dict[String, String]()
    var b = body.as_bytes()
    var all = Range(0, len(b))
    var data = field(b, all, "data")
    var rl = field(b, data, "rateLimit")
    var cost = _int(text(b, field(b, rl, "cost")))
    var remaining = _int(text(b, field(b, rl, "remaining")))
    for i in range(len(repos)):
        var r = field(b, data, String("r", i))
        if not r.found():
            continue
        var oid = text(b, field(b, field(b, field(b, r, "defaultBranchRef"), "target"), "oid"))
        if oid.byte_length() > 0:
            out[repos[i]] = oid^
    return Heads(out^, cost, remaining)


def _int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return -1


@fieldwise_init
struct LiveCommit(Copyable, Movable):
    var repo: String
    var sha: String
    var subject: String
    var committed_at: Int64
    """Microseconds since the epoch, the committer's time."""
    var seen_at: Int64
    """When the poller first saw it."""


def parse_history(repo: String, body: String, seen_at: Int64) -> List[LiveCommit]:
    """The commits in a reply to `history_query(repo)`, newest first."""
    var out = List[LiveCommit]()
    var b = body.as_bytes()
    var all = Range(0, len(b))
    var target = field(b, field(b, field(b, field(b, all, "data"), "repository"), "defaultBranchRef"), "target")
    for c in each(b, field(b, field(b, target, "history"), "nodes")):
        out.append(LiveCommit(
            repo,
            text(b, field(b, c, "oid")),
            text(b, field(b, c, "messageHeadline")),
            timestamp_micros(b, field(b, c, "committedDate")),
            seen_at,
        ))
    return out^


def new_since(history: List[LiveCommit], known: String) -> Tuple[List[LiveCommit], Bool]:
    """The commits of `history` (newest first) newer than `known`, oldest
    first, and whether `known` was among them. When it wasn't (a push of more
    than `HISTORY_N` commits, or a force push), all of `history` is new."""
    var out = List[LiveCommit]()
    var found = False
    for ref c in history:
        if c.sha == known:
            found = True
            break
        out.append(c.copy())
    out.reverse()
    return (out^, found)


@fieldwise_init
struct Freshness(Copyable, Movable):
    """Seconds from a commit to the poller seeing it, over some commits."""

    var n: Int
    var median_s: Int
    var p90_s: Int


def freshness(commits: List[LiveCommit], since: Int64) -> Freshness:
    """Seen-minus-committed over the commits seen at `since` or later. The
    committer's time comes before the push (a commit can be pushed days
    later), so a lag over a day is left out: that commit was old when
    pushed, not slow to arrive."""
    var lags = List[Int]()
    for ref c in commits:
        if c.seen_at < since:
            continue
        var lag = Int((c.seen_at - c.committed_at) // 1_000_000)
        if lag >= 0 and lag <= 86_400:
            lags.append(lag)
    if len(lags) == 0:
        return Freshness(0, 0, 0)
    sort(lags)
    var n = len(lags)
    return Freshness(n, lags[(n - 1) // 2], lags[min(n - 1, (n * 9) // 10)])


struct Asked(Movable):
    """What the heads queries of one poll got."""
    var heads: Dict[String, String]
    var cost: Int
    var remaining: Int
    var skipped: Int
    """Repos whose batch failed even when split: left as they were."""
    var failed_in_a_row: Int
    var last_error: String

    def __init__(out self):
        self.heads = Dict[String, String]()
        self.cost = 0
        self.remaining = -1
        self.skipped = 0
        self.failed_in_a_row = 0
        self.last_error = String()


comptime GIVE_UP_AFTER = 12
"""Failed heads requests in a row after which a poll stops: GitHub is down,
not one batch too big. Splitting a batch of 50 down to one that small fails
at most 8 times in a row (two tries at 50, 25, 12 and 6)."""


def ask_heads[
    fetch: def(String) raises thin -> Tuple[Int, String]
](repos: List[String], mut got: Asked, pause: Bool = True) raises:
    """The heads of `repos` into `got`. A 5xx, a timeout or a request that
    fails is tried again after a pause; if it still fails, the batch is
    split in halves (GitHub answers a big query with 502 when it takes too
    long), down to `HEADS_MIN_SPLIT` repos, and a batch that small that
    still fails is skipped. Any other status (401, 403) raises. `fetch`
    POSTs a query and returns its status and body."""
    for attempt in range(HEADS_TRIES):
        if attempt > 0 and pause:
            nap_ms(backoff_ms(attempt - 1))
        var status = 0
        var body: String
        try:
            var r = fetch(heads_query(repos))
            status = r[0]
            body = r[1]
        except e:
            body = String()
            got.last_error = String(e)
        if status == 200:
            var h = parse_heads(body, repos)
            for e in h.heads.items():
                got.heads[e.key] = e.value
            got.cost += max(h.cost, 0)
            got.remaining = h.remaining
            got.failed_in_a_row = 0
            return
        if status != 0:
            got.last_error = String(
                "HTTP ", status, ": ", String(body[byte = : min(200, body.byte_length())])
            )
            if not retryable_status(status):
                raise Error("GraphQL heads: ", got.last_error)
        got.failed_in_a_row += 1
        if got.failed_in_a_row >= GIVE_UP_AFTER:
            raise Error(
                "GraphQL heads: ", got.failed_in_a_row, " requests in a row failed, the last: ",
                got.last_error,
            )
    if len(repos) > HEADS_MIN_SPLIT:
        var mid = len(repos) // 2
        var a = List[String]()
        var b = List[String]()
        for i in range(len(repos)):
            if i < mid:
                a.append(repos[i])
            else:
                b.append(repos[i])
        ask_heads[fetch](a, got, pause)
        ask_heads[fetch](b, got, pause)
        return
    got.skipped += len(repos)
