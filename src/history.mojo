"""A repository's history: lines of Mojo, tooling, packaging and Mojo
version at each commit, and the commits where one of those changed.

`read_history` clones the repository (bare, into `MOJO_HISTORY_WORKDIR`,
default `$TMPDIR/mojo_history`), walks its first-parent history once with
`git log --numstat --summary`, and reads a manifest or lock file only at the
commits that touch one. It also reads the clone's tags (`git
for-each-ref refs/tags`) and its contributors (`contributors.read_authors`).
`read_tags_and_authors` reads only those two, from a clone without file
contents, for a repository whose history mojo.commits already has. It needs
`git` on the PATH.
"""

from std.os import getenv

from dista import Seq

from contributors import AuthorMonth, read_authors
from filemix import FileMix

from command import STDERR_DROP, STDERR_MERGE, git, make_dirs, remove_tree
from retry import backoff_ms, env_int, log_retry, nap_ms
from deps import names_mojo_pkg
from versions import (
    ToolFiles,
    lock_version,
    manifest_version,
    packaging,
    pin_version,
    pylock_version,
    pyproject_tables,
    recipe_kind,
    tooling,
)


comptime LOG_FORMAT = "@@%H %ct %s"
"""A commit's header line in `git log`: sha, committer time, subject."""
comptime SUBJECT_MAX = 200
"""Bytes of a commit subject kept (cut on a codepoint boundary)."""


def cut_subject(s: StringSpan) -> String:
    """`s` to at most `SUBJECT_MAX` bytes, on a codepoint boundary."""
    if s.byte_length() <= SUBJECT_MAX:
        return String(s)
    var out = String()
    for cp in s.codepoint_slices():
        if out.byte_length() + cp.byte_length() > SUBJECT_MAX:
            break
        out += cp
    return out^


@fieldwise_init
struct CommitRow(Copyable, Movable):
    """One commit of the first-parent history, as a row of `mojo.commits`:
    the totals of Mojo lines and files *after* it, and the tooling and Mojo
    version in force at it (carried forward from earlier commits when this
    one touched no manifest)."""

    var repo: String
    var sha: String
    var committed_at: Int64
    """Microseconds since the epoch, the committer's time."""
    var seq: Int64
    var mojo_lines: Int64
    var mojo_files: Int64
    var tooling: String
    var mojo_version: String
    var version_source: String
    var packaging: String
    """`rattler`, `conda-build` or `none` (`versions.packaging`)."""
    var subject: String
    """The first line of the commit message, at most `SUBJECT_MAX` bytes."""
    var changes: String
    """What kinds of files it changed and how much (`FileMix.encode`); empty
    for a row read before #121's file mix."""


@fieldwise_init
struct MigrationRow(Copyable, Movable):
    """One change of tooling or of Mojo version, as a row of
    `mojo.migrations`, recorded at the commit that made it."""

    var repo: String
    var sha: String
    var committed_at: Int64
    var kind: String
    """`tooling`, `packaging` or `mojo_version`."""
    var from_value: String
    var to_value: String


@fieldwise_init
struct TagRow(Copyable, Movable):
    """One git tag, as a row of `mojo.tags`."""

    var repo: String
    var tag: String
    """The name under `refs/tags/`."""
    var commit: String
    """What the tag points at, peeled once for an annotated tag."""
    var annotated: Bool
    var tagged_at: Int64
    """The tagger's date (annotated) or the commit's (lightweight), in
    microseconds; 0 if git had none."""
    var tooling: String
    var mojo_version: String
    """At `commit`, when it is on the first-parent history; else empty."""
    var packaging: String
    """At `commit`, as `tooling`."""


@fieldwise_init
struct History(Copyable, Movable):
    """What a dista task returns for one repository. A plain struct of
    `Seq`s so dista can send it by reflection. Failures travel in `error`
    rather than as an exception, so one bad repository doesn't fail the
    other 49 of its run."""

    var repo: String
    var error: String
    """Empty when the history was read."""
    var commits: Seq[CommitRow]
    var migrations: Seq[MigrationRow]
    var tags: Seq[TagRow]
    var authors: Seq[AuthorMonth]
    """Its contributors by month (`contributors.read_authors`)."""

    @staticmethod
    def empty(repo: String) -> Self:
        """A history with no rows and no error."""
        return Self(
            repo, String(), Seq[CommitRow](), Seq[MigrationRow](), Seq[TagRow](),
            Seq[AuthorMonth](),
        )


comptime TAG_FORMAT = (
    "%(refname)%09%(objecttype)%09%(objectname)%09%(*objectname)%09%(creatordate:unix)"
)
"""`git for-each-ref --format`: tab-separated, as git refuses tabs in ref
names."""


def parse_tags(repo: String, output: String) -> List[TagRow]:
    """`git for-each-ref --format=TAG_FORMAT refs/tags` output as rows, by
    name. Lines that don't have the five fields are skipped."""
    var rows = List[TagRow]()
    for line in output.split("\n"):
        # An annotated tag is its own object (`tag`) that points at a commit
        # (`%(*objectname)`); a lightweight tag is the commit itself.
        var f = line.split("\t")
        if len(f) != 5:
            continue
        var name = String(f[0])
        if not name.startswith("refs/tags/"):
            continue
        var tag = String(name[byte=10:])
        if tag.byte_length() == 0:
            continue
        var annotated = String(f[1]) == "tag"
        var target = String(f[3]) if annotated and f[3].byte_length() > 0 else String(f[2])
        var at: Int64
        try:
            at = Int64(Int(String(f[4]).strip())) * 1_000_000
        except:
            at = 0
        rows.append(TagRow(repo, tag, target, annotated, at, String(), String(), String()))
    # An insertion sort by name, so a repository's tags always come out in
    # the same order whatever order git listed them in.
    for i in range(1, len(rows)):
        var j = i
        while j > 0 and rows[j - 1].tag > rows[j].tag:
            rows.swap_elements(j - 1, j)
            j -= 1
    return rows^


def join_tags(
    mut tags: List[TagRow], commits: Dict[String, Tuple[String, String, String]]
):
    """Fills each tag's tooling, Mojo version and packaging from the commit
    it points at (sha -> (tooling, version, packaging))."""
    for ref t in tags:
        if t.commit in commits:
            var v = commits.get(t.commit, (String(), String(), String()))
            t.tooling = v[0]
            t.mojo_version = v[1]
            t.packaging = v[2]


def _read_tags(repo: String, dir: String, mut out: History) raises:
    """Appends the clone's tags to `out.tags`, each with the tooling and
    Mojo version of the commit it points at when `out.commits` has it."""
    var r = git(["-C", dir, "for-each-ref", String("--format=", TAG_FORMAT), "refs/tags"])
    if r[0] != 0:
        raise Error("git for-each-ref failed: ", r[1].strip())
    var tags = parse_tags(repo, r[1])
    var by_sha = Dict[String, Tuple[String, String, String]]()
    for ref c in out.commits.items:
        by_sha[c.sha] = (c.tooling, c.mojo_version, c.packaging)
    join_tags(tags, by_sha)
    for ref t in tags:
        out.tags.append(t.copy())


def safe_repo(repo: String) -> Bool:
    """`owner/name` with GitHub's characters only: it names a directory
    under the work directory and a GitHub URL, so nothing else may pass."""
    var slashes = 0
    for c in repo.as_bytes():
        if c == UInt8(ord("/")):
            slashes += 1
        elif not (
            (c >= 48 and c <= 57)
            or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or c == UInt8(ord("-"))
            or c == UInt8(ord("_"))
            or c == UInt8(ord("."))
        ):
            return False
    return slashes == 1 and not repo.startswith(".") and ".." not in repo


def is_bazel_file(path: StringSpan) -> Bool:
    """The files that make a repository a Bazel one, at its root."""
    return (
        path == "MODULE.bazel"
        or path == "WORKSPACE"
        or path == "WORKSPACE.bazel"
        or path == "BUILD.bazel"
    )


def is_python_manifest(path: StringSpan) -> Bool:
    """A root `pyproject.toml` or `requirements*.txt`: where a Python build
    tool is told to install Mojo."""
    if "/" in path:
        return False
    return path == "pyproject.toml" or (
        path.startswith("requirements") and path.endswith(".txt")
    )


def is_tool_file(path: StringSpan) -> Bool:
    """Whether a change to `path` can change a commit's tooling or Mojo
    version, so the version is read again (Bazel's files only change the
    tooling, recipes only the packaging: neither needs a read)."""
    return (
        path == "pixi.toml" or path == "pixi.lock" or path == "mojoproject.toml"
        or path == "magic.lock" or path == "uv.lock" or path == "poetry.lock"
        or path == "pdm.lock" or is_python_manifest(path)
    )


def is_mojo_file(path: StringSpan) -> Bool:
    """Whether `path` is Mojo source, in either extension."""
    return path.endswith(".mojo") or path.endswith(".🔥")


def git_timeout_ms() -> Int:
    """`GIT_TIMEOUT_SECONDS` (default 600): how long one git command that
    talks to GitHub may run before it is killed."""
    return env_int("GIT_TIMEOUT_SECONDS", 600) * 1000


def git_net() -> List[String]:
    """git's options for a command that talks to GitHub: git's own stall
    detector, which aborts a transfer slower than
    `GIT_LOW_SPEED_LIMIT` bytes a second (1000) for `GIT_LOW_SPEED_SECONDS`
    (60), long before `GIT_TIMEOUT_SECONDS`. The `-c` settings reach the
    fetches a blobless clone makes later, from `git show`, too."""
    return [
        "-c", String("http.lowSpeedLimit=", env_int("GIT_LOW_SPEED_LIMIT", 1000)),
        "-c", String("http.lowSpeedTime=", env_int("GIT_LOW_SPEED_SECONDS", 60)),
    ]


def transient_git_error(output: String) -> Bool:
    """Whether a failed clone is worth trying again: everything but a
    repository that is gone, private or blocked."""
    var low = output.lower()
    for p in [
        "repository not found",
        "could not read username",
        "authentication failed",
        "returned error: 403",
        "returned error: 404",
        "returned error: 451",
        "access to this repository has been disabled",
        "not a repository name",
    ]:
        if p in low:
            return False
    return True


def git_clone(repo: String, dir: String, flags: List[String]) raises -> Tuple[Int, String]:
    """`git clone --quiet --bare <flags>` of `repo` from GitHub into `dir`,
    each try killed after `git_timeout_ms()` and tried again, with
    exponential backoff and jitter, up to `GIT_RETRIES` (default 3) more
    times, unless it failed for good (`transient_git_error`). Returns the
    last try's status and output (with the number of tries if it failed)."""
    var tries = env_int("GIT_RETRIES", 3) + 1
    var timeout = git_timeout_ms()
    var attempt = 1
    while True:
        make_dirs(_workdir())
        remove_tree(dir)
        var args = git_net()
        args.append("clone")
        args.append("--quiet")
        args.append("--bare")
        for f in flags:
            args.append(f)
        args.append(String("https://github.com/", repo, ".git"))
        args.append(dir)
        var r = git(args, timeout, STDERR_MERGE)
        if r[0] == 0:
            return r^
        var err = String(r[1].strip())
        if attempt >= tries or not transient_git_error(err):
            if attempt > 1:
                err = String(err, " (after ", attempt, " tries)")
            return (r[0], err^)
        var wait = backoff_ms(attempt - 1)
        log_retry(String("git clone ", repo), attempt, tries, wait, err)
        nap_ms(wait)
        attempt += 1


def _show(dir: String, sha: String, file: String) raises -> String:
    """The contents of `file` at `sha`, or "" if it isn't there."""
    var r = git(["-C", dir, "show", String(sha, ":", file)], stderr=STDERR_DROP)
    if r[0] != 0:
        return String()
    return r[1]


struct _State:
    """The commit being read, and what is true after it: which files that
    decide the tooling exist (`f`, and the Python manifests in `py_files`),
    how many recipes of each kind there are, the running totals of Mojo
    `lines` and `files`, and the `tool`, `pack`, `version` and `source` in
    force. All of it is carried from commit to commit; `_finish` turns the
    state into a row. `touched` is whether this commit added, removed or
    changed a file that can name the version (`is_tool_file`), the only
    time the version is read again; `py_touched` whether it changed a Python
    manifest, which is then read again for its Mojo dependency and its
    `[tool.*]` tables."""

    var f: ToolFiles
    var py_files: List[String]
    """The Python manifests (`is_python_manifest`) that exist, in the order
    they appeared."""
    var rattler: Int
    var conda_build: Int
    var touched: Bool
    var py_touched: Bool
    var lines: Int64
    var files: Int64
    var sha: String
    var at: Int64
    var subject: String
    var seq: Int64
    var tool: String
    var pack: String
    var version: String
    var source: String
    var mix: FileMix
    """This commit's files (`filemix`); reset at each commit."""

    def __init__(out self):
        self.f = ToolFiles()
        self.py_files = List[String]()
        self.rattler = 0
        self.conda_build = 0
        self.sha = String()
        self.at = 0
        self.subject = String()
        self.seq = 0
        self.tool = String("none")
        self.pack = String("none")
        self.version = String()
        self.source = String()
        self.touched = False
        self.py_touched = False
        self.lines = 0
        self.files = 0
        self.mix = FileMix()

    def mark(mut self, path: String, exists: Bool):
        """Records that `path` now exists (or no longer does), if it is a
        file that decides the tooling, the packaging or the version."""
        var kind = recipe_kind(path)
        if kind == "rattler":
            self.rattler += 1 if exists else -1
            return  # the packaging changes, nothing else
        if kind == "conda-build":
            self.conda_build += 1 if exists else -1
            return
        if path == "pixi.toml":
            self.f.pixi_toml = exists
        elif path == "pixi.lock":
            self.f.pixi_lock = exists
        elif path == "mojoproject.toml":
            self.f.mojoproject = exists
        elif path == "magic.lock":
            self.f.magic_lock = exists
        elif path == "uv.lock":
            self.f.uv_lock = exists
        elif path == "poetry.lock":
            self.f.poetry_lock = exists
        elif path == "pdm.lock":
            self.f.pdm_lock = exists
        elif is_python_manifest(path):
            var at = -1
            for i in range(len(self.py_files)):
                if self.py_files[i] == path:
                    at = i
            if exists and at < 0:
                self.py_files.append(path)
            elif not exists and at >= 0:
                _ = self.py_files.pop(at)
            self.py_touched = True
        elif is_bazel_file(path):
            self.f.bazel = exists
            return  # the tooling changes, the Mojo version doesn't
        else:
            return
        self.touched = True

    def any_file(self) -> Bool:
        """Whether any file that can name the version is left."""
        return (
            self.f.pixi_toml or self.f.pixi_lock or self.f.mojoproject
            or self.f.magic_lock or self.f.uv_lock or self.f.poetry_lock
            or self.f.pdm_lock or len(self.py_files) > 0
        )


def _read_python(dir: String, sha: String, mut st: _State) raises:
    """Reads the Python manifests at `sha` again: whether one depends on
    Mojo (`py_mojo`), and the `pyproject.toml`'s `[tool.*]` tables."""
    st.f.py_mojo = False
    var pyproject = False
    for p in st.py_files:
        var text = _show(dir, sha, p)
        if p == "pyproject.toml":
            pyproject = True
            pyproject_tables(text, st.f)
        if names_mojo_pkg(p, text):
            st.f.py_mojo = True
    if not pyproject:
        pyproject_tables(String(), st.f)


def _version(dir: String, sha: String, st: _State) raises -> Tuple[String, String]:
    """The Mojo version at `sha` and the file it came from, or two empty
    strings. Lock files win over manifests: a lock names the version that
    was actually resolved, a manifest only the range asked for; and
    `pixi.lock` wins over a `magic.lock` left from before a move to pixi
    (`versions.lock_files`). Python files count only when a Python manifest
    depends on Mojo (`py_mojo`), and the `pyproject.toml` also when pixi
    reads it."""
    var locks = List[String]()
    if st.f.pixi_lock:
        locks.append("pixi.lock")
    if st.f.magic_lock:
        locks.append("magic.lock")
    for l in locks:
        var v = lock_version(_show(dir, sha, l))
        if v.byte_length() > 0:
            return (v^, l)
    var pylocks = List[String]()
    if st.f.py_mojo:
        if st.f.uv_lock:
            pylocks.append("uv.lock")
        if st.f.poetry_lock:
            pylocks.append("poetry.lock")
        if st.f.pdm_lock:
            pylocks.append("pdm.lock")
    for l in pylocks:
        var v = pylock_version(_show(dir, sha, l))
        if v.byte_length() > 0:
            return (v^, l)
    var manifests = List[String]()
    if st.f.pixi_toml:
        manifests.append("pixi.toml")
    if st.f.mojoproject:
        manifests.append("mojoproject.toml")
    for m in manifests:
        var v = manifest_version(_show(dir, sha, m))
        if v.byte_length() > 0:
            return (v^, m)
    if st.f.py_mojo or st.f.pyproject_pixi:
        for p in st.py_files:
            if p != "pyproject.toml" and not st.f.py_mojo:
                continue
            # A pixi or poetry table line (`mojo = ">=1.2"`), else a PEP 508
            # pin (`"mojo>=1.2.0,<1.3"`).
            var text = _show(dir, sha, p)
            var v = manifest_version(text) if p == "pyproject.toml" else String()
            if v.byte_length() == 0 or v == "*":
                var pin = pin_version(text)
                if pin.byte_length() > 0:
                    v = pin^
            if v.byte_length() > 0:
                return (v^, p)
    return (String(), String())


def _finish(repo: String, dir: String, mut st: _State, mut out: History) raises:
    """Closes the commit `st` is at: one row, and any migrations."""
    if st.sha.byte_length() == 0:
        return
    if st.py_touched:
        var sha = st.sha
        _read_python(dir, sha, st)
    var new_tool = tooling(st.f)
    var new_pack = packaging(st.rattler > 0, st.conda_build > 0)
    if st.touched:
        # Only a commit that touches a manifest costs `git show`s. A manifest
        # that names no version (yet) leaves the earlier version standing; the
        # version is cleared only when no manifest or lock file is left.
        var v = _version(dir, st.sha, st)
        if v[0].byte_length() > 0 or not st.any_file():
            if v[0] != st.version:
                out.migrations.append(
                    MigrationRow(repo, st.sha, st.at, "mojo_version", st.version, v[0])
                )
            st.version = v[0]
            st.source = v[1]
    if new_tool != st.tool:
        out.migrations.append(
            MigrationRow(repo, st.sha, st.at, "tooling", st.tool, new_tool)
        )
        st.tool = new_tool
    if new_pack != st.pack:
        out.migrations.append(
            MigrationRow(repo, st.sha, st.at, "packaging", st.pack, new_pack)
        )
        st.pack = new_pack
    out.commits.append(
        CommitRow(
            repo, st.sha, st.at, st.seq, st.lines, st.files, st.tool,
            st.version, st.source, st.pack, st.subject, st.mix.encode(),
        )
    )
    st.mix = FileMix()
    st.seq += 1
    st.touched = False
    st.py_touched = False


def _path_of(line: StringSpan) -> String:
    """The path in a `--summary` line: ` create mode 100644 <path>`."""
    var s = String(line)
    var at = 0
    var spaces = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord(" ")):
            spaces += 1
            if spaces == 4:
                at = i + 1
                break
    return String(s[byte=at:])


def _parse_log(repo: String, dir: String, log: String, mut out: History) raises:
    """Turns the `git log` of `_read_history` into `out.commits` and
    `out.migrations`. Per commit git prints the `@@sha time subject` header, then
    its `--numstat` lines (`added<TAB>deleted<TAB>path`), then its
    `--summary` lines (` create mode ...` / ` delete mode ...`). A commit is
    therefore complete only when the next header (or the end) arrives, which
    is when `_finish` writes its row."""
    var st = _State()
    for line in log.split("\n"):
        if line.startswith("@@"):
            _finish(repo, dir, st, out)
            # `@@<sha> <time> <subject>`: the subject may have spaces of its own.
            var head = String(line[byte=2:])
            var parts = head.split(" ", 2)
            st.sha = String(parts[0])
            st.at = Int64(Int(parts[1])) * 1_000_000 if len(parts) > 1 else 0
            st.subject = cut_subject(parts[2]) if len(parts) > 2 else String()
            continue
        # Files are counted from the summary (with `--no-renames` a rename is
        # a delete plus a create) and lines from numstat, so both follow the
        # running totals without ever listing a tree.
        if line.startswith(" create mode "):
            st.mix.created()
            var p = _path_of(line)
            if is_mojo_file(p):
                st.files += 1
            st.mark(p, True)
            continue
        if line.startswith(" delete mode "):
            var p = _path_of(line)
            if is_mojo_file(p):
                st.files -= 1
            st.mark(p, False)
            continue
        var cols = line.split("\t")
        if len(cols) == 3:
            var p = String(cols[2])
            # Binary files print "-" for both counts.
            var plus = Int64(Int(cols[0])) if String(cols[0]) != "-" else Int64(0)
            var minus = Int64(Int(cols[1])) if String(cols[1]) != "-" else Int64(0)
            st.mix.add(p, plus, minus)
            if is_mojo_file(p) and String(cols[0]) != "-":
                st.lines += Int64(Int(cols[0])) - Int64(Int(cols[1]))
            if is_tool_file(p):
                st.touched = True
                if is_python_manifest(p):
                    st.py_touched = True
    _finish(repo, dir, st, out)


def read_history(repo: String) raises -> History:
    """Clones one repository from GitHub on a worker and reads its commits,
    version changes and tags.
    Errors (a repository gone, a clone that failed, history that doesn't
    parse) come back in `error`, so one bad repository doesn't fail the rest
    of its run."""
    var out = History.empty(repo)
    try:
        _read_history(repo, out)
    except e:
        if safe_repo(repo):
            try:
                remove_tree(_clone_dir(repo))
            except:
                pass
        out = History.empty(repo)
        out.error = String("reading its history: ", e)
    return out^


def _add_authors(repo: String, dir: String, mut out: History) raises:
    """Appends the clone's contributors by month to `out.authors`."""
    for ref a in read_authors(repo, dir):
        out.authors.append(a.copy())


def read_tags_and_authors(repo: String) raises -> History:
    """Reads only one repository's git tags and contributors on a worker,
    from a clone without file contents.
    No commits: a bare clone with `--filter=blob:none`; errors come back in
    `error`."""
    var out = History.empty(repo)
    if not safe_repo(repo):
        out.error = String("not a repository name: ", repo)
        return out^
    var dir = _clone_dir(repo)
    try:
        var clone = git_clone(repo, dir, ["--filter=blob:none"])
        if clone[0] != 0:
            out.error = String("git clone failed: ", clone[1].strip())
        else:
            _read_tags(repo, dir, out)
            _add_authors(repo, dir, out)
    except e:
        out = History.empty(repo)
        out.error = String("reading its tags and authors: ", e)
    try:
        remove_tree(dir)
    except:
        pass
    return out^


def _workdir() -> String:
    """Where clones go: each is deleted after it is read."""
    return getenv("MOJO_HISTORY_WORKDIR", String(getenv("TMPDIR", "/tmp"), "/mojo_history"))


def _clone_dir(repo: String) -> String:
    """`owner/name` as one directory name, `owner__name.git`."""
    return String(_workdir(), "/", repo.replace("/", "__"), ".git")


def _read_history(repo: String, mut out: History) raises:
    """`read_history` without the error handling: failures that git reports
    are put in `out.error`. The clone is bare (no checkout: manifests are read
    with `git show`) and is removed before returning."""
    if not safe_repo(repo):
        out.error = String("not a repository name: ", repo)
        return
    var dir = _clone_dir(repo)
    var clone = git_clone(repo, dir, List[String]())
    if clone[0] != 0:
        out.error = String("git clone failed: ", clone[1].strip())
        remove_tree(dir)
        return
    # `--first-parent --diff-merges=first-parent` follows the default branch
    # only, with a merge shown as its diff against the first parent: a pull
    # request counts once, and the lines add up to the branch's real size.
    # `--reverse` puts the oldest commit first so the totals accumulate.
    var log = git([
        "-C", dir, "-c", "core.quotepath=off", "log", "--first-parent",
        "--reverse", "--no-renames", "--diff-merges=first-parent",
        String("--format=", LOG_FORMAT), "--numstat", "--summary", "HEAD",
    ])
    if log[0] != 0:
        out.error = String("git log failed: ", log[1].strip())
    else:
        try:
            _parse_log(repo, dir, log[1], out)
            try:
                _read_tags(repo, dir, out)
            except:
                pass  # the history stands without its tags
            try:
                _add_authors(repo, dir, out)
            except:
                pass  # and without its contributors
        except e:
            out.error = String("reading its git log: ", e)
    remove_tree(dir)
