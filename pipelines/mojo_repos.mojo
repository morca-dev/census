"""Finds new Mojo repositories among each day's GH Archive candidates by asking
GitHub, and adds them to mojo.repos.

A sensor: each day gharchive commits starts a run for that day. The step
reads the day's rows of `gharchive.candidates` (which gharchive's hour tasks
wrote with `detect.scan_event` while they parsed the events), asks
GitHub about the ones it hasn't asked about before (`detect.verify`), and
appends the Mojo ones to `mojo.repos` and every answer to `mojo.checked`.
A repository already in mojo.repos, read again just before the append, is
never appended again, nor is one GitHub gives the id of a row of it
(`repo_id`): a renamed or transferred repository's events come under its
new name (#181). Rows from before ids were recorded have none, so such a
repository can be added again under its new name; mojo_stats records the
same id for both, and the console shows them as one (`names.mojo`).
mojo.repo_stats isn't read here: mojo_stats reads mojo.repos, and a read
of what it writes would be a cycle, which morca refuses to register.
mojo_history is keyed on `mojo.repos`' `repo` column, so each snapshot of
it starts mojo_history for the repositories it adds.

GH Archive's recent hours lack the events that named most candidates, so
each run also asks GitHub's search for the `language:Mojo` repositories
created that day (and, within a week of today, pushed since), whatever their
name (`detect.search_candidates`), and checks them with the rest.

GitHub allows 60 API requests an hour without a token, so a run checks at
most `MOJO_REPOS_BUDGET` candidates (default 25, or 1000 with
`GITHUB_TOKEN`), strongest signs first, and stops early when the rate limit
runs out. The rest go into `mojo.checked` as `unchecked`, and every later
run checks those first, whatever day it is for.
"""

from std.os import getenv, setenv

from morca import Ctx, Daily, Day, Mapped, Pipeline, Step, morca_main
from morca.civil import now
from morca.tables import BatchBuilder, append, ensure_table, scan, table
from parquet import RecordBatch

from cols import col, i64_at, str_at, str_range
from detect import Candidate, RepoInfo, Verdict, note, search_candidates, verify
from hourindex import candidates_from
from days import days_of
from jscan import days_from_civil
from names import NameRow, Names, names_from
from lake import (
    CHECKED,
    CANDIDATES,
    REPOS,
    add_str_or_null,
    add_strs,
    checked_schema,
    repos_schema,
)


def _known(mut ctx: Ctx, dataset: String) raises -> Dict[String, Bool]:
    """The `repo` values already in one of this step's own tables."""
    # Read at the table's *current* snapshot, not a pinned one: it has to
    # include what runs of earlier days (possibly just now) committed, or two
    # days could both add the same repository.
    var out = Dict[String, Bool]()
    var t = table(ctx, dataset)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in t.scan().select(["repo"]).to_batches():
        ref a = b.column(0)
        for r in range(b.num_rows):
            out[str_at(a, r)] = True
    return out^


def _names(mut ctx: Ctx, known: Dict[String, Bool]) raises -> Names:
    """The repositories of mojo.repos with the GitHub ids its rows have (since
    #181), so a candidate under a repository's new name isn't added again."""
    var keys = List[String]()
    for k in known.keys():
        keys.append(k)
    var rows = List[NameRow]()
    var t = table(ctx, REPOS)
    if t.metadata.has_current_snapshot and t.metadata.schema().has_field(15):
        for b in t.scan().select(["repo", "repo_id"]).to_batches():
            for r in range(b.num_rows):
                var id = i64_at(b.column(1), r)
                if id > 0:
                    # An answered row of no day: it joins by id and names
                    # the repository by its key.
                    rows.append(NameRow(str_at(b.column(0), r), -1, "ok", "", id))
    return names_from(keys, rows)


@fieldwise_init
struct _Asked(Copyable, Movable):
    """The latest thing `mojo.checked` says about a repository."""

    var at: Int64
    var pending: Bool
    """The latest answer is `unchecked`: no API budget was left for it."""
    var candidate: Candidate


def _asked(mut ctx: Ctx) raises -> Dict[String, _Asked]:
    """The latest row of mojo.checked for each repository. The table is an
    append-only log of answers (a repository can be `unchecked` on one day and
    `mojo` on a later one), so the newest `checked_at` wins. The row keeps
    the candidate's signals, first_seen and sha, which is all a later run
    needs to check a repository that waited, without its day's events."""
    var out = Dict[String, _Asked]()
    var t = table(ctx, CHECKED)
    if not t.metadata.has_current_snapshot:
        return out^
    for b in t.scan().to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "checked_at")
        var c_out = col(b, "outcome")
        var c_sig = col(b, "signals")
        var c_first = col(b, "first_seen")
        var c_sha = col(b, "sha")
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r)
            var at = i64_at(b.column(c_at), r)
            if repo in out and out[repo].at > at:
                continue
            out[repo] = _Asked(
                at,
                str_at(b.column(c_out), r) == "unchecked",
                Candidate(
                    repo,
                    str_at(b.column(c_sig), r),
                    i64_at(b.column(c_first), r),
                    str_at(b.column(c_sha), r),
                ),
            )
    return out^


def _now_micros() raises -> Int64:
    """The current time in microseconds since the epoch."""
    return now() * 1_000_000


def _day_candidates(mut ctx: Ctx, d: Day) raises -> Dict[String, Candidate]:
    """The day's candidates from `gharchive.candidates`, merged the way
    `detect.scan_event` merged them over the day's events: signals added in
    the order they were noticed, the earliest `first_seen`, the first
    `sha`."""
    # The table is partitioned by day on `hour`, so the range filter lets the
    # scan skip every other day's files. `scan` is morca's: pinned to the
    # snapshot this step first saw, so a retry sees the same candidates.
    var lo = Int64(days_from_civil(d.year, d.month, d.day)) * 86_400_000_000
    var hi = lo + 86_400_000_000
    var cands = table(ctx, CANDIDATES)
    var filter = String(
        '["and",[">=","hour",', lo, '],["<","hour",', hi, "]]"
    )
    return candidates_from(
        scan(ctx, cands)
        .filter(filter)
        .select(["repo", "reason", "first_seen", "sha"])
        .to_batches()
    )



@fieldwise_init
struct _Found(Copyable, Movable):
    """A candidate GitHub says is a Mojo repository."""

    var info: RepoInfo
    var candidate: Candidate
    var how: String


def _repos_batch(found: List[_Found], known: Dict[String, Bool]) raises -> Tuple[RecordBatch, Int]:
    """The rows of mojo.repos for the repositories of `found` that aren't in
    `known` (each once), and how many there are."""
    var b = BatchBuilder(repos_schema())
    var c_repo = b.col("repo")
    var c_created = b.col("created_at")
    var c_first = b.col("first_seen")
    var c_found = b.col("found_by")
    var c_stars = b.col("stars")
    var c_forks = b.col("forks")
    var c_license = b.col("license")
    var c_branch = b.col("default_branch")
    var c_desc = b.col("description")
    var c_size = b.col("size_kb")
    var c_lang = b.col("language")
    var c_fork = b.col("fork")
    var c_topics = b.col("topics")
    var c_topic = b.col("topics.element")
    var c_id = b.col("repo_id")
    var n = 0
    var taken = Dict[String, Bool]()
    for ref f in found:
        ref info = f.info
        if info.repo in known or info.repo in taken:
            continue
        taken[info.repo] = True
        b.add_str(c_repo, info.repo)
        b.add_int(c_created, info.created_at)
        b.add_int(c_first, f.candidate.first_seen)
        b.add_str(c_found, String(f.candidate.signals, " / ", f.how))
        b.add_int(c_stars, info.stars)
        b.add_int(c_forks, info.forks)
        add_str_or_null(b, c_license, info.license)
        add_str_or_null(b, c_branch, info.default_branch)
        add_str_or_null(b, c_desc, info.description)
        b.add_int(c_size, info.size_kb)
        add_str_or_null(b, c_lang, info.language)
        b.add_bool(c_fork, info.fork)
        add_strs(b, c_topics, c_topic, info.topics)
        if info.id > 0:
            b.add_int(c_id, info.id)
        else:
            b.add_null(c_id)
        n += 1
    return (b^.build(), n)


def find_repos(mut ctx: Ctx, d: Day) raises -> Int:
    """Checks the day's new candidates with GitHub, within the API budget, and
    adds the Mojo ones to mojo.repos.
    Every answer goes to `mojo.checked`. Returns the number of repositories
    added.

    Rerunning a day, or running overlapping days, adds nothing twice: a
    repository already in `mojo.repos`, or already answered, is skipped."""
    var found = _day_candidates(ctx, d)
    ctx.log(String(String(d), ": ", len(found), " candidates"))
    # GH Archive no longer has the events that named most Mojo repositories
    # (`detect.mojo`): GitHub's search for the day's `language:Mojo`
    # repositories adds the ones whose name doesn't say so. A day within a
    # week of today also asks for the ones pushed since.
    var day = String(d)
    var recent = days_of(day) >= Int64(now() // 86_400) - 7
    var searched = search_candidates(day, recent)
    if searched[1].byte_length() > 0:
        ctx.log(String("GitHub search: ", searched[1], "; going on with what it gave"))
    var from_search = 0
    for ref c in searched[0]:
        if c.repo not in found:
            from_search += 1
        note(found, c.repo, "search", c.first_seen)
    ctx.log(String("GitHub search: ", len(searched[0]), " Mojo repositories, ", from_search, " not among the events' candidates"))

    # Leave out what an earlier day already settled: a repository already in
    # mojo.repos, or one GitHub already answered about (`mojo`, `not mojo`,
    # `fork` or `gone`, so each repository is asked about once, ever). Only an
    # `unchecked` answer, which means no budget was left, is asked again.
    var repos_t = ensure_table(ctx, REPOS, repos_schema())
    var checked_t = ensure_table(ctx, CHECKED, checked_schema())
    var known = _known(ctx, REPOS)
    # A repository renamed or transferred since it was found shows up in
    # the events under its new name; GitHub's id (below) says it is one of
    # mojo.repos already.
    var names = _names(ctx, known)
    var asked = _asked(ctx)
    var todo = List[Candidate]()
    for e in found.items():
        if e.key in known:
            continue
        if e.key in asked and not asked[e.key].pending:
            continue
        todo.append(e.value.copy())
    # Candidates an earlier run had no API budget for, from any day. Their
    # signals and sha were kept in mojo.checked, so they are checked without
    # reading the old day's candidates again.
    for e in asked.items():
        if e.value.pending and e.key not in found and e.key not in known:
            todo.append(e.value.candidate.copy())
    # Strongest signs first (`Candidate.rank`), so that when the budget runs
    # out it is the weakest guesses (a repository whose name merely contains
    # "mojo") that wait. An insertion sort: stable, and the list is small.
    for i in range(1, len(todo)):
        var j = i
        while j > 0 and todo[j - 1].rank() > todo[j].rank():
            todo.swap_elements(j - 1, j)
            j -= 1

    # Without a token GitHub allows 60 requests an hour and a check can take
    # more than one (the repository, then a pushed commit), so 25 candidates
    # keep a local run under it; a token allows 5000.
    var budget = Int(getenv("MOJO_REPOS_BUDGET", "1000" if getenv("GITHUB_TOKEN") else "25"))
    var kb = BatchBuilder(checked_schema())
    var k_repo = kb.col("repo")
    var k_at = kb.col("checked_at")
    var k_out = kb.col("outcome")
    var k_sig = kb.col("signals")
    var k_how = kb.col("how")
    var k_first = kb.col("first_seen")
    var k_sha = kb.col("sha")
    var checked_now = _now_micros()
    var asked_n = 0
    var found_mojo = List[_Found]()
    var added_names = Dict[String, Bool]()
    # Once `stopped` (budget used up, or GitHub says limited), the loop keeps
    # going only to write the remaining candidates to mojo.checked as
    # `unchecked`, so that a later run finds them there.
    var stopped = False
    for ref c in todo:
        var outcome = String("unchecked")
        var how = String()
        if not stopped and asked_n >= budget:
            ctx.log(String("budget of ", budget, " checks used; ", len(todo) - asked_n, " candidates wait"))
            stopped = True
        if not stopped:
            # A network failure raises and fails the attempt (`retries=1`); a
            # rate limit is not a failure but a `limited` verdict.
            var v: Verdict
            try:
                v = verify(c)
            except e:
                raise Error(c.repo, ": checking it on GitHub: ", e)
            asked_n += 1
            if v.outcome == "limited":
                # Not counted as an answer: the candidate stays `unchecked`.
                ctx.log(String("GitHub rate limit reached after ", asked_n - 1, " checks"))
                stopped = True
            else:
                outcome = v.outcome
                how = v.how
                ctx.log(String(c.repo, " [", c.signals, "]: ", v.outcome, " ", v.how))
                # `info.repo` is GitHub's own spelling (`full_name`), which
                # can differ from the event's after a rename or in case, so
                # it is checked against `known` again, and against this run's
                # additions.
                # A new name of a repository mojo.repos has (GitHub's id,
                # or a name mojo_stats saw) isn't added again either.
                var have = names.known_as(v.info.repo, v.info.id)
                if v.outcome == "mojo" and have.byte_length() > 0:
                    ctx.log(String(c.repo, ": already in mojo.repos as ", have))
                if v.outcome == "mojo" and have.byte_length() == 0 and v.info.repo not in known and v.info.repo not in added_names:
                    added_names[v.info.repo] = True
                    found_mojo.append(_Found(v.info.copy(), c.copy(), v.how))
                # `remaining` is GitHub's X-RateLimit-Remaining: stop before
                # the next call is refused.
                if v.remaining == 0:
                    ctx.log("GitHub rate limit now 0; the rest wait for a later run")
                    stopped = True
        # A candidate that was already waiting and still is gets no second
        # `unchecked` row, so the log doesn't grow by a row per run per
        # waiting candidate.
        if outcome == "unchecked" and c.repo in asked and asked[c.repo].pending:
            continue  # already waiting
        kb.add_str(k_repo, c.repo)
        kb.add_int(k_at, checked_now)
        kb.add_str(k_out, outcome)
        kb.add_str(k_sig, c.signals)
        add_str_or_null(kb, k_how, how)
        kb.add_int(k_first, c.first_seen)
        add_str_or_null(kb, k_sha, c.sha)
    var added = 0
    if len(found_mojo) > 0:
        # The checks can take many minutes, and other runs (another day's,
        # or another scheduler on the same warehouse) may have added some of
        # these since `known` was read: look at mojo.repos again so a repo
        # is never in it twice.
        var now_known = _known(ctx, REPOS)
        var batch = _repos_batch(found_mojo, now_known)
        added = batch[1]
        if added < len(found_mojo):
            ctx.log(String(len(found_mojo) - added, " found repositories were added to mojo.repos meanwhile; left out"))
        # This snapshot of mojo.repos is what starts mojo_history's and
        # mojo_versions' runs, for the repositories it adds.
        if added > 0:
            var id = append(ctx, repos_t, [batch[0].copy()])
            ctx.log(String(added, " Mojo repositories added, snapshot ", id))
    if kb.rows() > 0:
        _ = append(ctx, checked_t, [kb^.build()])
    return added


# `Mapped` runs the step once per partition of a run, here a `Day`. Reads and
# writes are declared so `morca.tables` can enforce them and the UI can draw
# the lineage: CANDIDATES is only read (the sensor's dataset), and the two
# tables are written. `retries=1` re-runs a failed attempt once in the run.
comptime FindRepos = Step[
    "find_repos",
    Day,
    Int,
    find_repos,
    Mapped,
    retries=1,
    reads=[CANDIDATES],
    writes=[REPOS, CHECKED],
]
# `sensor=True`: no schedule; the scheduler starts a run when gharchive (or
# gharchive_index) commits a snapshot of `gharchive.candidates`, for the days
# that snapshot holds. Left at `max_runs=1`, days are checked one at a time,
# which the `known`/`asked` reads above rely on.
comptime MojoRepos = Pipeline[
    "mojo_repos",
    FindRepos,
    partitions=Daily["2023-01-01"],
    sensor=True,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoRepos]()
