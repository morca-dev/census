"""The Mojo version a repository states at its HEAD, from files that
`history.read_history` doesn't read, and an estimate by date.

`read_head_version` clones the repository bare without file contents
(`--filter=blob:none`: every commit and tree, no blobs), lists HEAD's files
and reads the few that can name a version: lock file and manifest (as the
history does), a version file, CI workflows, Dockerfiles and dev container
files, READMEs. `versions.pick_version` chooses by precedence and
`mojo_releases.estimate_version` turns the date of the last commit that touched
a Mojo file into the release current then, kept apart as the estimate.
`modular/modular` is cloned shallow (it is gigabytes) and states its own
version in `Mojo/pixi.lock`, source `repo`.

The same read collects the dependencies HEAD's manifests declare and the
names the repository publishes itself under (`deps.manifest_deps`: the
root `pixi.toml`, `mojoproject.toml`, `pyproject.toml`, `requirements*.txt`
and a `recipe.yaml` of its own), the rows of `mojo.repo_deps`.
"""


from deps import Dep, declared_count, dedupe, encode_deps, is_recipe, manifest_deps
from command import STDERR_DROP, TIMED_OUT, git, remove_tree
from history import _workdir, git_clone, git_net, git_timeout_ms, safe_repo
from mojo_releases import estimate_version
from versions import (
    SOURCE_DATE,
    SOURCE_REPO,
    file_version,
    lock_files,
    lock_version,
    manifest_version,
    pick_version,
    pin_version,
    pylock_version,
    readme_version,
    script_version,
    usable,
)

comptime MAX_FILES = 12
"""Files read per kind (workflows, Dockerfiles, ...)."""
comptime MAX_BYTES = 262144
"""Bytes read of a file."""


@fieldwise_init
struct HeadVersion(Copyable, Movable):
    """One row of `mojo.repo_versions`, and what the `read_head_version`
    task returns. A plain struct so dista can send it by reflection."""

    var repo: String
    var error: String
    """Empty when HEAD was read."""
    var head_sha: String
    var version: String
    """Detected, by precedence; empty for none."""
    var source: String
    var file: String
    """The file the version was read from."""
    var estimate: String
    """The release current at `last_mojo_commit` (microseconds), by date."""
    var estimate_source: String
    var last_mojo_commit: Int64
    var read_at: Int64
    var declared_deps: Int64
    """Distinct dependencies HEAD's manifests declare, the toolchain left
    out (`deps.declared_count`); -1 (null in the table) for a row read
    before dependencies were."""
    var deps: String
    """The rows of `mojo.repo_deps` for this repository, as
    `deps.encode_deps` writes them; not a column of `mojo.repo_versions`
    (and empty in rows read back from it)."""

    @staticmethod
    def empty(repo: String) -> Self:
        """A row with nothing found and no error."""
        return Self(
            repo, String(), String(), String(), String(), String(), String(),
            String(), 0, 0, -1, String(),
        )


def _base(path: String) -> String:
    """The last component of `path`."""
    var slash = path.rfind("/").or_else(-1)
    if slash < 0:
        return path
    return String(path[byte = slash + 1 :])


struct Candidates(Copyable, Movable):
    """HEAD's files that can name a version, by kind."""

    var lock: List[String]
    var manifest: List[String]
    var file: List[String]
    var ci: List[String]
    var docker: List[String]
    var readme: List[String]
    var deps: List[String]
    """The files dependencies are read from: the manifests and the
    repository's own recipe (`deps.is_recipe`)."""

    def __init__(out self):
        self.lock = List[String]()
        self.manifest = List[String]()
        self.file = List[String]()
        self.ci = List[String]()
        self.docker = List[String]()
        self.readme = List[String]()
        self.deps = List[String]()


def classify(paths: List[String]) -> Candidates:
    """Sorts a repository's file list into the kinds `read_head_version`
    reads. A kind keeps `MAX_FILES` files, shortest paths first."""
    # Lock files, manifests and version files count only at the repository
    # root (`root`): a nested `pixi.lock` belongs to some example or
    # dependency, not to the project. CI and Docker files can live deeper.
    var c = Candidates()
    var locks = lock_files()
    var found = List[Bool](length=len(locks), fill=False)
    for p in paths:
        var base = _base(p)
        var low = base.lower()
        var root = base == p
        var lock = -1
        if root:
            for i in range(len(locks)):
                if p == locks[i]:
                    lock = i
        if lock >= 0:
            found[lock] = True
        elif root and (
            p == "pixi.toml" or p == "mojoproject.toml" or p == "pyproject.toml"
            or p == "requirements.txt" or p == "requirements-dev.txt"
        ):
            c.manifest.append(p)
            c.deps.append(p)
        elif is_recipe(p):
            c.deps.append(p)
        elif root and (
            p == ".mojoversion" or p == ".mojo-version" or p == ".tool-versions"
            or p == "mojo-version" or p == "MOJO_VERSION" or p == "mojo_version.txt"
        ):
            c.file.append(p)
        elif (p.startswith(".github/workflows/") and (p.endswith(".yml") or p.endswith(".yaml"))) \
            or p == ".gitlab-ci.yml" or p == ".circleci/config.yml" \
            or p == "azure-pipelines.yml" or p == "Makefile" or p == "makefile" or p == "justfile":
            c.ci.append(p)
        elif low.startswith("dockerfile") or low.endswith(".dockerfile") \
            or p.startswith(".devcontainer/") and (low.endswith(".json") or low.startswith("dockerfile")) \
            or root and low.startswith("docker-compose") and (low.endswith(".yml") or low.endswith(".yaml")) \
            or p == ".devcontainer.json":
            c.docker.append(p)
        elif root and low.startswith("readme"):
            c.readme.append(p)
    # The lock files in `lock_files` order, not the tree's (alphabetical):
    # `pixi.lock` is read before a `magic.lock` left beside it.
    for i in range(len(locks)):
        if found[i]:
            c.lock.append(locks[i])
    _trim(c.ci)
    _trim(c.docker)
    _trim(c.readme)
    return c^


def _trim(mut paths: List[String]):
    """The first `MAX_FILES` by length, then name: the shortest paths are
    the top-level files, which are the most likely to state the project's
    own version."""
    for i in range(1, len(paths)):
        var j = i
        while j > 0 and (
            paths[j - 1].byte_length() > paths[j].byte_length()
            or (paths[j - 1].byte_length() == paths[j].byte_length() and paths[j - 1] > paths[j])
        ):
            paths.swap_elements(j - 1, j)
            j -= 1
    while len(paths) > MAX_FILES:
        _ = paths.pop()


def _show(dir: String, rev: String, path: String) raises -> String:
    """`path` at `rev`, cut to `MAX_BYTES`, or "" if there isn't one. In a
    blobless clone this is what fetches the blob, one file at a time, so it
    gets git's stall detector and `GIT_TIMEOUT_SECONDS` as a clone does."""
    var args = git_net()
    for a in ["-C", dir, "show", String(rev, ":", path)]:
        args.append(a)
    var r = git(args, git_timeout_ms(), STDERR_DROP, MAX_BYTES)
    if r[0] == TIMED_OUT:
        # Not "no such file": the repository fails, and keeps its old row.
        raise Error("git show ", path, ": ", r[1])
    if r[0] != 0:
        return String()
    return r[1]


def _text(dir: String, path: String, mut cache: Dict[String, String]) raises -> String:
    """`_show` of `path` at HEAD, fetched once: a manifest is read for its
    version and again for its dependencies."""
    if path in cache:
        return cache[path]
    var text = _show(dir, "HEAD", path)
    cache[path] = text
    return text^


def _first(
    dir: String, paths: List[String], kind: String, mut file: String,
    mut cache: Dict[String, String],
) raises -> String:
    """The first version `kind` ('lock', 'manifest', 'file', 'script' or
    'readme') reads from `paths`; `file` is set to its path."""
    for p in paths:
        var text = _text(dir, p, cache)
        if text.byte_length() == 0:
            continue
        # `pyproject.toml` and `requirements.txt` are in the manifest kind
        # too, and they aren't pixi manifests: when `manifest_version` finds
        # nothing, `pin_version` reads their `mojo==...` pins.
        var v: String
        if kind == "lock":
            # A conda lock (`.../mojo-1.2.0-....conda`), else a Python one
            # (`name = "mojo"`, `version = "1.2.0"`).
            v = lock_version(text)
            if not usable(v):
                v = pylock_version(text)
        elif kind == "manifest":
            v = manifest_version(text)
            if not usable(v):
                v = pin_version(text)
        elif kind == "file":
            v = file_version(text)
        elif kind == "readme":
            v = readme_version(text)
        else:
            v = script_version(text)
        if usable(v):
            file = p
            return v^
    return String()


def pick_head(
    lock: String, manifest: String, file: String, ci: String, docker: String,
    readme: String,
) -> Tuple[String, String]:
    """`versions.pick_version` (the order of precedence is kept there)."""
    return pick_version(lock, manifest, file, ci, docker, readme)


def read_head_version(repo: String) raises -> HeadVersion:
    """Clones one repository on a worker and reads the Mojo version and
    dependencies its latest commit states.
    Errors (a repository gone, a failed clone) come back in `error`, so one
    bad repository doesn't fail the rest of its run."""
    var out = HeadVersion.empty(repo)
    var dir: String
    try:
        if not safe_repo(repo):
            out.error = String("not a repository name: ", repo)
            return out^
        dir = String(_workdir(), "/", repo.replace("/", "__"), ".head.git")
        _read(repo, dir, out)
    except e:
        var keep = out.repo
        out = HeadVersion.empty(keep)
        out.error = String("reading its HEAD: ", e)
    if dir.byte_length() > 0:
        try:
            remove_tree(dir)
        except:
            pass
    return out^


def _read(repo: String, dir: String, mut out: HeadVersion) raises:
    """Fills `out` from a fresh bare clone in `dir`; git failures go in
    `out.error`. The caller removes the clone."""
    var shallow = repo == "modular/modular"
    var flags: List[String] = ["--no-tags", "--filter=blob:none"]
    if shallow:
        flags.append("--depth")
        flags.append("1")
    var clone = git_clone(repo, dir, flags)
    if clone[0] != 0:
        out.error = String("git clone failed: ", clone[1].strip())
        return
    var sha = git(["-C", dir, "rev-parse", "HEAD"])
    out.head_sha = String(sha[1].strip())
    var tree = git(["-C", dir, "-c", "core.quotepath=off", "ls-tree", "-r", "--name-only", "HEAD"])
    if tree[0] != 0:
        out.error = String("git ls-tree failed: ", tree[1].strip())
        return
    var paths = List[String]()
    for line in tree[1].split("\n"):
        if line.byte_length() > 0:
            paths.append(String(line))
    var c = classify(paths)
    # Each kind is read on its own, first file that names a version wins
    # (`_first`), and `pick_head` then chooses between the kinds.
    var f_lock = String()
    var f_manifest = String()
    var f_file = String()
    var f_ci = String()
    var f_docker = String()
    var f_readme = String()
    var cache = Dict[String, String]()
    var lock = _first(dir, c.lock, "lock", f_lock, cache)
    var manifest = _first(dir, c.manifest, "manifest", f_manifest, cache)
    var vfile = _first(dir, c.file, "file", f_file, cache)
    var ci = _first(dir, c.ci, "script", f_ci, cache)
    var docker = _first(dir, c.docker, "script", f_docker, cache)
    var readme = _first(dir, c.readme, "readme", f_readme, cache)
    # Every manifest is read for dependencies, not only the first that names
    # a version: a `pyproject.toml` beside the `pixi.toml` adds its own.
    var rows = List[Dep]()
    for p in c.deps:
        rows.extend(manifest_deps(p, _text(dir, p, cache)))
    var unique = dedupe(rows)
    out.declared_deps = Int64(declared_count(unique))
    out.deps = encode_deps(unique)
    var picked = pick_head(lock, manifest, vfile, ci, docker, readme)
    out.version = picked[0]
    out.source = picked[1]
    if picked[1] == "lock":
        out.file = f_lock
    elif picked[1] == "manifest":
        out.file = f_manifest
    elif picked[1] == "file":
        out.file = f_file
    elif picked[1] == "ci":
        out.file = f_ci
    elif picked[1] == "docker":
        out.file = f_docker
    elif picked[1] == "readme":
        out.file = f_readme
    if repo == "modular/modular":
        # The repository states its own version in the lock file of Mojo/.
        var own = lock_version(_show(dir, "HEAD", "Mojo/pixi.lock"))
        if usable(own):
            out.version = own^
            out.source = String(SOURCE_REPO)
            out.file = String("Mojo/pixi.lock")
    # The estimate by date uses the last commit that touched a Mojo file,
    # not HEAD: a project that stopped writing Mojo in 2024 was built with
    # that year's release even if its README was edited since. (A shallow
    # clone has only HEAD, so modular/modular falls back to HEAD's date.)
    var last = git(
        ["-C", dir, "log", "-1", "--format=%ct", "HEAD", "--", "*.mojo", "*.🔥"],
        stderr=STDERR_DROP,
    )
    var secs: Int64
    try:
        secs = Int64(Int(String(last[1].strip())))
    except:
        secs = 0
    if secs == 0 and shallow:
        var head = git(["-C", dir, "log", "-1", "--format=%ct", "HEAD"])
        try:
            secs = Int64(Int(String(head[1].strip())))
        except:
            secs = 0
    out.last_mojo_commit = secs * 1_000_000
    out.estimate = estimate_version(out.last_mojo_commit)
    if out.estimate.byte_length() > 0:
        out.estimate_source = String(SOURCE_DATE)
