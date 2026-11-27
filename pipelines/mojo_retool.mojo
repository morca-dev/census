"""A backfill run by hand, once each time the history reader learns
something new: reads again the git histories mojo_history already read and
replaces their commits, migrations and tags.

New repositories don't need it: mojo_history reads them with the current
`history.read_history`, the same reader this pipeline runs, and mojo_refresh
reads again with it every repository whose head moved; this one reads them
all, moved or not. It has no schedule and no sensor; each change to what
that reader detects (Bazel as a tooling, 2026-11; Python build tools and
packaging, #116) is followed by one run over every repository. It is keyed by the `repo` column of
`mojo.repos` like mojo_history, 50 a run:

    morca backfill --rerun mojo_retool @all

A repository that mojo_history hasn't read yet is skipped (it will read it
the new way), and one whose clone fails keeps the rows it has. For the rest
the run clones it as mojo_history does (`read_history`) and, in one
`overwrite` snapshot a table (`rewrite.rewrite_histories`), removes the
files it read and adds the other repositories' rows again together with the
new ones, so no row is duplicated: a repository's rows are exactly its new
ones. Contributors are left as mojo_history (or mojo_refresh) wrote them. A
repository whose tags came back empty keeps its old tags. The log says the rows of each table
before and after, and a rerun gives the same.
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task
from morca import Ctx, Gather, Name, Pipeline, Step, Tasks, morca_main
from morca.keyed import Keyed
from morca.tables import scan, table

from cols import col, i64_at, str_at
from history import History, read_history
from lake import COMMITS, MIGRATIONS, REPOS, TAGS
from rewrite import history_repos, rewrite_histories

# The same dista task as mojo_history's: it runs on a worker, clones one
# repository and returns its `History` (with `error` set on failure rather
# than raising). `Tasks[...]` lists the tasks morca starts a runtime for, which
# the step reaches through `ctx.runtime`.
comptime ReadHistory = Task[String, History, read_history]
comptime RetoolTasks = Tasks[ReadHistory]


def retool(mut ctx: Ctx, keys: Seq[Name]) raises -> Int:
    """Reads again the history of each repository mojo_history has read and
    rewrites the three history tables with the new rows.
    The repositories are the run's `keys`. Returns the number of repositories
    re-read.

    The tables are unpartitioned, so a repository's rows can't be replaced
    by partition: `rewrite.rewrite_histories` reads each table whole, drops
    the rows of the re-read repositories, and writes everything back with
    the new rows in one `overwrite` per table."""
    # The repositories mojo_history has read (they have commit rows).
    var have = history_repos(ctx)

    ref rt = ctx.runtime[RetoolTasks]()
    var sizes = Dict[String, Int64]()
    for b in scan(ctx, table(ctx, REPOS)).select(["repo", "size_kb"]).to_batches():
        var ir = col(b, "repo")
        var isz = col(b, "size_kb")
        for r in range(b.num_rows):
            sizes[str_at(b.column(ir), r)] = i64_at(b.column(isz), r)
    var max_kb = Int64(Int(getenv("MOJO_HISTORY_MAX_KB", "0")))
    var names = List[String]()
    var refs = List[ObjectRef[History]]()
    for i in range(len(keys)):
        var repo = keys.items[i].text
        if repo not in have:
            ctx.log(String(repo, ": no history read yet, left to mojo_history"))
            continue
        if max_kb > 0 and sizes.get(repo, Int64(0)) > max_kb:
            ctx.log(String(repo, ": over MOJO_HISTORY_MAX_KB, kept as it was"))
            continue
        names.append(repo)
        refs.append(rt.remote[ReadHistory](repo))
    # The histories read replace the old. A clone that failed, or a history
    # with no commits, keeps its old rows (it is not in `histories`).
    var histories = List[History]()
    var failed = 0
    for i in range(len(refs)):
        var h = rt.get(refs[i])
        rt.release(refs[i])
        if h.error.byte_length() > 0 or len(h.commits) == 0:
            ctx.log(String(names[i], ": kept as it was (", h.error if h.error else "no commits", ")"))
            failed += 1
            continue
        histories.append(h^)
    # Contributors are left to mojo_history here, as before mojo_refresh;
    # one run at a time of the pipelines sharing the `mojo_repo_rows`
    # concurrency key (morca.toml) keeps the read-then-replace safe.
    var line = rewrite_histories(ctx, histories, contributors=False)
    ctx.log(String(len(histories), " repositories re-read (", failed, " kept as they were); ", line))
    return len(histories)


# `Gather` runs the step once per run, with all the run's keys as a `Seq`.
# Unlike mojo_history, COMMITS, MIGRATIONS and TAGS are both read and written
# and REPOS only read, and there is no `sensor=True`: nothing starts this but
# `morca backfill`.
comptime Retool = Step[
    "retool",
    Seq[Name],
    Int,
    retool,
    Gather,
    retries=1,
    reads=[REPOS, COMMITS, MIGRATIONS, TAGS],
    # replaces=: a rerun rewrites these rows (replace.replace_files) rather than
    # adding them again, so `morca backfill --rerun` needs no --allow-append.
    # Under replaces=, a morca.tables `append` to them would replace whole
    # partitions, other keys' rows included: keep writing through replace_files.
    replaces=[COMMITS, MIGRATIONS, TAGS],
]
# `Keyed` partitions are the `repo` values of `mojo.repos`; `keys_per_run=50`
# makes `@all` into runs of 50 repositories.
comptime MojoRetool = Pipeline[
    "mojo_retool",
    Retool,
    tasks=RetoolTasks,
    partitions=Keyed[REPOS, "repo"],
    keys_per_run=50,
    workers=4,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoRetool]()
