"""mojo_history's rows to and from the tables (`mojo_retool` rewrites them)."""

from morca.tables import BatchBuilder
from parquet import RecordBatch

from cols import bool_at, col, has_col, i64_at, is_valid, str_at
from deps import Dep, RepoDep
from headversion import HeadVersion
from history import CommitRow, MigrationRow, TagRow
from lake import (
    add_str_or_null,
    add_ts_or_null,
    commits_schema,
    migrations_schema,
    repo_deps_schema,
    repo_versions_schema,
    tags_schema,
)


# Each table has a pair: `*_rows` reads a batch scanned from the table into
# structs, and `*_batch` builds a batch to append or write. Column positions
# in the builders (`BatchBuilder.roots`) are the top-level columns of the
# schema in `lake.mojo`, in order.


def commit_rows(b: RecordBatch) raises -> List[CommitRow]:
    """The rows of a scanned `mojo.commits` batch."""
    var out = List[CommitRow]()
    var c = List[Int]()
    for name in [
        "repo", "sha", "committed_at", "seq", "mojo_lines", "mojo_files",
        "tooling", "mojo_version", "version_source",
    ]:
        c.append(col(b, name))
    # `packaging` came later: a batch from before has no such column.
    var c_pack = col(b, "packaging") if has_col(b, "packaging") else -1
    var c_subj = col(b, "subject") if has_col(b, "subject") else -1
    var c_chg = col(b, "changes") if has_col(b, "changes") else -1
    for r in range(b.num_rows):
        out.append(
            CommitRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                i64_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                i64_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
                str_at(b.column(c[7]), r),
                str_at(b.column(c[8]), r),
                str_at(b.column(c_pack), r) if c_pack >= 0 else String(),
                str_at(b.column(c_subj), r) if c_subj >= 0 else String(),
                str_at(b.column(c_chg), r) if c_chg >= 0 else String(),
            )
        )
    return out^


def commits_batch(rows: List[CommitRow]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.commits`."""
    var b = BatchBuilder(commits_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_str(cs[1], r.sha)
        b.add_int(cs[2], r.committed_at)
        b.add_int(cs[3], r.seq)
        b.add_int(cs[4], r.mojo_lines)
        b.add_int(cs[5], r.mojo_files)
        b.add_str(cs[6], r.tooling)
        add_str_or_null(b, cs[7], r.mojo_version)
        add_str_or_null(b, cs[8], r.version_source)
        add_str_or_null(b, cs[9], r.packaging)
        add_str_or_null(b, cs[10], r.subject)
        add_str_or_null(b, cs[11], r.changes)
    return b^.build()


def migration_rows(b: RecordBatch) raises -> List[MigrationRow]:
    """The rows of a scanned `mojo.migrations` batch."""
    var out = List[MigrationRow]()
    var c = List[Int]()
    for name in ["repo", "sha", "committed_at", "kind", "from_value", "to_value"]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            MigrationRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                i64_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r),
                str_at(b.column(c[4]), r),
                str_at(b.column(c[5]), r),
            )
        )
    return out^


def migrations_batch(rows: List[MigrationRow]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.migrations`."""
    var b = BatchBuilder(migrations_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_str(cs[1], r.sha)
        b.add_int(cs[2], r.committed_at)
        b.add_str(cs[3], r.kind)
        add_str_or_null(b, cs[4], r.from_value)
        add_str_or_null(b, cs[5], r.to_value)
    return b^.build()


def tag_rows(b: RecordBatch) raises -> List[TagRow]:
    """The rows of a scanned `mojo.tags` batch."""
    var out = List[TagRow]()
    var c = List[Int]()
    for name in [
        "repo", "tag", "commit", "annotated", "tagged_at", "tooling",
        "mojo_version",
    ]:
        c.append(col(b, name))
    var c_pack = col(b, "packaging") if has_col(b, "packaging") else -1
    for r in range(b.num_rows):
        out.append(
            TagRow(
                str_at(b.column(c[0]), r),
                str_at(b.column(c[1]), r),
                str_at(b.column(c[2]), r),
                bool_at(b.column(c[3]), r),
                i64_at(b.column(c[4]), r),
                str_at(b.column(c[5]), r),
                str_at(b.column(c[6]), r),
                str_at(b.column(c_pack), r) if c_pack >= 0 else String(),
            )
        )
    return out^


def tags_batch(rows: List[TagRow]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.tags`."""
    var b = BatchBuilder(tags_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_str(cs[1], r.tag)
        b.add_str(cs[2], r.commit)
        b.add_bool(cs[3], r.annotated)
        add_ts_or_null(b, cs[4], r.tagged_at)
        add_str_or_null(b, cs[5], r.tooling)
        add_str_or_null(b, cs[6], r.mojo_version)
        add_str_or_null(b, cs[7], r.packaging)
    return b^.build()


def head_version_rows(b: RecordBatch) raises -> List[HeadVersion]:
    """The rows of a scanned `mojo.repo_versions` batch (`error` and `deps`
    are empty). `read_at` is the second column but a late field of
    `HeadVersion`, hence the out-of-order indexes. `declared_deps` is -1
    where it is null, and in a batch from before the column was added."""
    var out = List[HeadVersion]()
    var c = List[Int]()
    for name in [
        "repo", "read_at", "head_sha", "mojo_version", "version_source",
        "version_file", "version_estimate", "estimate_source", "last_mojo_commit",
    ]:
        c.append(col(b, name))
    var c_deps = col(b, "declared_deps") if has_col(b, "declared_deps") else -1
    for r in range(b.num_rows):
        var declared = Int64(-1)
        if c_deps >= 0 and is_valid(b.column(c_deps), r):
            declared = i64_at(b.column(c_deps), r)
        out.append(
            HeadVersion(
                str_at(b.column(c[0]), r), String(), str_at(b.column(c[2]), r),
                str_at(b.column(c[3]), r), str_at(b.column(c[4]), r),
                str_at(b.column(c[5]), r), str_at(b.column(c[6]), r),
                str_at(b.column(c[7]), r), i64_at(b.column(c[8]), r),
                i64_at(b.column(c[1]), r), declared, String(),
            )
        )
    return out^


def head_versions_batch(rows: List[HeadVersion]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.repo_versions`."""
    var b = BatchBuilder(repo_versions_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_int(cs[1], r.read_at)
        add_str_or_null(b, cs[2], r.head_sha)
        add_str_or_null(b, cs[3], r.version)
        add_str_or_null(b, cs[4], r.source)
        add_str_or_null(b, cs[5], r.file)
        add_str_or_null(b, cs[6], r.estimate)
        add_str_or_null(b, cs[7], r.estimate_source)
        add_ts_or_null(b, cs[8], r.last_mojo_commit)
        if r.declared_deps >= 0:
            b.add_int(cs[9], r.declared_deps)
        else:
            b.add_null(cs[9])
    return b^.build()


def repo_dep_rows(b: RecordBatch) raises -> List[RepoDep]:
    """The rows of a scanned `mojo.repo_deps` batch."""
    var out = List[RepoDep]()
    var c = List[Int]()
    for name in [
        "repo", "read_at", "relation", "kind", "dep_name", "dep_repo", "section", "file",
    ]:
        c.append(col(b, name))
    for r in range(b.num_rows):
        out.append(
            RepoDep(
                str_at(b.column(c[0]), r), i64_at(b.column(c[1]), r),
                Dep(
                    str_at(b.column(c[2]), r), str_at(b.column(c[3]), r),
                    str_at(b.column(c[4]), r), str_at(b.column(c[5]), r),
                    str_at(b.column(c[6]), r), str_at(b.column(c[7]), r),
                ),
            )
        )
    return out^


def repo_deps_batch(rows: List[RepoDep]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.repo_deps`."""
    var b = BatchBuilder(repo_deps_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.repo)
        b.add_int(cs[1], r.read_at)
        b.add_str(cs[2], r.dep.relation)
        b.add_str(cs[3], r.dep.kind)
        b.add_str(cs[4], r.dep.name)
        add_str_or_null(b, cs[5], r.dep.dep_repo)
        add_str_or_null(b, cs[6], r.dep.section)
        b.add_str(cs[7], r.dep.file)
    return b^.build()
