"""Replacing some repositories' rows in the unpartitioned tables they are
read into again: the history tables (mojo_retool, mojo_refresh) and
`mojo.repo_versions` with `mojo.repo_deps` (mojo_versions, mojo_refresh).

A repository's rows can't be replaced by partition, so each table is read
whole, the rows of the repositories read again are dropped, and everything
is written back with their new rows in one `overwrite` snapshot
(`replace.replace_files`) that removes the files read. The rows read are
checked against the files' record counts first, so nothing unread is
removed; and `morca.tables.commit` refuses the snapshot if another writer
removed one of those files since, committing nothing. A repository's rows
are exactly its new ones, so a rerun doesn't duplicate them.

With `pinned` (mojo_retool, which declares the tables in `reads=`) the
tables are read at the step's pinned snapshot; without it (mojo_versions,
mojo_refresh) at their current one, undeclared, as mojo_history reads
`mojo.commits`: morca refuses to register two pipelines that both read and
write a dataset (a cycle), and a keyed sensor (mojo_versions) that reads a
dataset an hourly pipeline (mojo_refresh) writes. One writer at a time: the
pipelines that call this share the `mojo_repo_rows` concurrency key
(morca.toml), which is what keeps the read-then-replace safe.
"""

from morca import Ctx
from morca.tables import Table, TableScan, ensure_table, scan

from contributors import AuthorMonth, contributor_rows, contributors_batch
from deps import RepoDep, decode_deps
from headversion import HeadVersion
from history import CommitRow, History, MigrationRow, TagRow
from historyrows import (
    commit_rows,
    commits_batch,
    head_version_rows,
    head_versions_batch,
    migration_rows,
    migrations_batch,
    repo_dep_rows,
    repo_deps_batch,
    tag_rows,
    tags_batch,
)
from lake import (
    COMMITS,
    CONTRIBUTORS,
    MIGRATIONS,
    REPO_DEPS,
    REPO_VERSIONS,
    TAGS,
    commits_schema,
    contributors_schema,
    migrations_schema,
    repo_deps_schema,
    repo_versions_schema,
    tags_schema,
)
from replace import replace_files
from cols import str_at


@fieldwise_init
struct TableFiles(Movable):
    """A table's data files at the step's snapshot: their paths (what the
    `overwrite` removes) and the rows they hold (what the rows read must add
    up to)."""

    var paths: List[String]
    var rows: Int64


def scan_of(mut ctx: Ctx, t: Table, pinned: Bool) raises -> TableScan:
    """A scan of `t` at the step's pinned snapshot (`pinned`, for a dataset
    the step declared in `reads=`), else at its current one."""
    if pinned:
        return scan(ctx, t)
    return t.scan()


def table_files(mut ctx: Ctx, t: Table, pinned: Bool = True) raises -> TableFiles:
    """The data files of `t` (`scan_of`)."""
    var out = TableFiles(List[String](), 0)
    if not t.metadata.has_current_snapshot:
        return out^
    for task in scan_of(ctx, t, pinned).plan_files():
        out.paths.append(task.data_file.file_path)
        out.rows += task.data_file.record_count
    return out^


def _check(dataset: String, rows: Int, files: TableFiles) raises:
    """Raises unless the rows read are all the files hold: removing the
    files would otherwise lose the ones not read."""
    if Int64(rows) != files.rows:
        raise Error(dataset, ": read ", rows, " rows but its files hold ", files.rows)


def history_repos(mut ctx: Ctx) raises -> Dict[String, Bool]:
    """The repositories `mojo.commits` has, at the step's snapshot: the ones
    mojo_history has read."""
    var t = ensure_table(ctx, COMMITS, commits_schema())
    var out = Dict[String, Bool]()
    if not t.metadata.has_current_snapshot:
        return out^
    for b in scan(ctx, t).select(["repo"]).to_batches():
        for r in range(b.num_rows):
            out[str_at(b.column(0), r)] = True
    return out^


def rewrite_histories(
    mut ctx: Ctx, histories: List[History], contributors: Bool, pinned: Bool = True
) raises -> String:
    """Replaces the rows of the repositories of `histories` (each a history read
    with commits) in `mojo.commits`, `mojo.migrations` and `mojo.tags`, and
    with `contributors` in `mojo.contributors` too. Returns a line for the
    log: each table's rows before and after, and the snapshot.

    A repository whose new read has no tags keeps its old tags, and with
    `contributors` one with no contributor rows keeps its old ones. Every
    repository whose commit count changed is logged: a read again that
    changes no counts only changed columns (tooling, version); a changed
    count means the first-parent history itself differs (new commits, or a
    force-push)."""
    if len(histories) == 0:
        return String("no repositories to replace")
    # `ensure_table` adds the columns the schemas gained since the tables
    # were made (`packaging`), so the rows written back can carry them.
    var commits_t = ensure_table(ctx, COMMITS, commits_schema())
    var migrations_t = ensure_table(ctx, MIGRATIONS, migrations_schema())
    var tags_t = ensure_table(ctx, TAGS, tags_schema())
    var commits_files = table_files(ctx, commits_t, pinned)
    var migrations_files = table_files(ctx, migrations_t, pinned)
    var tags_files = table_files(ctx, tags_t, pinned)
    var old_commits = List[CommitRow]()
    var old_migrations = List[MigrationRow]()
    var old_tags = List[TagRow]()
    if commits_t.metadata.has_current_snapshot:
        for b in scan_of(ctx, commits_t, pinned).to_batches():
            for ref r in commit_rows(b):
                old_commits.append(r.copy())
    if migrations_t.metadata.has_current_snapshot:
        for b in scan_of(ctx, migrations_t, pinned).to_batches():
            for ref r in migration_rows(b):
                old_migrations.append(r.copy())
    if tags_t.metadata.has_current_snapshot:
        for b in scan_of(ctx, tags_t, pinned).to_batches():
            for ref r in tag_rows(b):
                old_tags.append(r.copy())
    _check(COMMITS, len(old_commits), commits_files)
    _check(MIGRATIONS, len(old_migrations), migrations_files)
    _check(TAGS, len(old_tags), tags_files)

    var done = Dict[String, Bool]()
    var tagged = Dict[String, Bool]()
    var counted = Dict[String, Bool]()
    for ref h in histories:
        done[h.repo] = True
        if len(h.tags) > 0:
            tagged[h.repo] = True
        if len(h.authors) > 0:
            counted[h.repo] = True

    var before_c = Dict[String, Int]()
    var after_c = Dict[String, Int]()
    for ref c in old_commits:
        if c.repo in done:
            before_c[c.repo] = before_c.get(c.repo, 0) + 1
    for ref h in histories:
        after_c[h.repo] = after_c.get(h.repo, 0) + len(h.commits)
    for e in before_c.items():
        var a = after_c.get(e.key, 0)
        if a != e.value:
            ctx.log(String(e.key, ": ", e.value, " commits before, ", a, " now"))

    var out_commits = List[CommitRow]()
    for ref c in old_commits:
        if c.repo not in done:
            out_commits.append(c.copy())
    var out_migrations = List[MigrationRow]()
    for ref m in old_migrations:
        if m.repo not in done:
            out_migrations.append(m.copy())
    var out_tags = List[TagRow]()
    for ref t in old_tags:
        if t.repo not in tagged:
            out_tags.append(t.copy())
    for ref h in histories:
        for ref c in h.commits.items:
            out_commits.append(c.copy())
        for ref m in h.migrations.items:
            out_migrations.append(m.copy())
        for ref t in h.tags.items:
            out_tags.append(t.copy())
    # One `overwrite` snapshot per table; a retry whose first attempt got
    # this far finds the snapshots and writes nothing.
    var id = replace_files(ctx, commits_t, commits_files.paths, [commits_batch(out_commits)])
    _ = replace_files(ctx, migrations_t, migrations_files.paths, [migrations_batch(out_migrations)])
    _ = replace_files(ctx, tags_t, tags_files.paths, [tags_batch(out_tags)])
    var line = String(
        COMMITS, " ", len(old_commits), " -> ", len(out_commits), " rows, ",
        MIGRATIONS, " ", len(old_migrations), " -> ", len(out_migrations),
        ", ", TAGS, " ", len(old_tags), " -> ", len(out_tags),
    )
    if contributors:
        var contributors_t = ensure_table(ctx, CONTRIBUTORS, contributors_schema())
        var files = table_files(ctx, contributors_t, pinned)
        var old = List[AuthorMonth]()
        if contributors_t.metadata.has_current_snapshot:
            for b in scan_of(ctx, contributors_t, pinned).to_batches():
                for ref r in contributor_rows(b):
                    old.append(r.copy())
        _check(CONTRIBUTORS, len(old), files)
        var out = List[AuthorMonth]()
        for ref r in old:
            if r.repo not in counted:
                out.append(r.copy())
        for ref h in histories:
            for ref a in h.authors.items:
                out.append(a.copy())
        _ = replace_files(ctx, contributors_t, files.paths, [contributors_batch(out)])
        line += String(", ", CONTRIBUTORS, " ", len(old), " -> ", len(out))
    line += String("; snapshot ", id)
    return line^


def rewrite_head_versions(
    mut ctx: Ctx, fresh: Dict[String, HeadVersion], pinned: Bool = True
) raises -> String:
    """Replaces the rows of the repositories of `fresh` (each a HEAD read,
    `read_at` set) in `mojo.repo_versions` and `mojo.repo_deps`. Returns a
    line for the log: each table's rows before and after, and the
    snapshots.

    A repository in `fresh` appears once in `mojo.repo_versions` whether or
    not it had a row, and has exactly its new dependencies (none, for one
    read with no manifest). The dependencies are committed first, so a
    `declared_deps` that isn't null means its rows are in."""
    if len(fresh) == 0:
        return String("no repositories to replace")
    # `ensure_table` adds `declared_deps` to a `mojo.repo_versions` made
    # before it; the old rows read it as null.
    var t = ensure_table(ctx, REPO_VERSIONS, repo_versions_schema())
    var td = ensure_table(ctx, REPO_DEPS, repo_deps_schema())
    var files = table_files(ctx, t, pinned)
    var dep_files = table_files(ctx, td, pinned)
    var old = List[HeadVersion]()
    if t.metadata.has_current_snapshot:
        for b in scan_of(ctx, t, pinned).to_batches():
            for ref r in head_version_rows(b):
                old.append(r.copy())
    var old_deps = List[RepoDep]()
    if td.metadata.has_current_snapshot:
        for b in scan_of(ctx, td, pinned).to_batches():
            for ref r in repo_dep_rows(b):
                old_deps.append(r.copy())
    _check(REPO_VERSIONS, len(old), files)
    _check(REPO_DEPS, len(old_deps), dep_files)
    var out = List[HeadVersion]()
    for ref r in old:
        if r.repo not in fresh:
            out.append(r.copy())
    for e in fresh.items():
        out.append(e.value.copy())
    var out_deps = List[RepoDep]()
    for ref r in old_deps:
        if r.repo not in fresh:
            out_deps.append(r.copy())
    for e in fresh.items():
        for ref d in decode_deps(e.value.deps):
            out_deps.append(RepoDep(e.key, e.value.read_at, d.copy()))
    var dep_id = replace_files(ctx, td, dep_files.paths, [repo_deps_batch(out_deps)])
    var id = replace_files(ctx, t, files.paths, [head_versions_batch(out)])
    return String(
        REPO_VERSIONS, " ", len(old), " -> ", len(out), " rows; snapshot ", id,
        "; ", REPO_DEPS, " ", len(old_deps), " -> ", len(out_deps),
        " rows; snapshot ", dep_id,
    )
