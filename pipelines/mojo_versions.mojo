"""Records the Mojo version and the dependencies each repository states in its
latest commit, with a version estimated by date, for the repositories
mojo_repos adds (a sensor on mojo.repos) or a backfill names; mojo_refresh
reads them again, hourly, once their head moves.

The mojo_versions pipeline: the Mojo version each repository states at its
HEAD, for the ones whose lock file and manifest name none, and an estimate by
date; and the dependencies its manifests declare at HEAD.

Keyed by the `repo` column of `mojo.repos` like mojo_history, 50 repositories
a run, and a sensor, so each snapshot mojo_repos commits starts runs for the
repositories it adds. A repository that mojo_history hasn't read is read here
all the same (this step clones it without file contents). Run for the
repositories already in the lake by hand:

    morca backfill --rerun mojo_versions @all

which is also how `mojo.repo_deps` and `declared_deps` were filled for the
repositories read before dependencies were (a row of `mojo.repo_versions`
with `declared_deps` null is one of those). New repositories get both from
their first run. Which dependencies are census repositories, and how many
repositories use each, the console works out from the rows when it builds
(`deps.resolve`), so a repository added later is matched without a rerun of
the ones that depend on it.

Each repository goes to a dista task (`read_head_version`: a blobless clone,
the few files at HEAD that can state a version, the date of the last commit
that touched a Mojo file, and the manifests' dependencies). The step then
replaces the repositories' rows of `mojo.repo_deps` and of
`mojo.repo_versions`, one `overwrite` snapshot each
(`rewrite.rewrite_head_versions`, as mojo_retool and mojo_refresh do): it
keeps the other repositories' rows and adds the new ones, so no row is
duplicated and a rerun gives the same. A repository whose clone fails keeps
the rows it had.
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task
from morca.civil import now
from morca import Ctx, Gather, Name, Pipeline, Step, Tasks, morca_main
from morca.keyed import Keyed

from headversion import HeadVersion, read_head_version
from lake import REPOS, REPO_DEPS, REPO_VERSIONS
from rewrite import rewrite_head_versions

# A dista `Task` runs on a worker process: it clones one repository and
# returns a `HeadVersion` (with `error` set rather than raising, so one bad
# repository doesn't fail the run). `Tasks[...]` lists the tasks whose
# runtime morca starts for a run; the step reaches it with `ctx.runtime`.
comptime ReadHead = Task[String, HeadVersion, read_head_version]
comptime VersionTasks = Tasks[ReadHead]


def versions(mut ctx: Ctx, keys: Seq[Name]) raises -> Int:
    """Reads the latest commit of up to 50 repositories and replaces their rows
    in mojo.repo_versions and mojo.repo_deps.
    The repositories are the run's `keys`, and each table gets one snapshot.
    Returns the number of repositories read."""
    # All tasks are started, then collected in order; only as many clones run
    # at once as there are dista workers.
    ref rt = ctx.runtime[VersionTasks]()
    var names = List[String]()
    var refs = List[ObjectRef[HeadVersion]]()
    for i in range(len(keys)):
        var repo = keys.items[i].text
        names.append(repo)
        refs.append(rt.remote[ReadHead](repo))
    var fresh = Dict[String, HeadVersion]()
    var failed = 0
    var found = 0
    # `read_at` is stamped here, once for the run, in microseconds, not on
    # the worker.
    var now = now() * 1_000_000
    for i in range(len(refs)):
        var h = rt.get(refs[i])
        rt.release(refs[i])
        if h.error.byte_length() > 0:
            # Not in `fresh`, so the rewrite keeps the row it had (if any);
            # a repository that has none is tried again in a later run.
            ctx.log(String(names[i], ": kept as it was (", h.error, ")"))
            failed += 1
            continue
        h.read_at = now
        if h.version.byte_length() > 0:
            found += 1
        ctx.log(String(
            names[i], ": ", h.version if h.version else "no version",
            " (", h.source if h.source else "-", ") estimate ",
            h.estimate if h.estimate else "-", ", ", h.declared_deps, " dependencies",
        ))
        fresh[names[i]] = h^
    # The other repositories' rows are kept and these replaced, one
    # `overwrite` snapshot per table (`rewrite.rewrite_head_versions`). It
    # is safe only because one run at a time writes these tables (the
    # `mojo_repo_rows` concurrency key in morca.toml, and `max_runs` 1).
    var line = rewrite_head_versions(ctx, fresh, pinned=False)
    ctx.log(String(
        len(fresh), " repositories read (", failed, " kept as they were), ",
        found, " with a version; ", line,
    ))
    if failed > 0 and failed == len(refs):
        raise Error("every repository in this run failed (", failed, ")")
    return len(fresh)


# `Gather` runs the step once per run, with all the run's keys (repository
# names) as a `Seq`. REPOS is read only, which is what makes the pipeline a
# sensor on it. The step also reads the old rows of REPO_VERSIONS and
# REPO_DEPS to keep them, at their current snapshot, but doesn't declare them
# in `reads`: mojo_refresh (hourly) writes them too, and morca refuses to
# register a keyed sensor that reads a dataset a time-partitioned pipeline
# writes. The `mojo_repo_rows` concurrency key (morca.toml) keeps the
# read-then-replace safe. A changed `reads` leaves the keys done (no
# `version=` changed).
comptime Versions = Step[
    "versions",
    Seq[Name],
    Int,
    versions,
    Gather,
    retries=1,
    reads=[REPOS],
    # replaces=: a rerun rewrites these rows (replace.replace_files) rather than
    # adding them again, so `morca backfill --rerun` needs no --allow-append.
    # Under replaces=, a morca.tables `append` to them would replace whole
    # partitions, other keys' rows included: keep writing through replace_files.
    replaces=[REPO_VERSIONS, REPO_DEPS],
]
# `Keyed` partitions are names read from a column of a dataset, here the
# `repo` values of `mojo.repos`; `sensor=True` starts a run over the keys a
# new snapshot of a dataset the pipeline reads (mojo.repos) added.
comptime MojoVersions = Pipeline[
    "mojo_versions",
    Versions,
    tasks=VersionTasks,
    partitions=Keyed[REPOS, "repo"],  # owner/name
    keys_per_run=50,
    sensor=True,
    workers=4,
]


def main() raises:
    if not getenv("MORCA_WAREHOUSE"):
        _ = setenv("MORCA_WAREHOUSE", "build/warehouse")
    morca_main[MojoVersions]()
