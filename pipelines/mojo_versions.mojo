"""Records the Mojo version and the dependencies each repository states in its
latest commit, with a version estimated by date.

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
`mojo.repo_versions`, one `overwrite` snapshot each, as mojo_retool does: it
keeps the other repositories' rows and adds the new ones, so no row is
duplicated and a rerun gives the same. A repository whose clone fails keeps
the rows it had.
"""

from std.os import getenv, setenv

from dista import ObjectRef, Seq, Task
from morca.civil import now
from morca import Ctx, Gather, Name, Pipeline, Step, Tasks, morca_main
from morca.keyed import Keyed
from morca.tables import ensure_table, scan

from deps import RepoDep, decode_deps
from headversion import HeadVersion, read_head_version
from historyrows import head_version_rows, head_versions_batch, repo_dep_rows, repo_deps_batch
from lake import REPOS, REPO_DEPS, REPO_VERSIONS, repo_deps_schema, repo_versions_schema
from replace import replace_files

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
    # `ensure_table` adds `declared_deps` to a `mojo.repo_versions` made
    # before it; the old rows read it as null.
    var t = ensure_table(ctx, REPO_VERSIONS, repo_versions_schema())
    var td = ensure_table(ctx, REPO_DEPS, repo_deps_schema())
    # Read the table's current rows, and the data files they are in. The
    # unpartitioned table is rewritten whole: every row of a repository not
    # in this run is kept (`old`), and every file is removed (`files`).
    var old = List[HeadVersion]()
    var files = List[String]()
    var file_rows = Int64(0)
    if t.metadata.has_current_snapshot:
        for task in scan(ctx, t).plan_files():
            files.append(task.data_file.file_path)
            file_rows += task.data_file.record_count
        for b in scan(ctx, t).to_batches():
            for ref r in head_version_rows(b):
                old.append(r.copy())
        # Cross-check, because the commit below *removes* every file: if the
        # rows read don't add up to what the files' metadata says, some were
        # not read, and removing the files would lose them.
        if Int64(len(old)) != file_rows:
            raise Error(
                REPO_VERSIONS, ": read ", len(old), " rows but its files hold ", file_rows,
            )
    # The same for `mojo.repo_deps`, also rewritten whole.
    var old_deps = List[RepoDep]()
    var dep_files = List[String]()
    var dep_file_rows = Int64(0)
    if td.metadata.has_current_snapshot:
        for task in scan(ctx, td).plan_files():
            dep_files.append(task.data_file.file_path)
            dep_file_rows += task.data_file.record_count
        for b in scan(ctx, td).to_batches():
            for ref r in repo_dep_rows(b):
                old_deps.append(r.copy())
        if Int64(len(old_deps)) != dep_file_rows:
            raise Error(
                REPO_DEPS, ": read ", len(old_deps), " rows but its files hold ", dep_file_rows,
            )
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
            # Not in `fresh`, so the merge below keeps the row it had (if
            # any); a repository that has none is tried again in a later run.
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
    # The new table contents: the old rows of the other repositories, then
    # the fresh rows. A repository in this run appears once whether or not
    # it had a row, which is why a rerun gives the same rows.
    var out = List[HeadVersion]()
    for ref r in old:
        if r.repo not in fresh:
            out.append(r.copy())
    for e in fresh.items():
        out.append(e.value.copy())
    # One `overwrite` snapshot removing `files` and adding `out` (see
    # `replace.replace_files`; a retry finds the commit its first attempt
    # made). It is safe only because one run writes this table at a time
    # (`max_runs` is left at its default of 1).
    # The dependencies the same way: the other repositories' rows, then the
    # fresh ones (a repository read with no manifest has none, and loses any
    # it had). They are committed first, so a `declared_deps` that isn't null
    # means its rows are in.
    var out_deps = List[RepoDep]()
    for ref r in old_deps:
        if r.repo not in fresh:
            out_deps.append(r.copy())
    for e in fresh.items():
        for ref d in decode_deps(e.value.deps):
            out_deps.append(RepoDep(e.key, e.value.read_at, d.copy()))
    var dep_id = replace_files(ctx, td, dep_files, [repo_deps_batch(out_deps)])
    var id = replace_files(ctx, t, files, [head_versions_batch(out)])
    ctx.log(String(
        len(fresh), " repositories read (", failed, " kept as they were), ",
        found, " with a version; ", REPO_VERSIONS, " ", len(old), " -> ", len(out),
        " rows; snapshot ", id, "; ", REPO_DEPS, " ", len(old_deps), " -> ",
        len(out_deps), " rows; snapshot ", dep_id,
    ))
    if failed > 0 and failed == len(refs):
        raise Error("every repository in this run failed (", failed, ")")
    return len(fresh)


# `Gather` runs the step once per run, with all the run's keys (repository
# names) as a `Seq`. `reads` includes REPO_VERSIONS and REPO_DEPS because the
# step reads the old rows to keep them, as well as writing them; REPOS is
# read only, which is what makes the pipeline a sensor on it.
comptime Versions = Step[
    "versions",
    Seq[Name],
    Int,
    versions,
    Gather,
    retries=1,
    reads=[REPOS, REPO_VERSIONS, REPO_DEPS],
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
