"""What kinds of files a commit changed, and how much of each (#121).

`mojo_history` adds each `--numstat` line of a commit (`FileMix.add`) and
each file it creates (`FileMix.created`), and `mojo.commits` keeps the
result as `changes` (`FileMix.encode`): the lines added plus deleted in
each kind of file, the lines in test files of any language, and the counts
of files, new files, lines added and lines deleted. `committype` reads the
mix back (`FileMix.decode`) to type the commits a subject alone can't.

A file's kind is from its path alone (`file_kind`): CI before lock files
before Mojo (a Mojo file with `test` in its path is a Mojo test) before
Python before docs before config, else `other`.
"""

from std.math import log1p

comptime KIND_MOJO = 0
comptime KIND_MOJO_TEST = 1
comptime KIND_PYTHON = 2
comptime KIND_DOCS = 3
comptime KIND_CONFIG = 4
comptime KIND_LOCK = 5
comptime KIND_CI = 6
comptime KIND_OTHER = 7
comptime KINDS = 8

comptime ENCODING = "1"
"""The first field of `encode`: bumped if the fields change."""


def _ends(s: String, ends: List[String]) -> Bool:
    for ref e in ends:
        if s.endswith(e):
            return True
    return False


def file_kind(path: String) -> Int:
    """The kind of the file at `path` (a `KIND_*`)."""
    var q = path.lower()
    var slash = q.rfind("/").or_else(-1)
    var base = String(q[byte = slash + 1 :]) if slash >= 0 else q
    if (
        q.startswith(".github/") or q.startswith(".gitlab") or q.startswith(".circleci/")
        or base == ".gitlab-ci.yml" or base == ".pre-commit-config.yaml"
        or base == ".travis.yml" or base == "azure-pipelines.yml" or base == "jenkinsfile"
    ):
        return KIND_CI
    if base.endswith(".lock") or base == "package-lock.json" or base == "pnpm-lock.yaml" or base == "yarn.lock":
        return KIND_LOCK
    if base.endswith(".mojo") or base.endswith(".🔥"):
        return KIND_MOJO_TEST if "test" in q else KIND_MOJO
    if base.endswith(".py") or base.endswith(".ipynb") or base.endswith(".pyi"):
        return KIND_PYTHON
    if (
        _ends(base, [".md", ".rst", ".txt", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".html", ".pdf"])
        or base.startswith("license") or base.startswith("readme")
        or q.startswith("docs/") or "/docs/" in q
    ):
        return KIND_DOCS
    if (
        _ends(base, [".toml", ".yaml", ".yml", ".json", ".cfg", ".ini", ".env"])
        or base.startswith(".") or base == "makefile" or base == "dockerfile"
        or base == "cmakelists.txt"
    ):
        return KIND_CONFIG
    return KIND_OTHER


def _is_test(path: String) -> Bool:
    """A test file of Mojo or Python: `test` in its path."""
    var k = file_kind(path)
    return (k == KIND_MOJO_TEST or k == KIND_PYTHON) and "test" in path.lower()


struct FileMix(Copyable, Movable):
    var lines: List[Int64]
    """Lines added plus deleted, by kind (`KIND_*`)."""
    var test_lines: Int64
    """Of those, in test files of Mojo or Python."""
    var files: Int64
    var new_files: Int64
    var added: Int64
    var deleted: Int64

    def __init__(out self):
        self.lines = List[Int64](length=KINDS, fill=0)
        self.test_lines = 0
        self.files = 0
        self.new_files = 0
        self.added = 0
        self.deleted = 0

    def add(mut self, path: String, added: Int64, deleted: Int64):
        """One `--numstat` line (a binary file's `-` counts as 0)."""
        self.lines[file_kind(path)] += added + deleted
        if _is_test(path):
            self.test_lines += added + deleted
        self.files += 1
        self.added += added
        self.deleted += deleted

    def created(mut self):
        """One ` create mode` line of `--summary`."""
        self.new_files += 1

    def total(self) -> Int64:
        var n = Int64(0)
        for x in self.lines:
            n += x
        return n

    def share(self, kind: Int) -> Float64:
        var t = self.total()
        return Float64(self.lines[kind]) / Float64(t) if t > 0 else 0.0

    def test_share(self) -> Float64:
        var t = self.total()
        return Float64(self.test_lines) / Float64(t) if t > 0 else 0.0

    def encode(self) -> String:
        """`1 <8 kinds' lines> <test lines> <files> <new> <added> <deleted>`."""
        var out = String(ENCODING)
        for x in self.lines:
            out.write(" ", x)
        out.write(" ", self.test_lines, " ", self.files, " ", self.new_files, " ", self.added, " ", self.deleted)
        return out^

    @staticmethod
    def decode(s: String) -> Optional[FileMix]:
        """The mix `encode` wrote, or None for "" or another encoding."""
        var parts = s.split(" ")
        if len(parts) != KINDS + 6 or String(parts[0]) != ENCODING:
            return None
        var m = FileMix()
        try:
            for k in range(KINDS):
                m.lines[k] = Int64(Int(parts[k + 1]))
            m.test_lines = Int64(Int(parts[KINDS + 1]))
            m.files = Int64(Int(parts[KINDS + 2]))
            m.new_files = Int64(Int(parts[KINDS + 3]))
            m.added = Int64(Int(parts[KINDS + 4]))
            m.deleted = Int64(Int(parts[KINDS + 5]))
        except:
            return None
        return m^

    def features(self) -> List[Float64]:
        """What `committype` compares commits by: each kind's share of the
        lines changed, then the size (log lines, log files), the share of
        files that are new and the share of changed lines deleted."""
        var out = List[Float64]()
        for k in range(KINDS):
            out.append(self.share(k))
        var ch = self.added + self.deleted
        out.append(log1p(Float64(ch)) / 10)
        out.append(Float64(self.new_files) / Float64(max(self.files, 1)))
        out.append(log1p(Float64(self.files)) / 5)
        out.append(Float64(self.deleted) / Float64(max(ch, 1)))
        return out^
