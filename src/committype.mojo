"""Commit types from commit subjects, by rules (#121): what a commit did,
for the repo page's commits and the Migrations page.

`commit_type` reads the subject the way a person skims it:

0. Leading tags go (`[skip ci] Merge ...`, `[gpt2] Add ...`), unless one
   names a type (`[release]`, `[doc]`); `[pre-commit.ci]` and dependabot
   are `chore`.
1. `Merge pull request ...` / `Merge branch ...` is `merge`.
2. A conventional-commit prefix (`fix:`, `feat(api):`, `docs!:`, also
   `toolchain:`, `accel:`, `repair:`, `readme:`) names the type
   (`_conventional`). A prefix it doesn't know (`migrate:`, `ffi:`) still
   counts for steps 3 and 4.
3. A commit that changed the Mojo version (it has a `mojo_version` row in
   mojo.migrations), or whose subject says it moved to a Mojo version
   (`update to Mojo 24.3`, `bump nightly to dev2026080206`), is `version`,
   or `migration` when it also says it adapted code (`refresh`, `fix`,
   `port`, `adapt`, `rework`; `lock mojo 1.2.0..., refresh MOJO_NOTES`).
4. A subject about migrating (`migrate`, `deprecated`, `port to Mojo`) is
   `migration`: work that follows a version change.
5. Otherwise the first word (`Fix`, `Added`, `Refactor`, `Update README`,
   `Initial commit`), else `other`.

6. A commit the rules leave `other` whose files are known (`Point.changes`,
   `filemix`) gets the main type its `VOTERS` nearest labelled commits
   (`commit_examples`) vote for, by what kinds of files they changed and
   how much, when that type has at least `VOTE_SHARE` of the vote; else it
   stays `other`.

Secondary types (`typed_commits`): `test` or `docs` when test files or docs
are at least `SECONDARY_SHARE` of the lines changed (and not nearly all of
them), unless that is the main type.

About a third of subjects carry a conventional prefix and the first word
labels another quarter. On 1,546 subjects from 80 sampled census repos
(version changes left out), the second rules (`COMMIT_TYPES_VERSION` 2)
left 43% `other`, down from 49%. Those are for a nearest-neighbour labeller over subject
embeddings, as the categories (#113) do it, once 100 hand-labelled commits
can check it.
"""

from committype_examples import commit_examples
from filemix import FileMix
from model import Migration, Point


comptime COMMIT_TYPES_VERSION = 4
"""Bumped when the rules change, so the console can say which it used."""


def commit_type_keys() -> List[String]:
    """Every type, in the order the console lists them."""
    return [
        "feature", "fix", "version", "migration", "refactor", "perf", "docs",
        "test", "chore", "merge", "other",
    ]


def commit_type_title(t: String) -> String:
    if t == "feature":
        return "Feature"
    if t == "fix":
        return "Fix"
    if t == "version":
        return "Mojo version"
    if t == "migration":
        return "Migration"
    if t == "refactor":
        return "Refactor"
    if t == "perf":
        return "Performance"
    if t == "docs":
        return "Docs"
    if t == "test":
        return "Tests"
    if t == "chore":
        return "Build and chores"
    if t == "merge":
        return "Merge"
    return "Other"


def _conventional(t: String) -> String:
    """The type a conventional-commit prefix names; empty for one it doesn't
    know."""
    if t == "feat" or t == "feature" or t == "add":
        return "feature"
    if t == "fix" or t == "bugfix" or t == "hotfix":
        return "fix"
    if t == "docs" or t == "doc" or t == "readme":
        return "docs"
    if t == "test" or t == "tests":
        return "test"
    if t == "refactor" or t == "style":
        return "refactor"
    if t == "perf" or t == "bench" or t == "accel" or t == "speed" or t == "optimize":
        return "perf"
    if t == "repair" or t == "bug":
        return "fix"
    if (
        t == "chore" or t == "build" or t == "ci" or t == "release"
        or t == "deps" or t == "revert" or t == "toolchain"
    ):
        return "chore"
    return String()


def _first_word(w: String) -> String:
    """The type a subject's first word names; empty for none."""
    if (
        w == "fix" or w == "fixed" or w == "fixes" or w == "fixing" or w == "bugfix"
        or w == "bugfixes" or w == "hotfix" or w == "typo" or w == "correct" or w == "corrected"
        or w == "resolve"
    ):
        return "fix"
    if (
        w == "add" or w == "added" or w == "adds" or w == "adding" or w == "implement"
        or w == "implemented" or w == "create" or w == "created" or w == "introduce"
        or w == "support" or w == "enable" or w == "new" or w == "enhance"
        or w == "enhanced" or w == "enhancing"
    ):
        return "feature"
    if (
        w == "refactor" or w == "refactored" or w == "cleanup" or w == "clean"
        or w == "rename" or w == "renamed" or w == "simplify" or w == "move"
        or w == "moved" or w == "restructure" or w == "reorganize" or w == "format"
        or w == "remove" or w == "removed" or w == "delete" or w == "deleted"
    ):
        return "refactor"
    if w == "optimize" or w == "optimized" or w == "speed" or w == "speedup":
        return "perf"
    if w == "docs" or w == "doc" or w == "readme" or w == "document" or w == "documentation":
        return "docs"
    if w == "test" or w == "tests":
        return "test"
    if w == "revert" or w == "release" or w == "bump" or w == "bumped":
        return "chore"
    return String()


def _is_letter(c: UInt8) -> Bool:
    return (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))


def _is_word_byte(c: UInt8) -> Bool:
    """Letters, digits, `.` and `-`: `1.2.0.dev2026`, `mojo-compiler` stay
    one word each."""
    return (
        _is_letter(c) or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord(".")) or c == UInt8(ord("-")) or c == UInt8(ord("_"))
    )


def words(lower: String) -> List[String]:
    """The words of a lowercased subject, without a trailing `.`."""
    var out = List[String]()
    var b = lower.as_bytes()
    var i = 0
    while i < len(b):
        while i < len(b) and not _is_word_byte(b[i]):
            i += 1
        var start = i
        while i < len(b) and _is_word_byte(b[i]):
            i += 1
        var end = i
        while end > start and (b[end - 1] == UInt8(ord(".")) or b[end - 1] == UInt8(ord("-"))):
            end -= 1
        if end > start:
            out.append(String(lower[byte=start:end]))
    return out^


def _is_mojo(w: String) -> Bool:
    return (
        w == "mojo" or w == "max" or w == "magic" or w == "nightly" or w == "modular"
        or w == "mojo-compiler"
    )


def _is_version_number(w: String) -> Bool:
    """`24.3`, `1.2.0.dev2026101905`, `v25.1`, `dev2026080206`."""
    var b = w.as_bytes()
    if len(b) == 0:
        return False
    var at = 1 if b[0] == UInt8(ord("v")) else 0
    if w.startswith("dev20"):
        return True
    if at >= len(b) or b[at] < UInt8(ord("0")) or b[at] > UInt8(ord("9")):
        return False
    return "." in w


def _is_bump(w: String) -> Bool:
    return (
        w == "bump" or w == "bumped" or w == "upgrade" or w == "upgraded"
        or w == "update" or w == "updated" or w == "updates" or w == "pin" or w == "pinned"
        or w == "switch" or w == "lock" or w == "locked"
    )


def _says_version(ws: List[String]) -> Bool:
    """A bump word and a Mojo version: `update to 26.2`, `upgrade Mojo to
    version 24.1.0`, `update mojo`, `bump nightly to dev2026080206`."""
    var bump = False
    for ref w in ws:
        if _is_bump(w):
            bump = True
    for i in range(len(ws) if bump else 0):
        if _is_mojo(ws[i]):
            # `update mojo`, `upgrade mojo and torch`: right after the bump word.
            if i > 0 and _is_bump(ws[i - 1]):
                return True
            # `bump to latest Mojo nightly`, `upgrade to the new mojo`.
            if i > 0 and (ws[i - 1] == "latest" or ws[i - 1] == "new" or ws[i - 1] == "newest"):
                return True
            for j in range(i + 1, min(i + 4, len(ws))):
                if _is_version_number(ws[j]) or ws[j] == "version" or ws[j] == "latest":
                    return True
    # `update to 26.2`, `24.2 updates`: a Modular release number with a bump
    # word, without the word Mojo.
    for i in range(len(ws) if bump else 0):
        if _is_release(ws[i]):
            return True
    return False


def _is_release(w: String) -> Bool:
    """A Modular release number: `24.2`, `v25.1.0`, `26.1.0.dev2026...`,
    `dev2026080206` (not `1.2.0`, which many libraries use too)."""
    var v = String(w[byte=1:]) if w.startswith("v") else w
    if not _is_version_number(v):
        return False
    return v.startswith("24.") or v.startswith("25.") or v.startswith("26.") or v.startswith("dev20")


def _says_migration(ws: List[String]) -> Bool:
    for i in range(len(ws)):
        ref w = ws[i]
        if w.startswith("migrat") or w.startswith("deprecat"):
            return True
        if (w == "port" or w == "ported") and i + 2 < len(ws) and ws[i + 1] == "to":
            if _is_mojo(ws[i + 2]) or _is_version_number(ws[i + 2]):
                return True
    return False


def _says_adapting(ws: List[String]) -> Bool:
    """Whether a subject that moves to a Mojo version also says it changed
    what the version needed (`lock mojo 1.2.0..., refresh MOJO_NOTES`,
    `bump to 24.3 and fix the tests`): a migration, not only a bump."""
    for ref w in ws:
        if (
            w.startswith("refresh") or w.startswith("adapt") or w.startswith("fix")
            or w == "port" or w == "ported" or w.startswith("rework") or w.startswith("rewrit")
        ):
            return True
    return False


def commit_type(subject: String, version_change: Bool) -> String:
    """The type of a commit with this subject; `version_change` when
    mojo.migrations has a Mojo version change at it."""
    var s = subject.lower()
    # Leading tags, `[skip ci] Merge pull request ...`, `[pre-commit.ci] ...`.
    while s.startswith("["):
        var close = s.find("]").or_else(-1)
        if close < 0:
            break
        var tag = String(s[byte=1:close])
        if "pre-commit" in tag or "dependabot" in tag:
            return "chore"
        # `[release] ...`, `[doc] ...`: a tag that names a type is read as
        # the subject's first word, as before.
        if _conventional(tag).byte_length() > 0 or _first_word(tag).byte_length() > 0:
            break
        s = String(String(s[byte = close + 1 :]).strip())
    if s.startswith("merge pull request") or s.startswith("merge branch") or s.startswith("merge remote"):
        return "merge"
    var b = s.as_bytes()
    # A conventional prefix: letters, an optional `(scope)` and `!`, a `:`.
    var i = 0
    while i < len(b) and _is_letter(b[i]):
        i += 1
    var base = String()
    var rest_at = 0
    if i > 0:
        var j = i
        if j < len(b) and b[j] == UInt8(ord("(")):
            while j < len(b) and b[j] != UInt8(ord(")")):
                j += 1
            j += 1
        if j < len(b) and b[j] == UInt8(ord("!")):
            j += 1
        if j < len(b) and b[j] == UInt8(ord(":")):
            base = _conventional(String(s[byte=:i]))
            rest_at = j + 1
    var ws = words(String(s[byte=rest_at:]))
    # A prefix it doesn't know still counts for a version or a migration:
    # `migrate: .load -> .unsafe_load`, `toolchain: lock mojo 1.2.0...`.
    var scan = words(s) if base.byte_length() == 0 and rest_at > 0 else ws.copy()
    var migration = _says_migration(scan)
    if version_change:
        return "migration" if migration or _says_adapting(scan) else "version"
    if base.byte_length() > 0 and base != "chore" and base != "fix" and base != "refactor":
        return base
    if base.byte_length() > 0 and migration:
        return "migration"
    if _says_version(scan):
        return "migration" if _says_adapting(scan) else "version"
    if migration:
        return "migration"
    if base.byte_length() > 0:
        return base
    if len(ws) == 0:
        return "other"
    if (ws[0] == "update" or ws[0] == "updated" or ws[0] == "updates") and len(ws) > 1:
        if ws[1] == "readme" or ws[1] == "readme.md" or ws[1] == "docs" or ws[1] == "documentation":
            return "docs"
    # `Initial commit`, `initial setup`; not `init function of ...`.
    if (ws[0] == "initial" or ws[0] == "init") and (
        len(ws) == 1 or ws[1] == "commit" or ws[1] == "setup" or ws[1] == "import"
    ):
        return "chore"
    var t = _first_word(ws[0])
    return t if t.byte_length() > 0 else String("other")


def has_subjects(pts: List[Point]) -> Bool:
    """Whether any commit has its subject (read since #102)."""
    for ref p in pts:
        if p.subject.byte_length() > 0:
            return True
    return False


def commit_types(pts: List[Point], ms: List[Migration]) -> List[String]:
    """The main type of each commit of `pts` (`typed_commits`)."""
    var out = List[String]()
    for ref t in typed_commits(pts, ms):
        out.append(t.main)
    return out^


comptime VOTERS = 5
comptime VOTE_SHARE = 0.5
"""Leave-one-out on the 100 examples: 63 typed, 37 of those right (59%);
the other 37 stay `other`."""
comptime SECONDARY_SHARE = 0.1
"""On the examples, 18 of the 23 secondary types it gives are right."""


@fieldwise_init
struct Typed(Copyable, Movable):
    var main: String
    """A `commit_type_keys` key, or "" for a commit without its subject."""
    var secondary: List[String]
    """Up to two more keys: other parts of the commit (`test`, `docs`)."""
    var by: String
    """`rules`, `files` (the vote) or "" (no subject)."""


def _unit(mut v: List[Float64]):
    var n = Float64(0)
    for x in v:
        n += x * x
    if n <= 0:
        return
    var s = 1 / (n ** 0.5)
    for i in range(len(v)):
        v[i] *= s


struct _Voters(Movable):
    """The examples' features, centered on their mean and unit length."""
    var mean: List[Float64]
    var vecs: List[List[Float64]]
    var main: List[String]

    def __init__(out self):
        self.mean = List[Float64]()
        self.vecs = List[List[Float64]]()
        self.main = List[String]()
        var raw = List[List[Float64]]()
        for ref line in commit_examples():
            var parts = line.split("|")
            var m = FileMix.decode(String(parts[2]))
            if not m:
                continue
            raw.append(m.value().features())
            self.main.append(String(parts[0]))
        if len(raw) == 0:
            return
        var d = len(raw[0])
        self.mean = List[Float64](length=d, fill=0)
        for ref v in raw:
            for j in range(d):
                self.mean[j] += v[j]
        for j in range(d):
            self.mean[j] /= Float64(len(raw))
        for ref v in raw:
            var c = List[Float64](length=d, fill=0)
            for j in range(d):
                c[j] = v[j] - self.mean[j]
            _unit(c)
            self.vecs.append(c^)

    def vote(self, m: FileMix) -> String:
        """The type the nearest examples vote for, or "" when none has
        `VOTE_SHARE` of the vote."""
        if len(self.vecs) == 0:
            return String()
        var f = m.features()
        for j in range(len(f)):
            f[j] -= self.mean[j]
        _unit(f)
        var top_s = List[Float64]()
        var top_i = List[Int]()
        for i in range(len(self.vecs)):
            var s = Float64(0)
            for j in range(len(f)):
                s += f[j] * self.vecs[i][j]
            var at = len(top_s)
            while at > 0 and top_s[at - 1] < s:
                at -= 1
            if at < VOTERS:
                top_s.insert(at, s)
                top_i.insert(at, i)
                if len(top_s) > VOTERS:
                    _ = top_s.pop()
                    _ = top_i.pop()
        var votes = Dict[String, Float64]()
        var total = Float64(0)
        for k in range(len(top_s)):
            var w = max(top_s[k], 0.0) + 1e-6
            total += w
            ref t = self.main[top_i[k]]
            votes[t] = votes.get(t, 0.0) + w
        var best = String()
        var best_w = Float64(0)
        for e in votes.items():
            if e.value > best_w:
                best_w = e.value
                best = e.key
        return best if total > 0 and best_w / total >= VOTE_SHARE else String()


def _secondary(main: String, m: FileMix) -> List[String]:
    var out = List[String]()
    var t = m.test_share()
    if main != "test" and t >= SECONDARY_SHARE and t < 0.95:
        out.append("test")
    var d = m.share(3)  # filemix.KIND_DOCS
    if main != "docs" and d >= SECONDARY_SHARE and d < 0.95:
        out.append("docs")
    return out^


def typed_commits(pts: List[Point], ms: List[Migration]) -> List[Typed]:
    """Each commit of `pts`: its main type by the rules (`commit_type`, a
    commit with a Mojo version change in `ms` counting as one), else by the
    vote over its files, and its secondary types."""
    var changed = Dict[String, Bool]()
    for ref m in ms:
        if m.kind == "mojo_version":
            changed[m.sha] = True
    var voters = _Voters()
    var out = List[Typed]()
    for ref p in pts:
        if p.subject.byte_length() == 0:
            out.append(Typed(String(), List[String](), String()))
            continue
        var main = commit_type(p.subject, p.sha in changed)
        var by = String("rules")
        var mix = FileMix.decode(p.changes)
        if not mix:
            out.append(Typed(main^, List[String](), by^))
            continue
        if main == "other":
            var v = voters.vote(mix.value())
            if v.byte_length() > 0:
                main = v^
                by = "files"
        var sec = _secondary(main, mix.value())
        out.append(Typed(main^, sec^, by^))
    return out^
