"""The dependencies a repository declares at its HEAD, and the names it
publishes itself under, from its manifests: `pixi.toml`, `mojoproject.toml`,
`pyproject.toml`, `requirements.txt` and a rattler-build `recipe.yaml`.

`manifest_deps` reads one file into `Dep` rows (`mojo_versions` stores them
in `mojo.repo_deps`); `resolve` turns every repository's rows into the
Mojo libraries each depends on and the repositories that depend on each,
directly, through a fork of it, or through one of its dependents (second
degree), which the console computes when it builds its pages, so the
reverse counts need no pipeline of their own.

The readers are line-based, like the version readers in `versions.mojo`: a
manifest is TOML or YAML a person wrote by a template, and the few shapes
that matter (a `name = "spec"` line under a dependencies table, a `- name
spec` item under `requirements:`) don't need a full parser.
"""

from overview import top_gains
from versions import packages


def republishes() -> Dict[String, String]:
    """REPUBLISHES: repositories that republish another one's code without
    being a GitHub fork of it, as their descriptions say ("Packaged
    distribution of flare (ehsanmok/flare)"), by the lowercased republish,
    to the repository they republish. `resolve` counts a project that
    depends on one as a dependent of the upstream through a fork of it, as
    for a fork (`ForkOf`). Curated: an entry is added when the republish's
    description or README names its upstream, never guessed."""
    var out = Dict[String, String]()
    out["magmalake/flare_mlake"] = "ehsanmok/flare"
    out["magmalake/json_mlake"] = "ehsanmok/json"
    out["magmalake/mozz_mlake"] = "ehsanmok/mozz"
    # Vendors the codec of libs/zstd rather than packaging the repository.
    out["magmalake/zstd.mojo"] = "amarbaro/mojo-libs"
    return out^

comptime DEPENDS = "depends"
"""`relation` of a declared dependency."""
comptime PROVIDES = "provides"
"""`relation` of a name the repository publishes itself under: its
`[package]` name (pixi-build), a recipe's `package.name`, a pyproject's
`[project]` name, or a pixi workspace's name (kind `workspace`)."""


@fieldwise_init
struct Dep(Copyable, Movable):
    """One row of `mojo.repo_deps` (less `repo` and `read_at`, which the
    pipeline knows)."""

    var relation: String
    """`depends` or `provides`."""
    var kind: String
    """For `depends`: `conda` (a pixi/magic or recipe package), `pypi`,
    `git`, `url` or `path`. For `provides`: `package`, `recipe`, `pyproject`
    or `workspace`."""
    var name: String
    """The package name as written."""
    var dep_repo: String
    """`owner/name` when the dependency is a GitHub URL (`git = ...`,
    `url = ...`, `name @ git+https://...`) or GitHub's `owner/name`
    shorthand (`git = "o/r"`, `github_shorthand`), else empty."""
    var section: String
    """Where in the file: `dependencies`, `feature.test.dependencies`,
    `package.run-dependencies`, `requirements.host`, `project.dependencies`."""
    var file: String


def modular_packages() -> List[String]:
    """The packages Modular publishes on conda.modular.com (`max`, `max-nightly`)
    as of 2026-11: its toolchain and tools, none of them a Mojo library of
    the census, whatever repository is named like one (`mojo-python`)."""
    return [
        "max", "max-all", "max-benchmark", "max-core", "max-pipelines",
        "max-python", "max-serve", "mblack", "modular", "mojo",
        "mojo-compiler", "mojo-dev", "mojo-jupyter", "mojo-python",
    ]


def _carries_mojo(n: String) -> Bool:
    """Whether the normalised name `n` is a package that installs Mojo
    (`versions.packages`, and `max-pipelines`)."""
    for p in packages():
        if n == p:
            return True
    return n == "max-pipelines"


def toolchain(name: String) -> Bool:
    """Whether `name` is Modular's toolchain (`mojo`, `max`, ...) or another
    package of its channel (`modular_packages`) rather than a library: every
    Mojo project depends on it, so it isn't counted."""
    var n = norm_name(name)
    if _carries_mojo(n):
        return True
    for p in modular_packages():
        if n == p:
            return True
    return False


def norm_name(name: String) -> String:
    """A package name compared the way conda and PyPI do: lower case, `_`
    and `.` as `-` (`Lightbug_HTTP` and `lightbug-http` are one name)."""
    return String(name.strip()).lower().replace("_", "-").replace(".", "-")


def _name_char(c: UInt8) -> Bool:
    """Whether `c` can be in a package name."""
    return (
        (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
        or c == UInt8(ord("-")) or c == UInt8(ord("_")) or c == UInt8(ord("."))
    )


def _leading_name(s: String) -> String:
    """The package name at the start of `s` (`numpy>=1.2` gives `numpy`)."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and _name_char(b[i]):
        i += 1
    return String(s[byte=:i])


def github_repo(url: String) -> String:
    """`owner/name` of a GitHub URL (`https://github.com/o/r.git`,
    `git+https://github.com/o/r@v1`, `git@github.com:o/r.git`,
    `https://github.com/o/r/archive/v1.tar.gz`), or empty."""
    var at = url.find("github.com").or_else(-1)
    if at < 0:
        return String()
    var i = at + 10
    var b = url.as_bytes()
    if i >= len(b) or (b[i] != UInt8(ord("/")) and b[i] != UInt8(ord(":"))):
        return String()
    i += 1
    var parts = List[String]()
    var start = i
    while i <= len(b) and len(parts) < 2:
        if i == len(b) or not _name_char(b[i]):
            parts.append(String(url[byte=start:i]))
            if i == len(b) or b[i] != UInt8(ord("/")):
                break
            start = i + 1
        i += 1
    if len(parts) < 2 or parts[0].byte_length() == 0 or parts[1].byte_length() == 0:
        return String()
    var name = parts[1]
    if name.endswith(".git"):
        var cut = String(name[byte = : name.byte_length() - 4])
        name = cut^
    if name.byte_length() == 0:
        return String()
    return String(parts[0], "/", name)


def _owner_char(c: UInt8) -> Bool:
    """Whether `c` can be in a GitHub owner: a letter, a digit or `-`."""
    return (
        (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
        or c == UInt8(ord("-"))
    )


def github_shorthand(spec: String) -> String:
    """`owner/name` when a `git = "..."` spec is GitHub's shorthand for a
    repository (`git = "Mosaad-M/json"`): no scheme or host, exactly one
    `/`, an owner of letters, digits and `-` (not first), a name of
    package-name characters, `.git` dropped; else empty."""
    var s = String(spec.strip())
    var slash = s.find("/").or_else(-1)
    if slash <= 0 or s.find("/", slash + 1).or_else(-1) >= 0:
        return String()
    var owner = String(s[byte=:slash])
    var name = String(s[byte = slash + 1 :])
    if name.endswith(".git"):
        var cut = String(name[byte = : name.byte_length() - 4])
        name = cut^
    if owner.byte_length() > 39 or owner.startswith("-"):
        return String()
    for c in owner.as_bytes():
        if not _owner_char(c):
            return String()
    if name.byte_length() == 0 or name == "." or name == "..":
        return String()
    for c in name.as_bytes():
        if not _name_char(c):
            return String()
    return String(owner, "/", name)


def _strip_comment(line: String, after_space: Bool = False) -> String:
    """`line` without a `#` comment (one outside quotes). With `after_space`,
    as pip reads it: a `#` starts a comment only at the start of the line or
    after a space (`...git#egg=name` is part of a URL)."""
    var b = line.as_bytes()
    var quote = UInt8(0)
    for i in range(len(b)):
        var c = b[i]
        if quote != 0:
            if c == quote:
                quote = 0
        elif c == UInt8(ord('"')) or c == UInt8(ord("'")):
            quote = c
        elif c == UInt8(ord("#")) and (
            not after_space or i == 0 or b[i - 1] == UInt8(32) or b[i - 1] == UInt8(9)
        ):
            return String(line[byte=:i])
    return line


def _unquote(s: String) -> String:
    """`s` stripped, without surrounding quotes."""
    var t = String(s.strip())
    if t.byte_length() >= 2 and (
        (t.startswith('"') and t.endswith('"')) or (t.startswith("'") and t.endswith("'"))
    ):
        return String(t[byte = 1 : t.byte_length() - 1])
    return t^


def _depth(s: String) -> Int:
    """How many `[`/`{` `s` opens and doesn't close, outside quotes."""
    var b = s.as_bytes()
    var quote = UInt8(0)
    var d = 0
    for c in b:
        if quote != 0:
            if c == quote:
                quote = 0
        elif c == UInt8(ord('"')) or c == UInt8(ord("'")):
            quote = c
        elif c == UInt8(ord("[")) or c == UInt8(ord("{")):
            d += 1
        elif c == UInt8(ord("]")) or c == UInt8(ord("}")):
            d -= 1
    return d


def _split_key(line: String) -> Tuple[String, String]:
    """A TOML `key = value` line as (key, value), the key unquoted; ("", "")
    when the line isn't one."""
    var b = line.as_bytes()
    var quote = UInt8(0)
    for i in range(len(b)):
        var c = b[i]
        if quote != 0:
            if c == quote:
                quote = 0
        elif c == UInt8(ord('"')) or c == UInt8(ord("'")):
            quote = c
        elif c == UInt8(ord("=")):
            var key = _unquote(String(line[byte=:i]))
            return (key^, String(String(line[byte = i + 1 :]).strip()))
    return (String(), String())


def _inline_str(value: String, key: String) -> String:
    """The string `key` has in a TOML inline table (`{ git = "..." }`), or
    empty."""
    var at = 0
    while True:
        var i = value.find(key, at).or_else(-1)
        if i < 0:
            return String()
        at = i + 1
        var b = value.as_bytes()
        if i > 0 and _name_char(b[i - 1]):
            continue
        var j = i + key.byte_length()
        while j < len(b) and b[j] == UInt8(32):
            j += 1
        if j >= len(b) or b[j] != UInt8(ord("=")):
            continue
        j += 1
        while j < len(b) and b[j] == UInt8(32):
            j += 1
        if j >= len(b) or (b[j] != UInt8(ord('"')) and b[j] != UInt8(ord("'"))):
            continue
        var q = b[j]
        var k = j + 1
        while k < len(b) and b[k] != q:
            k += 1
        return String(value[byte = j + 1 : k])


def _section_name(header: String) -> String:
    """`[feature."test".dependencies]` as `feature.test.dependencies`."""
    var s = String(header.strip())
    while s.startswith("["):
        var t = String(s[byte=1:])
        s = t^
    while s.endswith("]"):
        var t = String(s[byte = : s.byte_length() - 1])
        s = t^
    var parts = s.split(".")
    var out = String()
    for i in range(len(parts)):
        if i > 0:
            out += "."
        out += _unquote(String(parts[i]))
    return out^


def _dep_table(section: String) -> Bool:
    """Whether a pixi table lists dependencies: its last part is
    `dependencies`, `host-dependencies`, `pypi-dependencies`, ..."""
    var parts = section.split(".")
    var last = String(parts[len(parts) - 1])
    return last == "dependencies" or last.endswith("-dependencies")


def _strip_prefix(section: String, prefix: String) -> String:
    if section.startswith(prefix):
        return String(section[byte = prefix.byte_length() :])
    return section


def _toml_dep(name: String, value: String, section: String, file: String) -> Dep:
    """A dependency line of a pixi table: `name = "spec"` or `name = { git =
    "...", rev = "..." }`."""
    var pypi = "pypi" in section
    var kind = String("pypi") if pypi else String("conda")
    var repo = String()
    if value.startswith("{"):
        var git = _inline_str(value, "git")
        var url = _inline_str(value, "url")
        var path = _inline_str(value, "path")
        if git.byte_length() > 0:
            kind = String("git")
            repo = github_repo(git)
            if repo.byte_length() == 0:
                repo = github_shorthand(git)
        elif url.byte_length() > 0:
            kind = String("url")
            repo = github_repo(url)
        elif path.byte_length() > 0:
            kind = String("path")
    return Dep(String(DEPENDS), kind^, name, repo^, section, file)


def _pep508(req: String, section: String, file: String) -> Optional[Dep]:
    """A PEP 508 requirement (`numpy>=1.26`, `foo @ git+https://github.com/o/r`)
    as a `pypi` (or `git`/`url`) dependency; none if it names no package."""
    var r = String(req.strip())
    var name = _leading_name(r)
    if name.byte_length() == 0:
        return None
    var kind = String("pypi")
    var repo = String()
    var at = r.find("@").or_else(-1)
    if at > 0:
        var url = String(String(r[byte = at + 1 :]).strip())
        repo = github_repo(url)
        kind = String("git") if url.startswith("git+") else String("url")
    return Dep(String(DEPENDS), kind^, name^, repo^, section, file)


def _array_strings(text: String) -> List[String]:
    """The quoted strings of a TOML array's text."""
    var out = List[String]()
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("'")):
            var k = i + 1
            while k < len(b) and b[k] != c:
                k += 1
            out.append(String(text[byte = i + 1 : k]))
            i = k + 1
        else:
            i += 1
    return out^


def toml_deps(text: String, file: String) -> List[Dep]:
    """The dependencies and published names of a `pixi.toml`,
    `mojoproject.toml` or `pyproject.toml` (whose pixi tables are under
    `tool.pixi`, and whose PEP 621 lists are `project.dependencies`,
    `project.optional-dependencies` and `dependency-groups`)."""
    var out = List[Dep]()
    var pyproject = file.endswith("pyproject.toml")
    var section = String()
    # A multi-line value (`dependencies = [` then a line per item, or an
    # inline table broken over lines) is gathered until its brackets close.
    var pending_key = String()
    var pending = String()
    var depth = 0
    var sub = -1
    for raw in text.split("\n"):
        var line = String(_strip_comment(String(raw)).strip())
        if depth > 0:
            pending += " "
            pending += line
            depth += _depth(line)
            if depth <= 0:
                _toml_entry(out, sub, section, pending_key, pending, file, pyproject)
                depth = 0
            continue
        if line.byte_length() == 0:
            continue
        if line.startswith("["):
            section = _section_name(line)
            if pyproject:
                section = _strip_prefix(section, "tool.pixi.")
            # `[dependencies.foo]`: the table is one dependency, `foo`; its
            # `git`/`url`/`path` keys, if any, follow (`_toml_entry`).
            sub = -1
            var parts = section.split(".")
            if len(parts) >= 2:
                var last = String(parts[len(parts) - 1])
                var parent = String(section[byte = : section.byte_length() - last.byte_length() - 1])
                if _dep_table(parent):
                    sub = len(out)
                    out.append(_toml_dep(last, String(), parent, file))
            continue
        var kv = _split_key(line)
        if kv[0].byte_length() == 0:
            continue
        var d = _depth(kv[1])
        if d > 0:
            pending_key = kv[0]
            pending = kv[1]
            depth = d
            continue
        _toml_entry(out, sub, section, kv[0], kv[1], file, pyproject)
    return out^


def _toml_entry(
    mut out: List[Dep], sub: Int, section: String, key: String, value: String,
    file: String, pyproject: Bool,
):
    """One `key = value` of table `section`, into `out` if it is a
    dependency or a published name. `sub` is the row of a
    `[dependencies.foo]` table being read, or -1."""
    if section == "package" and key == "name":
        out.append(Dep(String(PROVIDES), String("package"), _unquote(value), String(), section, file))
        return
    if (section == "workspace" or section == "project") and key == "name":
        var kind = String("pyproject") if pyproject and section == "project" else String("workspace")
        out.append(Dep(String(PROVIDES), kind^, _unquote(value), String(), section, file))
        return
    if pyproject and (
        (section == "project" and key == "dependencies")
        or section == "project.optional-dependencies"
        or section == "dependency-groups"
    ):
        var where = String(section, ".", key) if section != "project" else String("project.dependencies")
        for s in _array_strings(value):
            var d = _pep508(s, where, file)
            if d:
                out.append(d.value().copy())
        return
    if pyproject and section == "project":
        return
    if sub >= 0:
        # `[dependencies.foo]` with `git = "..."` under it.
        if key == "git" or key == "url" or key == "path":
            var d = _toml_dep(out[sub].name, String("{ ", key, " = ", value, " }"), out[sub].section, file)
            out[sub] = d^
        return
    if _dep_table(section):
        out.append(_toml_dep(key, value, section, file))


def _indent(line: String) -> Int:
    var b = line.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return i


def _yaml_value(line: String) -> String:
    """The value of a `key: value` YAML line, unquoted; empty for none."""
    var colon = line.find(":").or_else(-1)
    if colon < 0:
        return String()
    return _unquote(String(line[byte = colon + 1 :]))


def _subst(value: String, context: Dict[String, String]) -> String:
    """`${{ name }}` (and `${{ name | lower }}`) replaced from the recipe's
    `context:`; empty if it is some other template."""
    var v = String(value.strip())
    if not v.startswith("${{"):
        return v^
    var inner = String(String(v[byte=3:]).strip())
    if inner.endswith("}}"):
        var cut = String(String(inner[byte = : inner.byte_length() - 2]).strip())
        inner = cut^
    var bar = inner.find("|").or_else(-1)
    var lower = False
    if bar >= 0:
        lower = "lower" in String(inner[byte = bar + 1 :])
        var cut = String(String(inner[byte=:bar]).strip())
        inner = cut^
    if inner in context:
        var out = context.get(inner, String())
        return out.lower() if lower else out
    return String()


def recipe_deps(text: String, file: String) -> List[Dep]:
    """The requirements and package names of a rattler-build `recipe.yaml`:
    `package: name:` (also in each of `outputs:`), and the `- name spec`
    items under `requirements:` `build:`, `host:` and `run:` (the tests'
    requirements too). Jinja items (`${{ compiler('c') }}`, `pin_compatible`)
    and `if:` selectors are skipped; a selector's `then:` item is read."""
    var out = List[Dep]()
    var context = Dict[String, String]()
    var in_context = -1
    var in_package = -1
    var in_reqs = -1
    var req_key = String()
    for raw in text.split("\n"):
        var full = _strip_comment(String(raw))
        var line = String(full.strip())
        if line.byte_length() == 0:
            continue
        var ind = _indent(full)
        if in_context >= 0 and ind <= in_context:
            in_context = -1
        if in_package >= 0 and ind <= in_package:
            in_package = -1
        if in_reqs >= 0 and ind <= in_reqs:
            in_reqs = -1
            req_key = String()
        if line == "context:":
            in_context = ind
            continue
        if line == "package:" or line == "- package:":
            in_package = ind
            continue
        if line == "requirements:":
            in_reqs = ind
            req_key = String()
            continue
        if in_context >= 0 and ":" in line:
            var k = String(line[byte = : line.find(":").or_else(-1)])
            context[String(k.strip())] = _yaml_value(line)
            continue
        if in_package >= 0 and line.startswith("name:"):
            var n = _subst(_yaml_value(line), context)
            if n.byte_length() > 0:
                out.append(Dep(String(PROVIDES), String("recipe"), n^, String(), String("package"), file))
            continue
        if in_reqs < 0:
            continue
        if not line.startswith("-") and line.endswith(":"):
            # `build:`, `host:`, `run:` (or `run_constraints:`, not read).
            req_key = String(line[byte = : line.byte_length() - 1])
            continue
        if req_key != "build" and req_key != "host" and req_key != "run":
            continue
        var item = String()
        if line.startswith("- "):
            item = String(String(line[byte=2:]).strip())
        elif line.startswith("then:") or line.startswith("else:"):
            item = _yaml_value(line)
        if item.byte_length() == 0 or item.startswith("${{") or item.startswith("if:"):
            continue
        if item.startswith("then:") or item.startswith("else:"):
            item = _yaml_value(item)
        item = _unquote(item)
        var name = _leading_name(item)
        if name.byte_length() == 0:
            continue
        out.append(Dep(String(DEPENDS), String("conda"), name^, String(), String("requirements.", req_key), file))
    return out^


def requirements_deps(text: String, file: String) -> List[Dep]:
    """A pip `requirements.txt`: a PEP 508 line each, `-e git+https://...
    #egg=name` and bare URLs too; `-r` includes and options are skipped."""
    var out = List[Dep]()
    for raw in text.split("\n"):
        var line = String(_strip_comment(String(raw), True).strip())
        if line.byte_length() == 0:
            continue
        if line.startswith("-e ") or line.startswith("git+") or line.startswith("https://"):
            var url = String(String(line[byte = 3 :]).strip()) if line.startswith("-e ") else line
            var egg = url.find("#egg=").or_else(-1)
            var name = _leading_name(String(url[byte = egg + 5 :])) if egg >= 0 else String()
            var repo = github_repo(url)
            if name.byte_length() == 0:
                if repo.byte_length() == 0:
                    continue
                name = String(repo[byte = repo.find("/").or_else(-1) + 1 :])
            out.append(Dep(String(DEPENDS), String("git") if "git+" in url else String("url"), name^, repo^, String("requirements"), file))
            continue
        if line.startswith("-"):
            continue
        var d = _pep508(line, String("requirements"), file)
        if d:
            out.append(d.value().copy())
    return out^


def is_recipe(path: String) -> Bool:
    """Whether `path` is a recipe of the repository's own package: a
    `recipe.yaml` at the root or in `recipe/`, `recipes/`, `conda/` or
    `conda.recipe/`."""
    return (
        path == "recipe.yaml" or path == "recipe/recipe.yaml"
        or path == "recipes/recipe.yaml" or path == "conda/recipe.yaml"
        or path == "conda.recipe/recipe.yaml"
    )


def names_mojo_pkg(path: String, text: String) -> Bool:
    """Whether the manifest `path` (`text`) depends on a package that
    installs Mojo (`versions.packages`, `max-pipelines`): what makes a
    `pyproject.toml` or `requirements.txt` the way a repository gets Mojo."""
    for ref d in manifest_deps(path, text):
        if d.relation == DEPENDS and _carries_mojo(norm_name(d.name)):
            return True
    return False


def manifest_deps(path: String, text: String) -> List[Dep]:
    """The rows of one file, by its name."""
    if path.endswith(".toml"):
        return toml_deps(text, path)
    if path.endswith(".yaml") or path.endswith(".yml"):
        return recipe_deps(text, path)
    if path.endswith(".txt"):
        return requirements_deps(text, path)
    return List[Dep]()


def _clean(s: String) -> String:
    """`s` without the tabs and newlines `encode_deps` separates with."""
    return s.replace("\t", " ").replace("\n", " ")


def encode_deps(rows: List[Dep]) -> String:
    """`rows` as text, one per line, fields tab-separated: how a dista task
    returns them (its codec sends a struct's `String` fields, not a `List`)."""
    var out = String()
    for ref d in rows:
        out.write(
            _clean(d.relation), "\t", _clean(d.kind), "\t", _clean(d.name), "\t",
            _clean(d.dep_repo), "\t", _clean(d.section), "\t", _clean(d.file), "\n",
        )
    return out^


def decode_deps(text: String) -> List[Dep]:
    """What `encode_deps` wrote."""
    var out = List[Dep]()
    for line in text.split("\n"):
        var f = line.split("\t")
        if len(f) != 6:
            continue
        out.append(Dep(String(f[0]), String(f[1]), String(f[2]), String(f[3]), String(f[4]), String(f[5])))
    return out^


def dedupe(rows: List[Dep]) -> List[Dep]:
    """`rows` without repeats of the same (relation, kind, name, repo,
    section, file), in order."""
    var seen = Dict[String, Bool]()
    var out = List[Dep]()
    for ref d in rows:
        var k = String(d.relation, "\t", d.kind, "\t", d.name, "\t", d.dep_repo, "\t", d.section, "\t", d.file)
        if k in seen:
            continue
        seen[k] = True
        out.append(d.copy())
    return out^


def declared_count(rows: List[Dep]) -> Int:
    """Distinct dependencies by name, the toolchain left out: a name in
    `dependencies` and `package.run-dependencies` counts once."""
    var seen = Dict[String, Bool]()
    for ref d in rows:
        if d.relation != DEPENDS or toolchain(d.name):
            continue
        seen[norm_name(d.name)] = True
    return len(seen)


@fieldwise_init
struct RepoDep(Copyable, Movable):
    """A row of `mojo.repo_deps`: a `Dep` with its repository and when it
    was read."""

    var repo: String
    var read_at: Int64
    var dep: Dep


struct DepGraph(Copyable, Movable):
    """What `resolve` found, by repository (as named in `repos`)."""

    var depends_on: Dict[String, List[String]]
    """The census repositories each one depends on, sorted."""
    var used_by: Dict[String, List[String]]
    """The census repositories that depend on each one, sorted."""
    var declared: Dict[String, List[String]]
    """Every dependency each one declares (toolchain left out), by name as
    first written, sorted."""
    var via_forks: Dict[String, List[String]]
    """Of `used_by`, the ones that depend on it only through a fork of it,
    sorted."""
    var second: Dict[String, List[String]]
    """The census repositories that depend on it through one of its
    `used_by` (second degree), each once, sorted; none of them is in its
    `used_by`, nor is it itself."""

    def __init__(out self):
        self.depends_on = Dict[String, List[String]]()
        self.used_by = Dict[String, List[String]]()
        self.declared = Dict[String, List[String]]()
        self.via_forks = Dict[String, List[String]]()
        self.second = Dict[String, List[String]]()


@fieldwise_init
struct ForkOf(Copyable, Movable):
    """What GitHub says a repository named as a dependency was forked from
    (mojo.dep_forks)."""

    var parent: String
    var source: String
    """The root of its fork network."""


def _short(repo: String) -> String:
    """The name part of `owner/name`."""
    var slash = repo.find("/").or_else(-1)
    return String(repo[byte = slash + 1 :]) if slash >= 0 else repo


def _sorted(var xs: List[String]) -> List[String]:
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j - 1].lower() > xs[j].lower():
            xs.swap_elements(j - 1, j)
            j -= 1
    return xs^


def _add_once(mut d: Dict[String, List[String]], key: String, value: String) raises:
    """`value` appended to `d[key]` unless it is there already."""
    if key not in d:
        d[key] = List[String]()
    for x in d[key]:
        if x == value:
            return
    d[key].append(value)


struct _Census(Movable):
    """The census repositories by the names `resolve` matches a dependency
    against: lowercased `owner/name` (old names too), the normalised name
    part, and the names they publish."""

    var by_lower: Dict[String, String]
    """A lowercased `owner/name`, current or old (`aliases`), to the
    repository in `repos`."""
    var by_short: Dict[String, List[String]]
    """A `norm_name` of a name part to the repositories that have it."""
    var provided: Dict[String, List[String]]
    """A published name (`norm_name`; workspace names left out) to the
    repositories that publish it."""
    var provided_py: Dict[String, List[String]]
    """Of `provided`, the names published by a pyproject's `[project]`
    table, which alone can be a PyPI project."""

    def __init__(
        out self, repos: List[String], rows: List[RepoDep], aliases: Dict[String, String]
    ) raises:
        self.by_lower = Dict[String, String]()
        self.by_short = Dict[String, List[String]]()
        self.provided = Dict[String, List[String]]()
        self.provided_py = Dict[String, List[String]]()
        for r in repos:
            self.by_lower[r.lower()] = r
            _add_once(self.by_short, norm_name(_short(r)), r)
        for e in aliases.items():
            var cur = e.value.lower()
            if cur not in self.by_lower or e.key in self.by_lower:
                continue
            var r = self.by_lower[cur]
            self.by_lower[e.key] = r
            _add_once(self.by_short, norm_name(_short(e.key)), r)
        for ref rd in rows:
            if rd.dep.relation != PROVIDES or rd.dep.kind == "workspace":
                continue
            if rd.repo.lower() not in self.by_lower:
                continue
            var n = norm_name(rd.dep.name)
            if n.byte_length() == 0:
                continue
            var owner = self.by_lower[rd.repo.lower()]
            _add_once(self.provided, n, owner)
            if rd.dep.kind == "pyproject":
                _add_once(self.provided_py, n, owner)

    def by_name(self, d: Dep, conda_forge: Dict[String, Bool]) raises -> String:
        """The repository a dependency without a GitHub repository resolves
        to by its name (`resolve`'s rules 2 and 3 as its kind allows), or
        empty."""
        if d.kind == "path" or d.kind == "url" or d.kind == "git":
            return String()
        var n = norm_name(d.name)
        if d.kind == "pypi":
            return _published(self.provided_py, n)
        if n in conda_forge:
            return String()
        var target = _published(self.provided, n)
        if target.byte_length() == 0 and n in self.by_short and len(self.by_short[n]) == 1:
            target = self.by_short[n][0]
        return target^


def _published(provided: Dict[String, List[String]], n: String) raises -> String:
    """The repository that publishes `n`: the only one, or of several the
    one whose own name is `n`; else empty."""
    if n not in provided:
        return String()
    ref ps = provided[n]
    if len(ps) == 1:
        return ps[0]
    for p in ps:
        if norm_name(_short(p)) == n:
            return p
    return String()


def conda_lookups(
    repos: List[String],
    rows: List[RepoDep],
    aliases: Dict[String, String] = Dict[String, String](),
) raises -> Dict[String, List[String]]:
    """The `conda` dependencies of census repositories that `resolve` would
    match to a census repository by name (rules 2 and 3), by `norm_name`,
    each with the forms to ask conda-forge about: the normalised name, then
    each other spelling as written, lowercased (`lightbug_http`), once.
    Names with characters a package name can't have are left out. What
    mojo_stats asks anaconda.org about for mojo.dep_names."""
    var census = _Census(repos, rows, aliases)
    var none = Dict[String, Bool]()
    var out = Dict[String, List[String]]()
    for ref rd in rows:
        ref d = rd.dep
        if d.relation != DEPENDS or d.kind != "conda" or d.dep_repo.byte_length() > 0:
            continue
        if toolchain(d.name) or rd.repo.lower() not in census.by_lower:
            continue
        var n = norm_name(d.name)
        var plain = True
        for c in n.as_bytes():
            if not _name_char(c):
                plain = False
        if n.byte_length() == 0 or not plain:
            continue
        var target = census.by_name(d, none)
        if target.byte_length() == 0 or target == census.by_lower[rd.repo.lower()]:
            continue
        _add_once(out, n, n)
        _add_once(out, n, String(d.name.strip()).lower())
    return out^


def resolve(
    repos: List[String],
    rows: List[RepoDep],
    forks: Dict[String, ForkOf] = Dict[String, ForkOf](),
    aliases: Dict[String, String] = Dict[String, String](),
    republished: Dict[String, String] = republishes(),
    conda_forge: Dict[String, Bool] = Dict[String, Bool](),
) raises -> DepGraph:
    """Each repository's dependencies that are census repositories, and the
    reverse.

    A dependency resolves to a repository of `repos`, in this order:
    1. its GitHub repository (`git = "https://github.com/o/r"`, or the
       shorthand `git = "o/r"`), matched without regard to case;
    2. a name a census repository publishes (its `[package]` name, a
       recipe's or a pyproject's name), when one repository does; when
       several do, the one whose own name matches;
    3. a census repository whose name matches (`lightbug_http` for
       `Lightbug-HQ/lightbug_http`), when only one has it.
    Names compare by `norm_name`. Rules 2 and 3 depend on the kind, since a
    name means a package of one index, and a wrong link is worse than a
    missing one:
    - `conda`: both, unless the name is a conda-forge package
      (`conda_forge`, by `norm_name`, from mojo.dep_names): `requests` or
      `sqlite` is conda-forge's, not a Mojo repository's of that name;
    - `pypi`: only rule 2, and only to a repository that publishes the name
      from a pyproject (`provides` kind `pyproject`), the only kind of name
      that can be a PyPI project;
    - `git`: neither: it names one repository, and when that isn't in the
      census (and isn't a fork of a census repository) nothing else is;
    - `url` and `path`: neither.
    The toolchain and the other packages of Modular's channel (`toolchain`)
    don't resolve, nor does a repository to itself.

    A GitHub URL of a repository that isn't in `repos` but is a fork
    (`forks`, keyed by the lowercased `owner/name`) resolves to its source,
    or else its parent, when that is a census repository: the fork's
    dependents are rolled up into it, and `via_forks` names the ones that
    use it only that way. `second` is worked out from the resulting
    `used_by`.
    Workspace names aren't used in (2): a workspace is often named after
    the template it came from (`my-project`, `mojo`), not a package.

    `aliases` maps the lowercased old names of renamed or transferred
    repositories to their names in `repos` (`names.Names.current`): a
    URL, a fork's parent or source, a row's own `repo` (mojo.repo_deps is
    keyed by the name a repository was found under) and the name in (3)
    under an old name resolve to the repository as it is named now.

    `republished` (`republishes`) maps a republish to its upstream: a
    dependency on the republish (a census repository or not) also makes the
    project a dependent of the upstream, through a fork, when the upstream
    is a census repository."""
    var g = DepGraph()
    var census = _Census(repos, rows, aliases)
    # Per repository, its targets, each True when declared directly and
    # False when reached only through a fork.
    var deps = Dict[String, Dict[String, Bool]]()
    var declared = Dict[String, Dict[String, String]]()
    for ref rd in rows:
        ref d = rd.dep
        if d.relation != DEPENDS or toolchain(d.name):
            continue
        var me_low = rd.repo.lower()
        if me_low not in census.by_lower:
            continue
        var me = census.by_lower[me_low]
        var n = norm_name(d.name)
        if me not in declared:
            declared[me] = Dict[String, String]()
        if n not in declared[me]:
            declared[me][n] = d.name
        var target: String
        var direct = True
        if d.dep_repo.byte_length() > 0:
            var low = d.dep_repo.lower()
            target = census.by_lower.get(low, String())
            if target.byte_length() == 0 and low in forks:
                ref f = forks[low]
                target = census.by_lower.get(f.source.lower(), String())
                if target.byte_length() == 0:
                    target = census.by_lower.get(f.parent.lower(), String())
                direct = False
        else:
            target = census.by_name(d, conda_forge)
        # A republish of a census repository (`republishes`): its upstream
        # too, as through a fork.
        var upstream = String()
        var named = target.lower() if target.byte_length() > 0 else d.dep_repo.lower()
        if named.byte_length() > 0 and named in republished:
            upstream = census.by_lower.get(republished.get(named, String()).lower(), String())
        if upstream.byte_length() > 0 and upstream != me:
            if me not in deps:
                deps[me] = Dict[String, Bool]()
            deps[me][upstream] = deps[me].get(upstream, False)
        if target.byte_length() == 0 or target == me:
            continue
        if me not in deps:
            deps[me] = Dict[String, Bool]()
        deps[me][target] = deps[me].get(target, False) or direct
    for e in deps.items():
        var ts = List[String]()
        for t in e.value.items():
            ts.append(t.key)
            if t.key not in g.used_by:
                g.used_by[t.key] = List[String]()
            g.used_by[t.key].append(e.key)
            if not t.value:
                if t.key not in g.via_forks:
                    g.via_forks[t.key] = List[String]()
                g.via_forks[t.key].append(e.key)
        g.depends_on[e.key] = _sorted(ts^)
    var targets = List[String]()
    for t in g.used_by.keys():
        targets.append(t)
    for t in targets:
        g.used_by[t] = _sorted(g.used_by[t].copy())
        if t in g.via_forks:
            g.via_forks[t] = _sorted(g.via_forks[t].copy())
    for t in targets:
        var s = second_degree(t, g.used_by)
        if len(s) > 0:
            g.second[t] = s^
    for e in declared.items():
        var ns = List[String]()
        for v in e.value.values():
            ns.append(v)
        g.declared[e.key] = _sorted(ns^)
    return g^


def second_degree(repo: String, used_by: Dict[String, List[String]]) raises -> List[String]:
    """The repositories that depend on `repo` through one of its dependents
    (`used_by[repo]`) and not directly, each once however many of them it
    goes through, sorted; `repo` itself is left out, which a cycle would
    bring in."""
    var out = List[String]()
    if repo not in used_by:
        return out^
    var seen = Dict[String, Bool]()
    seen[repo] = True
    for u in used_by[repo]:
        seen[u] = True
    for u in used_by[repo]:
        if u not in used_by:
            continue
        for v in used_by[u]:
            if v not in seen:
                seen[v] = True
                out.append(v)
    return _sorted(out^)


def owner_of(repo: String) -> String:
    """The owner part of `owner/name`, lowercased: GitHub owners are the
    same whatever their case."""
    var slash = repo.find("/").or_else(-1)
    return String(repo[byte=:slash]).lower() if slash >= 0 else repo.lower()


struct Depended(Copyable, Movable):
    """A row of the home page's Most depended on: one repository, or every
    depended-on repository of one owner (`owner/*`)."""

    var name: String
    """The repository, or `owner/*` with the owner as its first repository
    writes it."""
    var owner: String
    """`owner_of` the repository (or repositories)."""
    var group: Bool
    """Whether it stands for an owner's repositories."""
    var members: List[Int]
    """Indices into `most_depended`'s `repos` of the repositories it stands
    for, the most used first."""
    var used_by: Int64
    """The distinct census repositories that depend on any of them."""
    var internal: Int64
    """Of those, the ones with the same owner."""
    var stars: Int64
    """The repositories' stars, summed."""
    var forks: Int64

    def __init__(out self, name: String, owner: String, group: Bool):
        self.name = name
        self.owner = owner
        self.group = group
        self.members = List[Int]()
        self.used_by = 0
        self.internal = 0
        self.stars = 0
        self.forks = 0


def other_owners(repo: String, users: List[String]) -> List[String]:
    """Of `users`, the repositories whose owner isn't `repo`'s: who else
    depends on it, which its badge counts (#241)."""
    var owner = owner_of(repo)
    var out = List[String]()
    for u in users:
        if owner_of(u) != owner:
            out.append(u)
    return out^


def _internal(owner: String, users: List[String]) -> Int64:
    var n = Int64(0)
    for u in users:
        if owner_of(u) == owner:
            n += 1
    return n


def _depended_rows(
    repos: List[String],
    used_by: List[List[String]],
    stars: List[Int64],
    forks: List[Int64],
    grouped: Dict[String, Bool],
) raises -> List[Depended]:
    """A row per depended-on repository, but one per owner of `grouped`,
    in the order of `repos` (an owner's row where its first one is)."""
    var rows = List[Depended]()
    var at = Dict[String, Int]()
    var users = Dict[String, Dict[String, Bool]]()
    for i in range(len(repos)):
        if len(used_by[i]) == 0:
            continue
        var o = owner_of(repos[i])
        if o not in grouped:
            var r = Depended(repos[i], o, False)
            r.members.append(i)
            r.used_by = Int64(len(used_by[i]))
            r.internal = _internal(o, used_by[i])
            r.stars = stars[i]
            r.forks = forks[i]
            rows.append(r^)
            continue
        if o not in at:
            var slash = repos[i].find("/").or_else(-1)
            at[o] = len(rows)
            rows.append(Depended(String(repos[i][byte=:slash], "/*"), o, True))
            users[o] = Dict[String, Bool]()
        ref r = rows[at[o]]
        # The most used first; ties keep the order of `repos`.
        var j = len(r.members)
        r.members.append(i)
        while j > 0 and len(used_by[r.members[j - 1]]) < len(used_by[i]):
            r.members[j] = r.members[j - 1]
            j -= 1
        r.members[j] = i
        r.stars += stars[i]
        r.forks += forks[i]
        for u in used_by[i]:
            users[o][u] = True
    for e in users.items():
        ref r = rows[at[e.key]]
        var us = List[String]()
        for u in e.value.keys():
            us.append(u)
        r.used_by = Int64(len(us))
        r.internal = _internal(e.key, us)
    return rows^


def most_depended(
    repos: List[String],
    used_by: List[List[String]],
    stars: List[Int64],
    forks: List[Int64],
    n: Int,
) raises -> List[Depended]:
    """The `n` rows of the home page's Most depended on: the repositories
    the most census repositories depend on (`used_by`, per repository of
    `repos`), with an owner's repositories collapsed into one `owner/*` row
    when two or more of them would be shown. The `owner/*` row counts the
    distinct repositories that depend on any of them, so a repository that
    uses five of an owner's libraries counts once.

    Collapsing frees slots that the next repositories fill, which can bring
    two of another owner's in: that owner is collapsed too, until no owner
    has two rows. Ties keep the order of `repos`."""
    var grouped = Dict[String, Bool]()
    while True:
        var rows = _depended_rows(repos, used_by, stars, forks, grouped)
        var counts = List[Int64]()
        for ref r in rows:
            counts.append(r.used_by)
        var top = top_gains(counts, n)
        var shown = Dict[String, Int]()
        var more = False
        for i in top:
            if rows[i].group:
                continue
            var c = shown.get(rows[i].owner, 0) + 1
            shown[rows[i].owner] = c
            if c == 2:
                grouped[rows[i].owner] = True
                more = True
        if not more:
            var out = List[Depended]()
            for i in top:
                out.append(rows[i].copy())
            return out^

