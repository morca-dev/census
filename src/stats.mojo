"""A repository's current numbers from GitHub, for `mojo.repo_stats`.

`parse_stats` reads a `GET /repos/{owner}/{repo}` reply; `stats_of` asks
GitHub, waiting out a rate limit (403/429) by `Retry-After` or
`X-RateLimit-Reset`, and turns a repository that is gone, blocked or
renamed into a state rather than an error.
"""

from std.time import sleep

from detect import long_of, topics_of
from fetch import Reply, github
from jscan import Range, field, text, timestamp_micros
from morca.civil import now


@fieldwise_init
struct StatsRow(Copyable, Movable):
    """One repository's numbers from GitHub on one day: a row of
    `mojo.repo_stats`. For a `state` without numbers (`gone`, `blocked`,
    `error`), the numbers are 0 here and null in the table."""

    var repo: String
    """The name asked about (mojo.repos' `repo`)."""
    var state: String
    """`ok`, `renamed`, `gone`, `blocked` or `error HTTP n`."""
    var stars: Int64
    var forks: Int64
    var open_issues: Int64
    var watchers: Int64
    """`subscribers_count`: who watches it (`watchers_count` is stars)."""
    var topics: List[String]
    var archived: Bool
    var pushed_at: Int64
    var homepage: String
    var license: String
    var description: String
    var size_kb: Int64
    var default_branch: String
    var renamed_to: String
    var repo_id: Int64
    """GitHub's `id`, which a rename or transfer keeps; 0 when unknown."""

    @staticmethod
    def empty(repo: String, state: String) -> Self:
        """A row with only a name and a state."""
        return Self(
            repo, state, 0, 0, 0, 0, List[String](), False, 0, "", "", "", 0,
            "", "", 0,
        )

    def has_numbers(self) -> Bool:
        """Whether GitHub answered with the repository's numbers (a renamed
        repository's reply is the new name's)."""
        return self.state == "ok" or self.state == "renamed"


def parse_stats(repo: String, body: String) -> StatsRow:
    """The row for `repo` from GitHub's reply about it. A reply for another
    name (GitHub followed a rename) is `renamed`, with the new name."""
    var b = body.as_bytes()
    var all = Range(0, len(b))
    var lic = field(b, all, "license")
    var license = text(b, field(b, lic, "spdx_id"))
    # `NOASSERTION` is GitHub's id for a license it can't classify; the name
    # says more.
    if license.byte_length() == 0 or license == "NOASSERTION":
        var name = text(b, field(b, lic, "name"))
        if name.byte_length() > 0:
            license = name
    # A renamed repository's old name redirects: the reply is 200 with the
    # new `full_name`. Names compare without case, which GitHub ignores.
    var full = text(b, field(b, all, "full_name"))
    var state = String("ok")
    var renamed_to = String()
    if full.byte_length() > 0 and full.lower() != repo.lower():
        state = String("renamed")
        renamed_to = full
    return StatsRow(
        repo,
        state,
        long_of(text(b, field(b, all, "stargazers_count"))),
        long_of(text(b, field(b, all, "forks_count"))),
        long_of(text(b, field(b, all, "open_issues_count"))),
        long_of(text(b, field(b, all, "subscribers_count"))),
        topics_of(b, all),
        text(b, field(b, all, "archived")) == "true",
        timestamp_micros(b, field(b, all, "pushed_at")),
        text(b, field(b, all, "homepage")),
        license,
        text(b, field(b, all, "description")),
        long_of(text(b, field(b, all, "size"))),
        text(b, field(b, all, "default_branch")),
        renamed_to,
        long_of(text(b, field(b, all, "id"))),
    )


def state_of(status: Int) -> String:
    """The state of a reply that isn't 200 (and isn't a rate limit): 404 and
    410 are `gone`, 451 (legal reasons) `blocked`."""
    if status == 404 or status == 410:
        return String("gone")
    if status == 451:
        return String("blocked")
    return String("error HTTP ", status)


def limited(r: Reply) -> Bool:
    """Whether a reply is GitHub's rate limit rather than an answer: 429, or
    403 with no requests left or a `Retry-After`. (A 403 can also be a
    refusal for another reason, which is an answer.)"""
    if r.status == 429:
        return True
    return r.status == 403 and (r.remaining == 0 or r.retry_after >= 0)


def wait_seconds(r: Reply, now_s: Int, attempt: Int) -> Int:
    """How long to wait before asking again: `Retry-After`, else until
    `X-RateLimit-Reset` (and a second), else a minute doubling."""
    if r.retry_after >= 0:
        return max(r.retry_after, 1)
    if r.reset > 0:
        return max(r.reset - now_s + 1, 1)
    return 60 * (1 << min(attempt, 4))


@fieldwise_init
struct Asked(Movable):
    """What `stats_of` found: the row, the requests it took (more than one
    after a wait or a 5xx), the seconds it waited, and the rate limit that
    was left after the last reply (-1 if it didn't say)."""

    var row: StatsRow
    var calls: Int
    var waited_s: Int
    var remaining: Int


def stats_of(repo: String, max_wait_s: Int) raises -> Asked:
    """Asks GitHub about `repo`, waiting out rate limits for at most
    `max_wait_s` seconds in all; raises when that isn't enough."""
    var calls = 0
    var waited = 0
    var attempt = 0
    while True:
        var r = github(String("/repos/", repo))
        calls += 1
        # Rate limit: sleep as GitHub says, and ask the same repository
        # again. `waited` counts against `max_wait_s`, which the caller
        # shares among all the repositories of a run.
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
        # A server error is retried a few times with a growing pause (5, 10,
        # 15 s) before it is recorded as `error HTTP n`.
        if r.status >= 500 and attempt < 3:
            sleep(Float64(5 * (attempt + 1)))
            waited += 5 * (attempt + 1)
            attempt += 1
            continue
        if r.status != 200:
            return Asked(StatsRow.empty(repo, state_of(r.status)), calls, waited, r.remaining)
        return Asked(parse_stats(repo, r.body), calls, waited, r.remaining)
