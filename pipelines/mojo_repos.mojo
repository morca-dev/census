"""Finds new Mojo repositories among each day's GH Archive candidates by asking
GitHub, and adds them to mojo.repos.

A sensor: each day gharchive commits starts a run for that day, and so does
mojo_stats's daily commit of `mojo.repo_stats`. The step
reads the day's rows of `gharchive.candidates` (which gharchive's hour tasks
wrote with `detect.scan_event` while they parsed the events), asks
GitHub about the ones it hasn't asked about before (`detect.verify`), and
appends the Mojo ones to `mojo.repos` and every answer to `mojo.checked`.
A repository already in mojo.repos, read again just before the append, is
never appended again, nor is one under a name it had or has now: a
renamed or transferred repository's events come under its new name, which
mojo.repo_stats records with GitHub's id for it (`names.mojo`, #181).
mojo_history is keyed on `mojo.repos`' `repo` column, so each snapshot of
it starts mojo_history for the repositories it adds.

GitHub allows 60 API requests an hour without a token, so a run checks at
most `MOJO_REPOS_BUDGET` candidates (default 25, or 1000 with
`GITHUB_TOKEN`), strongest signs first, and stops early when the rate limit
runs out. The rest go into `mojo.checked` as `unchecked`, and every later
run checks those first, whatever day it is for.
"""

from std.os import getenv, setenv

from iceberg.catalog.filesystem import Table
from iceberg.batch import ColumnBuilder, NestedBuilder, batch_of, batch_of_columns
from iceberg.nested import ColumnTree
from iceberg.values import Datum
from morca import Ctx, Daily, Day, Mapped, Pipeline, Step, morca_main
from morca.civil import now
from morca.tables import append, ensure_table, scan, table
from parquet import RecordBatch

from cols import col, i64_at, str_at, str_range
from detect import Candidate, RepoInfo, Verdict, verify
from hourindex import candidates_from
from jscan import days_from_civil
from names import NameRow, Names, name_columns, name_rows, names_from
from lake import (
    CHECKED,
    CANDIDATES,
    REPOS,
    REPO_STATS,
    checked_schema,
    json_strings,
    repos_schema,
    str_or_null,
    ts,
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
    """The names of the repositories of mojo.repos, old and new, from
    mojo.repo_stats (#181), and the GitHub ids mojo.repos has for them, so a
    candidate under a repository's new name isn't added again."""
    var keys = List[String]()
    for k in known.keys():
        keys.append(k)
    var rows = List[NameRow]()
    var stats: Optional[Table] = None
    try:
        stats = table(ctx, REPO_STATS)
    except e:
        ctx.log(String(REPO_STATS, " not read (", e, "); names as in ", REPOS))
    if stats and stats.value().metadata.has_current_snapshot:
        for b in scan(ctx, stats.value()).select(name_columns(stats.value())).to_batches():
            rows.extend(name_rows(b))
    # The ids of mojo.repos' own rows (since #181), as rows of a day before
    # any of mojo.repo_stats', so they join but don't name.
    var t = table(ctx, REPOS)
    if t.metadata.has_current_snapshot and t.metadata.schema().has_field(15):
        for b in t.scan().select(["repo", "repo_id"]).to_batches():
            for r in range(b.num_rows):
                var id = i64_at(b.column(1), r)
                if id > 0:
                    rows.append(NameRow(str_at(b.column(0), r), -1, "id", "", id))
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
    var rs = repos_schema()
    var c_repo = ColumnBuilder.of(rs, 1)
    var c_created = ColumnBuilder.of(rs, 2)
    var c_first = ColumnBuilder.of(rs, 3)
    var c_found = ColumnBuilder.of(rs, 4)
    var c_stars = ColumnBuilder.of(rs, 5)
    var c_forks = ColumnBuilder.of(rs, 6)
    var c_license = ColumnBuilder.of(rs, 7)
    var c_branch = ColumnBuilder.of(rs, 8)
    var c_desc = ColumnBuilder.of(rs, 9)
    var c_size = ColumnBuilder.of(rs, 10)
    var c_lang = ColumnBuilder.of(rs, 11)
    var c_fork = ColumnBuilder.of(rs, 12)
    var c_topics = NestedBuilder.of(rs, 13)
    var c_id = ColumnBuilder.of(rs, 15)
    var n = 0
    var taken = Dict[String, Bool]()
    for ref f in found:
        ref info = f.info
        if info.repo in known or info.repo in taken:
            continue
        taken[info.repo] = True
        c_repo.add(Datum.string_(info.repo))
        c_created.add(ts(info.created_at))
        c_first.add(ts(f.candidate.first_seen))
        c_found.add(Datum.string_(String(f.candidate.signals, " / ", f.how)))
        c_stars.add(Datum.long_(info.stars))
        c_forks.add(Datum.long_(info.forks))
        c_license.add(str_or_null(info.license))
        c_branch.add(str_or_null(info.default_branch))
        c_desc.add(str_or_null(info.description))
        c_size.add(Datum.long_(info.size_kb))
        c_lang.add(str_or_null(info.language))
        c_fork.add(Datum.bool_(info.fork))
        c_topics.add(json_strings(info.topics))
        c_id.add(Datum.long_(info.id) if info.id > 0 else Datum.none())
        n += 1
    # `topics` is a list column, so this table's batch is built from column
    # trees (`NestedBuilder`), not the flat `batch_of` used for the others.
    var trees = List[ColumnTree]()
    for ref c in [c_repo^, c_created^, c_first^, c_found^, c_stars^, c_forks^, c_license^, c_branch^, c_desc^, c_size^, c_lang^, c_fork^]:
        trees.append(c.build_tree())
    trees.append(c_topics.build())
    trees.append(c_id.build_tree())
    return (batch_of_columns(trees^), n)


def find_repos(mut ctx: Ctx, d: Day) raises -> Int:
    """Checks the day's new candidates with GitHub, within the API budget, and
    adds the Mojo ones to mojo.repos.
    Every answer goes to `mojo.checked`. Returns the number of repositories
    added.

    Rerunning a day, or running overlapping days, adds nothing twice: a
    repository already in `mojo.repos`, or already answered, is skipped."""
    var found = _day_candidates(ctx, d)
    ctx.log(String(String(d), ": ", len(found), " candidates"))

    # Leave out what an earlier day already settled: a repository already in
    # mojo.repos, or one GitHub already answered about (`mojo`, `not mojo`,
    # `fork` or `gone`, so each repository is asked about once, ever). Only an
    # `unchecked` answer, which means no budget was left, is asked again.
    var repos_t = ensure_table(ctx, REPOS, repos_schema())
    var checked_t = ensure_table(ctx, CHECKED, checked_schema())
    var known = _known(ctx, REPOS)
    # A repository renamed or transferred since it was found shows up in
    # the events under its new name: it is one of mojo.repos already.
    var names = _names(ctx, known)
    var asked = _asked(ctx)
    var todo = List[Candidate]()
    for e in found.items():
        if e.key in known or names.knows(e.key):
            continue
        if e.key in asked and not asked[e.key].pending:
            continue
        todo.append(e.value.copy())
    # Candidates an earlier run had no API budget for, from any day. Their
    # signals and sha were kept in mojo.checked, so they are checked without
    # reading the old day's candidates again.
    for e in asked.items():
        if e.value.pending and e.key not in found and e.key not in known and not names.knows(e.key):
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
    var cs = checked_schema()
    var k_repo = ColumnBuilder.of(cs, 1)
    var k_at = ColumnBuilder.of(cs, 2)
    var k_out = ColumnBuilder.of(cs, 3)
    var k_sig = ColumnBuilder.of(cs, 4)
    var k_how = ColumnBuilder.of(cs, 5)
    var k_first = ColumnBuilder.of(cs, 6)
    var k_sha = ColumnBuilder.of(cs, 7)
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
        k_repo.add(Datum.string_(c.repo))
        k_at.add(ts(checked_now))
        k_out.add(Datum.string_(outcome))
        k_sig.add(Datum.string_(c.signals))
        k_how.add(str_or_null(how))
        k_first.add(ts(c.first_seen))
        k_sha.add(str_or_null(c.sha))
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
    if len(k_repo) > 0:
        _ = append(ctx, checked_t, [batch_of([k_repo^, k_at^, k_out^, k_sig^, k_how^, k_first^, k_sha^])])
    return added


# `Mapped` runs the step once per partition of a run, here a `Day`. Reads and
# writes are declared so `morca.tables` can enforce them and the UI can draw
# the lineage: CANDIDATES and REPO_STATS (for renamed repositories' names)
# are only read, and the two tables are written. `retries=1` re-runs a failed attempt once in the run.
comptime FindRepos = Step[
    "find_repos",
    Day,
    Int,
    find_repos,
    Mapped,
    retries=1,
    reads=[CANDIDATES, REPO_STATS],
    writes=[REPOS, CHECKED],
]
# `sensor=True`: no schedule; the scheduler starts a run when gharchive (or
# gharchive_index) commits a snapshot of `gharchive.candidates`, for the days
# that snapshot holds, and so does mojo_stats's daily snapshot of
# `mojo.repo_stats` (for its day: that run checks the candidates still
# waiting). Left at `max_runs=1`, days are checked one at a time,
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
