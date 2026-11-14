"""Finding Mojo repositories in GH Archive events, and checking them.

GH Archive's push events carry commit messages, not file lists, so finding
Mojo repositories takes two passes. `scan_event` looks at one event for
cheap signs (the repository's name, the `language` of repository objects
that pull-request and fork payloads embed, commit messages naming `.mojo`
or `.🔥` files or a `mojoproject.toml`); `verify` asks GitHub about each
candidate: its `language`, its `pixi.toml` or `mojoproject.toml` naming a
Mojo package, and for a push, whether the pushed commit touched `.mojo`
files.

GH Archive's recent hours carry no push or create events and pull
requests without their repositories' `language` (a few thousand events an
hour in 2026-11, against 150,000 with 114,000 pushes in 2025-06), so a
repository whose name doesn't say "mojo" and that nobody forks is never a
candidate from the events: magmalake/flare_mlake and json_mlake weren't.
`search_candidates` adds the repositories GitHub's search gives for
`language:Mojo` created on a day (and, for a recent day, pushed since),
whatever their name.
"""

from std.time import sleep

from fetch import Reply, github, raw_file
from morca.civil import now
from jscan import Range, each, field, path, text, timestamp_micros
from versions import names_mojo


@fieldwise_init
struct Candidate(Copyable, Movable):
    """A repository that may be a Mojo one, with why it looks like it. Found
    by `scan_event` while an hour's events are parsed, stored in
    `gharchive.candidates` (one row per signal), and confirmed or dropped by
    `verify` in mojo_repos."""

    var repo: String
    var signals: String
    """Comma-separated: `language`, `search`, `push`, `manifest`,
    `description`, `name`."""
    var first_seen: Int64
    var sha: String
    """A pushed commit that may touch `.mojo` files, for `verify`."""

    def add(mut self, signal: String):
        """Adds `signal` unless it is there already, keeping the order the
        signals were noticed in."""
        for s in self.signals.split(","):
            if s == signal:
                return
        if self.signals.byte_length() > 0:
            self.signals += ","
        self.signals += signal

    def has(self, signal: String) -> Bool:
        """Whether `signal` is one of the signals."""
        for s in self.signals.split(","):
            if s == signal:
                return True
        return False

    def rank(self) -> Int:
        """Lower is checked first: the strongest signs, and the cheapest.
        mojo_repos checks in this order because its GitHub budget may run out
        before the list does."""
        if self.has("language") or self.has("search"):
            return 0
        if self.has("push"):
            return 1
        if self.has("manifest"):
            return 2
        if self.has("description"):
            return 3
        return 4


@always_inline
def _lower(c: UInt8) -> UInt8:
    """ASCII lowercase of one byte."""
    if c >= 65 and c <= 90:
        return c + 32
    return c


def contains_ci(b: Span[UInt8, _], s: Int, e: Int, needle: StringSlice) -> Bool:
    """Whether `b[s:e]` contains `needle` (lowercase ASCII), ignoring case."""
    # Events are scanned as raw bytes, with no JSON parse or allocation, since
    # this runs on every event of the day; the fields are
    # only parsed (`jscan`) for the few payloads that pass a cheap substring
    # test.
    var nb = needle.as_bytes()
    var m = len(nb)
    if m == 0:
        return True
    var first = nb[0]
    var i = s
    while i + m <= e:
        if _lower(b[i]) == first:
            var hit = True
            for k in range(1, m):
                if _lower(b[i + k]) != nb[k]:
                    hit = False
                    break
            if hit:
                return True
        i += 1
    return False


def _word(c: UInt8) -> Bool:
    """Whether `c` can be part of a file's name (letters, digits, `_`, `-`)."""
    return (
        (c >= 48 and c <= 57)
        or (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or c == UInt8(ord("_"))
        or c == UInt8(ord("-"))
    )


def names_mojo_file(b: Span[UInt8, _], s: Int, e: Int) -> Bool:
    """Whether the text names a file ending in `.mojo` or `.🔥`: a word
    character, the extension, then not a letter (so `foo.mojo` and
    `foo.🔥`, but not `x.mojom` or `maven.mojo.plugin`)."""
    var i = s + 1
    while i + 5 <= e:
        if b[i] == UInt8(ord(".")) and _word(b[i - 1]):
            # ".mojo"
            if (
                i + 5 <= e
                and _lower(b[i + 1]) == UInt8(ord("m"))
                and _lower(b[i + 2]) == UInt8(ord("o"))
                and _lower(b[i + 3]) == UInt8(ord("j"))
                and _lower(b[i + 4]) == UInt8(ord("o"))
                and (i + 5 == e or not _word(b[i + 5]))
                and (i + 5 == e or b[i + 5] != UInt8(ord(".")))
            ):
                return True
            # ".🔥" is F0 9F 94 A5 in UTF-8; JSON may also escape it.
            if (
                i + 5 <= e
                and b[i + 1] == 0xF0
                and b[i + 2] == 0x9F
                and b[i + 3] == 0x94
                and b[i + 4] == 0xA5
            ):
                return True
        i += 1
    return False


def note(
    mut found: Dict[String, Candidate],
    repo: String,
    signal: String,
    at: Int64,
    sha: String = "",
) raises:
    """Records that `repo` showed `signal` at time `at` (microseconds): a new
    candidate, or a new signal on an existing one, with the earliest `at` as
    its `first_seen` and the first `sha` seen. Names that aren't `owner/name`
    are ignored. Also the merge `hourindex.candidates_from` uses to rebuild
    a day's candidates from the table's rows."""
    if repo.byte_length() == 0 or "/" not in repo:
        return
    if repo in found:
        ref c = found[repo]
        c.add(signal)
        if at < c.first_seen:
            c.first_seen = at
        if sha.byte_length() > 0 and c.sha.byte_length() == 0:
            c.sha = sha
    else:
        found[repo] = Candidate(repo, signal, at, sha)


def scan_event(
    mut found: Dict[String, Candidate],
    type: String,
    repo: String,
    at: Int64,
    payload: Span[UInt8, _],
) raises:
    """Adds the candidates one event points at to `found`. `payload` is the
    event's JSON; `repo` and `type` come from the columns of the event."""
    var rb = repo.as_bytes()
    if contains_ci(rb, 0, len(rb), "mojo"):
        note(found, repo, "name", at)
    var n = len(payload)
    if n == 0:
        return
    var all = Range(0, n)
    # Repository objects with a language: pull requests' base and head
    # repositories, a fork's new repository. This is the strongest signal
    # (GitHub itself says the language is Mojo), and the cheap substring test
    # above the parse keeps the parse for the rare payload that has it. The
    # base/head repositories can differ from the event's `repo`, so they are
    # noted under their own `full_name`.
    if contains_ci(payload, 0, n, '"language":"mojo"'):
        if type.startswith("PullRequest"):
            for side in ["base", "head"]:
                var r = path(payload, field(payload, all, "pull_request"), side, "repo")
                if text(payload, field(payload, r, "language")) == "Mojo":
                    note(found, text(payload, field(payload, r, "full_name")), "language", at)
        elif type == "ForkEvent":
            var f = field(payload, all, "forkee")
            if text(payload, field(payload, f, "language")) == "Mojo":
                note(found, text(payload, field(payload, f, "full_name")), "language", at)
            note(found, repo, "language", at)
        else:
            note(found, repo, "language", at)
    # A push event carries commit messages but not file lists, so a message
    # that names a `.mojo` file is only a hint: `verify` later asks GitHub
    # whether the commit (`sha`) really touched Mojo files.
    if type == "PushEvent":
        if not contains_ci(payload, 0, n, ".mojo") and not contains_ci(
            payload, 0, n, "🔥"
        ) and not contains_ci(payload, 0, n, "mojoproject"):
            return
        for c in each(payload, field(payload, all, "commits")):
            var msg = field(payload, c, "message")
            if not msg.found():
                continue
            if names_mojo_file(payload, msg.start, msg.end):
                note(found, repo, "push", at, text(payload, field(payload, c, "sha")))
            if contains_ci(payload, msg.start, msg.end, "mojoproject.toml"):
                note(found, repo, "manifest", at)
    elif type == "CreateEvent":
        var d = field(payload, all, "description")
        if d.found() and contains_ci(payload, d.start, d.end, "mojo"):
            note(found, repo, "description", at)


@fieldwise_init
struct RepoInfo(Copyable, Movable):
    """The fields of `mojo.repos` that come from `GET /repos/{owner}/{repo}`."""

    var repo: String
    var created_at: Int64
    var stars: Int64
    var forks: Int64
    var license: String
    var default_branch: String
    var description: String
    var size_kb: Int64
    var language: String
    var fork: Bool
    var topics: List[String]
    var id: Int64
    """GitHub's repository id, which a rename or transfer keeps."""


def topics_of(b: Span[UInt8, _], obj: Range) -> List[String]:
    """The `topics` array of a repository object."""
    var out = List[String]()
    for t in each(b, field(b, obj, "topics")):
        var s = text(b, t)
        if s.byte_length() > 0:
            out.append(s^)
    return out^


def long_of(s: String) -> Int64:
    """The number at the start of `s` (0 if there is none): GitHub's counts
    are read out of the scanner as text."""
    var v = Int64(0)
    for c in s.as_bytes():
        if c < 48 or c > 57:
            break
        v = v * 10 + Int64(c - 48)
    return v


def parse_repo(body: String) -> RepoInfo:
    """The fields of mojo.repos from a `GET /repos/{owner}/{repo}` reply."""
    var b = body.as_bytes()
    var all = Range(0, len(b))
    var lic = field(b, all, "license")
    # `spdx_id` is "NOASSERTION" for licenses GitHub can't classify; the
    # license's name is more informative than that.
    var license = text(b, field(b, lic, "spdx_id"))
    if license.byte_length() == 0 or license == "NOASSERTION":
        var name = text(b, field(b, lic, "name"))
        if name.byte_length() > 0:
            license = name
    return RepoInfo(
        text(b, field(b, all, "full_name")),
        timestamp_micros(b, field(b, all, "created_at")),
        long_of(text(b, field(b, all, "stargazers_count"))),
        long_of(text(b, field(b, all, "forks_count"))),
        license,
        text(b, field(b, all, "default_branch")),
        text(b, field(b, all, "description")),
        long_of(text(b, field(b, all, "size"))),
        text(b, field(b, all, "language")),
        text(b, field(b, all, "fork")) == "true",
        topics_of(b, all),
        long_of(text(b, field(b, all, "id"))),
    )


@fieldwise_init
struct ForkInfo(Copyable, Movable):
    """Whether a repository is a fork, and of what, from a `GET
    /repos/{owner}/{repo}` reply."""

    var repo: String
    """GitHub's `full_name`."""
    var fork: Bool
    var parent: String
    """The repository it was forked from (`parent.full_name`), or ""."""
    var source: String
    """The root of its fork network (`source.full_name`): the same as
    `parent` for a fork of a repository that isn't one."""


def parse_fork(body: String) -> ForkInfo:
    """The fork fields of a `GET /repos/{owner}/{repo}` reply."""
    var b = body.as_bytes()
    var all = Range(0, len(b))
    return ForkInfo(
        text(b, field(b, all, "full_name")),
        text(b, field(b, all, "fork")) == "true",
        text(b, field(b, field(b, all, "parent"), "full_name")),
        text(b, field(b, field(b, all, "source"), "full_name")),
    )


@fieldwise_init
struct Verdict(Copyable, Movable):
    var outcome: String
    """`mojo`, `not mojo`, `fork`, `gone`, or `limited` (try again later)."""
    var how: String
    """For `mojo`: the check that settled it, e.g. `language`."""
    var info: RepoInfo
    var remaining: Int


def _commit_touches_mojo(repo: String, sha: String, mut remaining: Int) raises -> Bool:
    """Whether commit `sha` changed a `.mojo` or `.🔥` file, from the API's
    file list for it. `remaining` is updated from the reply's rate limit."""
    var r = github(String("/repos/", repo, "/commits/", sha))
    remaining = r.remaining
    if r.status != 200:
        return False
    var b = r.body.as_bytes()
    for f in each(b, field(b, Range(0, len(b)), "files")):
        var name = text(b, field(b, f, "filename"))
        if name.endswith(".mojo") or name.endswith(".🔥"):
            return True
    return False


def verify(c: Candidate) raises -> Verdict:
    """Asks GitHub whether `c` is a Mojo repository. The checks go from
    cheapest to dearest: the repository itself (one API call), its manifests
    (raw files, which GitHub doesn't count against the API limit), and the
    pushed commit (a second API call, made only if budget is left)."""
    var empty = RepoInfo(c.repo, 0, 0, 0, "", "", "", 0, "", False, List[String](), 0)
    var r = github(String("/repos/", c.repo))
    # GitHub answers 403 or 429 when the rate limit is used up: not a verdict
    # on the repository, so the caller stops and tries it again later.
    if r.status == 403 or r.status == 429:
        return Verdict("limited", "", empty^, r.remaining)
    # Any other status, 404 for a deleted repository among them, settles it
    # as `gone`.
    if r.status != 200:
        return Verdict("gone", String("HTTP ", r.status), empty^, r.remaining)
    var info = parse_repo(r.body)
    var remaining = r.remaining
    if info.fork:
        # Forks of modular/mojo are most "Mojo" repositories in the events;
        # they aren't libraries.
        return Verdict("fork", "", info^, remaining)
    if info.language == "Mojo":
        return Verdict("mojo", "language", info^, remaining)
    # A repository GitHub doesn't call Mojo may still be a Mojo project: its
    # manifest names a Mojo package.
    for f in ["pixi.toml", "mojoproject.toml"]:
        var manifest = raw_file(info.repo, info.default_branch, f)
        if names_mojo(manifest):
            return Verdict("mojo", String("manifest ", f), info^, remaining)
    if c.sha.byte_length() > 0 and remaining != 0:
        if _commit_touches_mojo(info.repo, c.sha, remaining):
            return Verdict("mojo", "push", info^, remaining)
    return Verdict("not mojo", "", info^, remaining)


comptime SEARCH_PAGES = 10
"""GitHub's search gives at most 1,000 results a query: 10 pages of 100."""


def search_queries(day: String, recent: Bool) -> List[String]:
    """The `q=` values (URL-encoded) for a day's search: the Mojo
    repositories created that day, and for a recent day (a daily run) those
    pushed on it or since, which finds an active repository found before
    neither way. Forks are left out by GitHub's search."""
    var out: List[String] = [String("language:Mojo+created:", day)]
    if recent:
        out.append(String("language:Mojo+pushed:%3E%3D", day))
    return out^


def parse_search(body: String) -> Tuple[Int, List[Candidate]]:
    """GitHub's `GET /search/repositories` reply: `total_count`, and a
    `search` candidate per item, first seen when it was last pushed."""
    var b = body.as_bytes()
    var all = Range(0, len(b))
    var out = List[Candidate]()
    for item in each(b, field(b, all, "items")):
        var name = text(b, field(b, item, "full_name"))
        if name.byte_length() == 0 or text(b, field(b, item, "fork")) == "true":
            continue
        out.append(Candidate(name, "search", timestamp_micros(b, field(b, item, "pushed_at")), ""))
    return (Int(long_of(text(b, field(b, all, "total_count")))), out^)


def _search_wait(r: Reply, attempt: Int) raises -> Int:
    """Seconds to wait out the search API's rate limit (30 requests a
    minute with a token, 10 without): `Retry-After`, else until
    `X-RateLimit-Reset`, else 20 s more each attempt; at most 90."""
    if r.retry_after >= 0:
        return min(max(r.retry_after, 1), 90)
    if r.reset > 0:
        return min(max(r.reset - Int(now()) + 1, 1), 90)
    return 20 * (attempt + 1)


def search_candidates(day: String, recent: Bool) raises -> Tuple[List[Candidate], String]:
    """The repositories GitHub's search says are Mojo ones for `day`
    (`search_queries`), and a note on an answer it couldn't use ("" for
    none). A rate limit is waited out (a backfill runs a day after another);
    one that lasts over three waits raises, failing the run rather than
    skipping the day's search silently."""
    var out = List[Candidate]()
    for ref q in search_queries(day, recent):
        for page in range(1, SEARCH_PAGES + 1):
            var path = String("/search/repositories?q=", q, "&per_page=100&page=", page)
            var r = github(path)
            var attempt = 0
            while (r.status == 403 or r.status == 429) and attempt < 3:
                sleep(Float64(_search_wait(r, attempt)))
                attempt += 1
                r = github(path)
            if r.status == 403 or r.status == 429:
                raise Error("GitHub search ", q, ": still rate limited (HTTP ", r.status, ")")
            if r.status != 200:
                return (out^, String("search ", q, " page ", page, ": HTTP ", r.status))
            var got = parse_search(r.body)
            var n = len(got[1])
            out.extend(got[1].copy())
            if n < 100 or page * 100 >= got[0]:
                break
    return (out^, String())
