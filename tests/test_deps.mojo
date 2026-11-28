"""The dependencies manifests declare, and resolving them to census repos.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from deps import (
    DEPENDS,
    PROVIDES,
    Dep,
    ForkOf,
    RepoDep,
    conda_lookups,
    declared_count,
    decode_deps,
    dedupe,
    encode_deps,
    github_repo,
    github_shorthand,
    is_recipe,
    manifest_deps,
    most_depended,
    names_mojo_pkg,
    norm_name,
    owner_of,
    resolve,
    second_degree,
    toolchain,
)
from versions import packages


def _find(rows: List[Dep], relation: String, name: String, section: String = "") -> Int:
    """The index of the first row with `relation` and `name` (and `section`
    when given), or -1."""
    for i in range(len(rows)):
        if rows[i].relation == relation and rows[i].name == name:
            if section.byte_length() == 0 or rows[i].section == section:
                return i
    return -1


comptime PIXI_BUILD = """[workspace]
authors = ["Mikhail Tavarez <miktavarez@gmail.com>"]
channels = ["conda-forge", "https://conda.modular.com/max"]
platforms = ["osx-arm64", "linux-64", "linux-aarch64"]
license = "MIT"
preview = ["pixi-build"]

[tasks]
tests = "sh -c 'for f in test/*.mojo; do mojo -I . $f; done'"
format = [{ task = "mojo_format" }]

[package]
name = "floki"
version = "0.4.1"

[package.build]
backend = { name = "pixi-build-mojo", version = "0.*", channels = [
  "https://prefix.dev/pixi-build-backends",
  "https://prefix.dev/conda-forge",
]}

[package.build.config.pkg]
name = "floki_pkg"

[dependencies]
mojo = ">=1.1.0,<1.2.0"
emberjson = { git = "https://github.com/bgreni/EmberJson.git", tag = "0.4.0" }
mojo-curl = { git = "https://github.com/thatstoasty/mojo-curl.git", tag = "v0.4.6" }
curl_wrapper = { git = "https://github.com/thatstoasty/mojo-curl.git", subdirectory = "shim", tag = "v0.4.6"  }
# mojo_datetime = { git = "https://github.com/martinvuyk/forge-tools.git" }
small_time = ">=26.2.0,<26.3"  # a comment

[package.run-dependencies]
mojo-compiler = "=1.1.0"
emberjson = { git = "https://github.com/bgreni/EmberJson.git", tag = "0.4.0" }

[feature.test.dependencies]
pytest = "*"
"local-helper" = { path = "./helper" }

[feature.test.pypi-dependencies]
requests = ">=2.31"

[target.linux-64.dependencies]
libcurl = ">=8"

[dependencies.lightbug_http]
git = "https://github.com/Lightbug-HQ/lightbug_http"
branch = "main"
"""


def test_pixi_toml() raises:
    var rows = manifest_deps("pixi.toml", PIXI_BUILD)
    var p = _find(rows, PROVIDES, "floki")
    assert_true(p >= 0)
    assert_equal(rows[p].kind, "package")
    # A build backend's or a Mojo package's `name` isn't a dependency or a
    # published name.
    assert_equal(_find(rows, PROVIDES, "floki_pkg"), -1)
    assert_equal(_find(rows, DEPENDS, "pixi-build-mojo"), -1)
    var e = _find(rows, DEPENDS, "emberjson", "dependencies")
    assert_true(e >= 0)
    assert_equal(rows[e].kind, "git")
    assert_equal(rows[e].dep_repo, "bgreni/EmberJson")
    assert_equal(rows[_find(rows, DEPENDS, "curl_wrapper")].dep_repo, "thatstoasty/mojo-curl")
    var st = _find(rows, DEPENDS, "small_time")
    assert_equal(rows[st].kind, "conda")
    assert_equal(rows[st].dep_repo, "")
    assert_equal(_find(rows, DEPENDS, "mojo_datetime"), -1)
    assert_true(_find(rows, DEPENDS, "emberjson", "package.run-dependencies") >= 0)
    assert_equal(rows[_find(rows, DEPENDS, "local-helper")].kind, "path")
    var rq = _find(rows, DEPENDS, "requests")
    assert_equal(rows[rq].kind, "pypi")
    assert_equal(rows[rq].section, "feature.test.pypi-dependencies")
    assert_true(_find(rows, DEPENDS, "libcurl", "target.linux-64.dependencies") >= 0)
    var lb = _find(rows, DEPENDS, "lightbug_http")
    assert_equal(rows[lb].kind, "git")
    assert_equal(rows[lb].dep_repo, "Lightbug-HQ/lightbug_http")
    assert_equal(rows[lb].section, "dependencies")
    # No task or channel line is taken for a dependency.
    assert_equal(_find(rows, DEPENDS, "tests"), -1)
    assert_equal(_find(rows, DEPENDS, "channels"), -1)
    # Toolchain left out, names counted once across tables.
    assert_equal(
        declared_count(rows), 9
    )  # emberjson mojo-curl curl_wrapper small_time pytest local-helper requests libcurl lightbug_http


comptime MOJOPROJECT = """[project]
authors = ["Someone <someone@example.com>"]
channels = ["conda-forge", "https://conda.modular.com/max", "https://repo.prefix.dev/modular-community"]
description = "Add a short description here"
name = "mojo-learn"
platforms = ["osx-arm64", "linux-64"]
version = "0.1.0"

[tasks]
test = "magic run mojo test"

[dependencies]
max = ">=24.5.0,<25"
numojo = ">=0.4,<0.5"
python = ">=3.11,<3.13"
"""


def test_mojoproject_toml() raises:
    var rows = manifest_deps("mojoproject.toml", MOJOPROJECT)
    var w = _find(rows, PROVIDES, "mojo-learn")
    assert_equal(rows[w].kind, "workspace")
    assert_true(_find(rows, DEPENDS, "numojo") >= 0)
    assert_true(_find(rows, DEPENDS, "max") >= 0)
    assert_equal(declared_count(rows), 2)  # numojo, python


comptime PYPROJECT = """[build-system]
requires = ["hatchling"]

[project]
name = "mojo-tools"
version = "0.2.0"
dependencies = [
    "numpy>=1.26",
    "max==25.1.0",
    "decimojo @ git+https://github.com/forfudan/decimojo.git@v0.3",
]

[project.optional-dependencies]
test = ["pytest>=8", "hypothesis"]

[tool.pixi.workspace]
channels = ["conda-forge", "https://conda.modular.com/max"]
platforms = ["linux-64"]

[tool.pixi.dependencies]
mojo = "==0.25.6"
emberjson = ">=0.2"
"""


def test_pyproject_toml() raises:
    var rows = manifest_deps("pyproject.toml", PYPROJECT)
    assert_equal(rows[_find(rows, PROVIDES, "mojo-tools")].kind, "pyproject")
    assert_equal(_find(rows, DEPENDS, "hatchling"), -1)
    var n = _find(rows, DEPENDS, "numpy")
    assert_equal(rows[n].kind, "pypi")
    assert_equal(rows[n].section, "project.dependencies")
    var d = _find(rows, DEPENDS, "decimojo")
    assert_equal(rows[d].kind, "git")
    assert_equal(rows[d].dep_repo, "forfudan/decimojo")
    assert_equal(rows[_find(rows, DEPENDS, "hypothesis")].section, "project.optional-dependencies.test")
    var e = _find(rows, DEPENDS, "emberjson")
    assert_equal(rows[e].kind, "conda")
    assert_equal(rows[e].section, "dependencies")


comptime RECIPE = """# yaml-language-server: $schema=https://raw.githubusercontent.com/prefix-dev/recipe-format/main/schema.json

context:
  version: "0.26.2.0"
  name: lightbug_http

package:
  name: ${{ name }}
  version: ${{ version }}

source:
  - path: ../lightbug_http
  - git: https://github.com/Lightbug-HQ/lightbug_http.git

build:
  number: 0
  script:
    - mkdir -p ${PREFIX}/lib/mojo
    - pixi run mojo package . -o ${PREFIX}/lib/mojo/lightbug_http.mojopkg

requirements:
  build:
    - ${{ compiler('c') }}
  host:
    - mojo-compiler =0.26.2
  run:
    - max >=0.26.2.0,<0.26.3
    - small_time >=26.2.0,<26.3
    - "emberjson >=0.3.1,<0.4"
    - if: unix
      then: libcurl
    - ${{ pin_compatible('mojo-compiler') }}
  run_constraints:
    - openssl >=3

tests:
  - script:
      - if: unix
        then:
          - python run_tests.py
    requirements:
      run:
        - pytest

about:
  homepage: https://github.com/saviorand/lightbug_http
  license: MIT
  summary: Lightbug is a simple and sweet HTTP framework for Mojo
"""


def test_recipe_yaml() raises:
    assert_true(is_recipe("recipe.yaml"))
    assert_true(is_recipe("recipes/recipe.yaml"))
    assert_true(not is_recipe("recipes/emberjson/recipe.yaml"))
    var rows = manifest_deps("recipes/recipe.yaml", RECIPE)
    var p = _find(rows, PROVIDES, "lightbug_http")
    assert_equal(rows[p].kind, "recipe")
    assert_equal(rows[_find(rows, DEPENDS, "small_time")].section, "requirements.run")
    assert_true(_find(rows, DEPENDS, "emberjson") >= 0)
    assert_true(_find(rows, DEPENDS, "mojo-compiler", "requirements.host") >= 0)
    assert_true(_find(rows, DEPENDS, "libcurl") >= 0)
    assert_true(_find(rows, DEPENDS, "pytest") >= 0)
    # Constraints, scripts, sources and Jinja aren't requirements.
    assert_equal(_find(rows, DEPENDS, "openssl"), -1)
    assert_equal(_find(rows, DEPENDS, "python"), -1)
    assert_equal(_find(rows, DEPENDS, "mkdir"), -1)
    assert_equal(declared_count(rows), 4)  # small_time emberjson libcurl pytest


def test_requirements_txt() raises:
    var rows = manifest_deps(
        "requirements.txt",
        "# pinned\n-r base.txt\nnumpy==1.26.4\nmax>=25.1 ; python_version>='3.10'\n"
        "-e git+https://github.com/owner/mojo-helpers.git#egg=mojo_helpers\n"
        "--extra-index-url https://example.com\n",
    )
    assert_true(_find(rows, DEPENDS, "numpy") >= 0)
    var h = _find(rows, DEPENDS, "mojo_helpers")
    assert_equal(rows[h].dep_repo, "owner/mojo-helpers")
    assert_equal(rows[h].kind, "git")
    assert_equal(declared_count(rows), 2)


def test_github_repo() raises:
    assert_equal(github_repo("https://github.com/bgreni/EmberJson.git"), "bgreni/EmberJson")
    assert_equal(github_repo("git+https://github.com/o/r.git@v1"), "o/r")
    assert_equal(github_repo("git@github.com:o/duckdb.mojo.git"), "o/duckdb.mojo")
    assert_equal(github_repo("https://github.com/o/r/archive/refs/tags/v1.tar.gz"), "o/r")
    assert_equal(github_repo("https://gitlab.com/o/r"), "")
    assert_equal(github_repo("https://github.com/o"), "")
    assert_equal(norm_name("Lightbug_HTTP"), "lightbug-http")


def test_encode_round_trip() raises:
    var rows = dedupe(manifest_deps("pixi.toml", PIXI_BUILD))
    var back = decode_deps(encode_deps(rows))
    assert_equal(len(back), len(rows))
    for i in range(len(rows)):
        assert_equal(back[i].name, rows[i].name)
        assert_equal(back[i].dep_repo, rows[i].dep_repo)
        assert_equal(back[i].section, rows[i].section)
    assert_equal(len(dedupe(manifest_deps("pixi.toml", String(PIXI_BUILD, "\n[dependencies]\nsmall_time = \"*\"\n")))), len(rows))


def _rows(repo: String, path: String, text: String) -> List[RepoDep]:
    var out = List[RepoDep]()
    for ref d in manifest_deps(path, text):
        out.append(RepoDep(repo, 0, d.copy()))
    return out^


def test_resolve() raises:
    var repos: List[String] = [
        "thatstoasty/floki", "bgreni/EmberJson", "Lightbug-HQ/lightbug_http",
        "thatstoasty/small-time", "Mojo-Numerics-and-Algorithms-group/NuMojo",
        "someone/mojo-learn", "modular/modular", "a/utils", "b/utils",
    ]
    var rows = _rows("thatstoasty/floki", "pixi.toml", PIXI_BUILD)
    rows.extend(_rows("Lightbug-HQ/lightbug_http", "recipes/recipe.yaml", RECIPE))
    rows.extend(_rows("someone/mojo-learn", "mojoproject.toml", MOJOPROJECT))
    # NuMojo publishes `numojo` ([package] name), not its repo's name.
    rows.append(RepoDep("Mojo-Numerics-and-Algorithms-group/NuMojo", 0, Dep(PROVIDES, "package", "numojo", "", "package", "pixi.toml")))
    # A workspace named after a template doesn't claim the name.
    rows.append(RepoDep("a/utils", 0, Dep(PROVIDES, "workspace", "python", "", "workspace", "pixi.toml")))
    rows.append(RepoDep("someone/mojo-learn", 0, Dep(DEPENDS, "conda", "utils", "", "dependencies", "pixi.toml")))
    var g = resolve(repos, rows)
    ref floki = g.depends_on["thatstoasty/floki"]
    # emberjson by URL (the case differs from the census name), lightbug by
    # its subtable's URL, small_time by the repo name; mojo-curl isn't in the
    # census; the toolchain isn't a library.
    assert_equal(len(floki), 3)
    assert_equal(floki[0], "bgreni/EmberJson")
    assert_equal(floki[1], "Lightbug-HQ/lightbug_http")
    assert_equal(floki[2], "thatstoasty/small-time")
    ref lb = g.depends_on["Lightbug-HQ/lightbug_http"]
    assert_equal(len(lb), 2)  # emberjson by name, small_time by name
    ref learn = g.depends_on["someone/mojo-learn"]
    # numojo by the name NuMojo publishes; `utils` is two repos' name, and
    # `python` a workspace name: neither resolves.
    assert_equal(len(learn), 1)
    assert_equal(learn[0], "Mojo-Numerics-and-Algorithms-group/NuMojo")
    ref eb = g.used_by["bgreni/EmberJson"]
    assert_equal(len(eb), 2)
    assert_equal(eb[0], "Lightbug-HQ/lightbug_http")
    assert_equal(eb[1], "thatstoasty/floki")
    assert_true("modular/modular" not in g.used_by)
    assert_true("thatstoasty/floki" not in g.used_by)
    assert_equal(len(g.declared["thatstoasty/floki"]), 9)


def _git(repo: String, url_repo: String) -> RepoDep:
    """`repo` depending on the GitHub repository `url_repo` by URL."""
    return RepoDep(repo, 0, Dep(DEPENDS, "git", String(url_repo.split("/")[1]), url_repo, "dependencies", "pixi.toml"))


# Mosaad-M/requests' `mojoproject.toml`: its own name, its git
# dependencies as GitHub's `owner/name` shorthand.
comptime MOSAAD_REQUESTS = """[project]
name = "requests"
channels = ["conda-forge", "https://conda.modular.com/max"]
platforms = ["osx-arm64", "linux-64"]

[package]
name = "requests"
version = "1.12.0"

[dependencies]
mojo = ">=0.26.1"
tls  = { git = "Mosaad-M/tls",      version = ">=1.12.0" }
tcp  = { git = "Mosaad-M/tcp",      version = ">=2.2.0" }
json = { git = "Mosaad-M/json",     version = ">=3.1.0" }
"""


def test_git_shorthand() raises:
    assert_equal(github_shorthand("Mosaad-M/json"), "Mosaad-M/json")
    assert_equal(github_shorthand(" o/duckdb.mojo.git "), "o/duckdb.mojo")
    # Not a shorthand: a URL, a path, a host, two slashes, an owner GitHub
    # wouldn't allow.
    assert_equal(github_shorthand("https://example.com/o/r"), "")
    assert_equal(github_shorthand("../json"), "")
    assert_equal(github_shorthand("./json"), "")
    assert_equal(github_shorthand("gitlab.com/o/r"), "")
    assert_equal(github_shorthand("o/r/x"), "")
    assert_equal(github_shorthand("o_x/r"), "")
    assert_equal(github_shorthand("-o/r"), "")
    assert_equal(github_shorthand("o/"), "")
    assert_equal(github_shorthand("/r"), "")
    assert_equal(github_shorthand("json"), "")
    var rows = manifest_deps("mojoproject.toml", MOSAAD_REQUESTS)
    var j = _find(rows, DEPENDS, "json")
    assert_equal(rows[j].kind, "git")
    assert_equal(rows[j].dep_repo, "Mosaad-M/json")
    assert_equal(rows[_find(rows, DEPENDS, "tls")].dep_repo, "Mosaad-M/tls")


def test_git_never_by_name() raises:
    var repos: List[String] = ["ehsanmok/json", "Mosaad-M/requests", "Mosaad-M/tls", "Mosaad-M/tcp"]
    # As read now: `json` names Mosaad-M/json, which isn't in the census;
    # tls and tcp are.
    var rows = _rows("Mosaad-M/requests", "mojoproject.toml", MOSAAD_REQUESTS)
    var g = resolve(repos, rows)
    ref req = g.depends_on["Mosaad-M/requests"]
    assert_equal(len(req), 2)
    assert_equal(req[0], "Mosaad-M/tcp")
    assert_equal(req[1], "Mosaad-M/tls")
    assert_true("ehsanmok/json" not in g.used_by)
    # As stored before the shorthand was read: a git row with no
    # repository doesn't fall back to its name.
    var old = List[RepoDep]()
    old.append(RepoDep("Mosaad-M/requests", 0, Dep(DEPENDS, "git", "json", "", "dependencies", "mojoproject.toml")))
    assert_equal(len(resolve(repos, old).used_by), 0)
    # Mosaad-M/json a fork of ehsanmok/json would roll up into it.
    var forks = Dict[String, ForkOf]()
    forks["mosaad-m/json"] = ForkOf("ehsanmok/json", "ehsanmok/json")
    var f = resolve(repos, rows, forks)
    assert_equal(len(f.via_forks["ehsanmok/json"]), 1)


def test_pypi_by_pyproject_only() raises:
    var repos: List[String] = [
        "Mosaad-M/requests", "RalphWalters/MojoX", "abhisheksreesaila/omxcore", "a/app",
    ]
    var rows = List[RepoDep]()
    # Mosaad-M/requests publishes `requests` as a pixi package; PyPI's
    # `requests` isn't it.
    rows.append(RepoDep("Mosaad-M/requests", 0, Dep(PROVIDES, "package", "requests", "", "package", "mojoproject.toml")))
    # omxcore publishes `mxframe` from its pyproject: that can be PyPI's.
    rows.append(RepoDep("abhisheksreesaila/omxcore", 0, Dep(PROVIDES, "pyproject", "mxframe", "", "project", "pyproject.toml")))
    rows.extend(_rows("a/app", "requirements.txt", "requests>=2\nmojox\n"))
    rows.append(RepoDep("a/app", 0, Dep(DEPENDS, "pypi", "MXFrame", "", "pypi-dependencies", "pixi.toml")))
    var g = resolve(repos, rows)
    # Not `requests` by the published name, not `mojox` by the repo's name.
    ref app = g.depends_on["a/app"]
    assert_equal(len(app), 1)
    assert_equal(app[0], "abhisheksreesaila/omxcore")
    assert_true("Mosaad-M/requests" not in g.used_by)
    assert_true("RalphWalters/MojoX" not in g.used_by)
    # The same names as conda packages still resolve (none is conda-forge's
    # here).
    var conda = List[RepoDep]()
    conda.append(rows[0].copy())
    conda.append(RepoDep("a/app", 0, Dep(DEPENDS, "conda", "requests", "", "dependencies", "pixi.toml")))
    conda.append(RepoDep("a/app", 0, Dep(DEPENDS, "conda", "mojox", "", "dependencies", "pixi.toml")))
    assert_equal(len(resolve(repos, conda).depends_on["a/app"]), 2)


def _conda(repo: String, name: String) -> RepoDep:
    """`repo` depending on the conda package `name`."""
    return RepoDep(repo, 0, Dep(DEPENDS, "conda", name, "", "dependencies", "pixi.toml"))


def test_conda_forge_names() raises:
    var repos: List[String] = [
        "ehsanmok/sqlite", "bgreni/EmberJson", "Lightbug-HQ/lightbug_http",
        "Mosaad-M/requests", "a/app", "b/app",
    ]
    var rows = List[RepoDep]()
    rows.append(RepoDep("ehsanmok/sqlite", 0, Dep(PROVIDES, "package", "sqlite", "", "package", "pixi.toml")))
    rows.append(RepoDep("bgreni/EmberJson", 0, Dep(PROVIDES, "recipe", "emberjson", "", "package", "recipe.yaml")))
    rows.append(RepoDep("Mosaad-M/requests", 0, Dep(PROVIDES, "package", "requests", "", "package", "mojoproject.toml")))
    rows.append(_conda("a/app", "sqlite"))
    rows.append(_conda("a/app", "emberjson"))
    rows.append(_conda("a/app", "Lightbug_HTTP"))
    rows.append(_conda("b/app", "requests"))
    rows.append(_conda("b/app", "numpy"))
    # ehsanmok/sqlite's own name isn't a dependency of it.
    rows.append(_conda("ehsanmok/sqlite", "sqlite"))
    # Without the conda-forge fact (mojo.dep_names empty, or no answer
    # yet): as before.
    var before = resolve(repos, rows)
    assert_equal(len(before.depends_on["a/app"]), 3)
    assert_equal(len(before.used_by["ehsanmok/sqlite"]), 1)
    assert_equal(len(before.used_by["Mosaad-M/requests"]), 1)
    # The names to ask about: those that resolve by name; numpy doesn't.
    var ask = conda_lookups(repos, rows)
    assert_equal(len(ask), 4)
    assert_true("sqlite" in ask and "emberjson" in ask and "requests" in ask)
    ref lb = ask["lightbug-http"]
    assert_equal(len(lb), 2)
    assert_equal(lb[0], "lightbug-http")
    assert_equal(lb[1], "lightbug_http")
    assert_true("numpy" not in ask)
    # With it: sqlite and requests are conda-forge's; emberjson and
    # lightbug_http (on modular-community) still resolve.
    var forge = Dict[String, Bool]()
    forge["sqlite"] = True
    forge["requests"] = True
    var g = resolve(repos, rows, conda_forge=forge)
    ref app = g.depends_on["a/app"]
    assert_equal(len(app), 2)
    assert_equal(app[0], "bgreni/EmberJson")
    assert_equal(app[1], "Lightbug-HQ/lightbug_http")
    assert_true("ehsanmok/sqlite" not in g.used_by)
    assert_true("Mosaad-M/requests" not in g.used_by)
    assert_true("b/app" not in g.depends_on)
    # A URL still resolves whatever the name.
    rows.append(RepoDep("b/app", 0, Dep(DEPENDS, "git", "sqlite", "ehsanmok/sqlite", "dependencies", "pixi.toml")))
    assert_equal(len(resolve(repos, rows, conda_forge=forge).used_by["ehsanmok/sqlite"]), 1)


def test_modular_packages() raises:
    # Everything conda.modular.com publishes is the toolchain, and the
    # lock-file packages keep their order.
    for n in [
        "max", "max-all", "max-benchmark", "max-core", "max-pipelines",
        "max-python", "max-serve", "mblack", "modular", "mojo",
        "mojo-compiler", "mojo-dev", "mojo-jupyter", "mojo-python", "Mojo_Python",
    ]:
        assert_true(toolchain(n), n)
    assert_true(not toolchain("mojo-learn"))
    assert_true(not toolchain("emberjson"))
    var p = packages()
    assert_equal(len(p), 5)
    assert_equal(p[0], "mojo-compiler")
    assert_equal(p[4], "modular")
    # Maucalderondelab/mojo-python isn't the dependency `mojo-python`.
    var repos: List[String] = ["Maucalderondelab/mojo-python", "larsbx/finite-math-kernels"]
    var rows = List[RepoDep]()
    rows.append(_conda("larsbx/finite-math-kernels", "mojo-python"))
    var g = resolve(repos, rows)
    assert_equal(len(g.used_by), 0)
    assert_true("larsbx/finite-math-kernels" not in g.declared)
    # A pyproject that names only mojo-jupyter doesn't install Mojo.
    assert_true(not names_mojo_pkg("requirements.txt", "mojo-jupyter\n"))
    assert_true(names_mojo_pkg("requirements.txt", "mojo>=0.26\n"))


def test_fork_roll_up() raises:
    var repos: List[String] = ["up/lib", "a/app", "b/app", "c/app", "d/app"]
    var rows = List[RepoDep]()
    # a/app uses the library itself; b/app a direct fork of it; c/app a
    # fork of that fork (its source is up/lib, its parent isn't a census
    # repo); d/app both the library and a fork, which makes it direct.
    rows.append(_git("a/app", "up/lib"))
    rows.append(_git("b/app", "B/lib"))
    rows.append(_git("c/app", "c/lib"))
    rows.append(_git("d/app", "up/lib"))
    rows.append(_git("d/app", "b/lib"))
    # A fork of a repository outside the census, and a fork of the census
    # repo that depends on it, roll up to nothing.
    rows.append(_git("a/app", "x/other"))
    rows.append(_git("up/lib", "e/fork-of-up"))
    var forks = Dict[String, ForkOf]()
    forks["b/lib"] = ForkOf("up/lib", "up/lib")
    forks["c/lib"] = ForkOf("b/lib", "UP/lib")
    forks["x/other"] = ForkOf("y/other", "y/other")
    forks["e/fork-of-up"] = ForkOf("up/lib", "up/lib")
    var g = resolve(repos, rows, forks)
    ref users = g.used_by["up/lib"]
    assert_equal(len(users), 4)
    assert_equal(users[0], "a/app")
    assert_equal(users[3], "d/app")
    ref via = g.via_forks["up/lib"]
    assert_equal(len(via), 2)
    assert_equal(via[0], "b/app")
    assert_equal(via[1], "c/app")
    assert_equal(len(g.depends_on["c/app"]), 1)
    assert_equal(g.depends_on["c/app"][0], "up/lib")
    assert_true("up/lib" not in g.depends_on)
    assert_equal(len(g.depends_on["a/app"]), 1)
    # Without the forks, only the direct ones.
    var plain = resolve(repos, rows)
    assert_equal(len(plain.used_by["up/lib"]), 2)
    assert_true("up/lib" not in plain.via_forks)


def test_second_degree() raises:
    var repos: List[String] = ["x/core", "a/mid", "b/mid", "c/top", "d/top", "e/both", "f/far"]
    var rows = List[RepoDep]()
    rows.append(_git("a/mid", "x/core"))
    rows.append(_git("b/mid", "x/core"))
    # c/top is reachable two ways (through a/mid and b/mid): counted once.
    rows.append(_git("c/top", "a/mid"))
    rows.append(_git("c/top", "b/mid"))
    rows.append(_git("d/top", "b/mid"))
    # e/both depends on x/core directly too: not second degree.
    rows.append(_git("e/both", "x/core"))
    rows.append(_git("e/both", "a/mid"))
    # f/far is third degree: left out.
    rows.append(_git("f/far", "c/top"))
    # A cycle: x/core depends on c/top, which depends on it through a/mid.
    rows.append(_git("x/core", "c/top"))
    var g = resolve(repos, rows)
    ref s = g.second["x/core"]
    assert_equal(len(s), 2)
    assert_equal(s[0], "c/top")
    assert_equal(s[1], "d/top")
    assert_equal(len(g.used_by["x/core"]), 3)
    # c/top's dependents are f/far and x/core; through x/core come a/mid,
    # b/mid and e/both, and through f/far nothing. c/top itself isn't its
    # own second degree, though x/core leads back to it.
    ref sc = g.second["c/top"]
    assert_equal(len(sc), 3)
    assert_equal(sc[0], "a/mid")
    assert_equal(sc[1], "b/mid")
    assert_equal(sc[2], "e/both")
    # Nobody depends on f/far.
    assert_true("f/far" not in g.second)
    # A two-repo cycle: each other's direct dependent, no second degree.
    var used = Dict[String, List[String]]()
    used["p/one"] = ["p/two"]
    used["p/two"] = ["p/one"]
    assert_equal(len(second_degree("p/one", used)), 0)


def test_most_depended() raises:
    # `a`'s repositories use each other; `A/two` is the same owner as `a/one`.
    var repos: List[String] = ["a/one", "A/two", "b/lib", "a/three", "c/x", "c/y", "d/z"]
    var used_by: List[List[String]] = [
        ["A/two", "a/three", "e/app"],
        ["a/three", "e/app", "f/app"],
        ["e/app", "f/app"],
        [],
        ["c/y", "e/app"],
        ["e/app"],
        ["e/app"],
    ]
    var stars: List[Int64] = [5, 1, 9, 0, 2, 3, 4]
    var forks: List[Int64] = [1, 2, 0, 0, 0, 1, 0]
    assert_equal(owner_of("A/two"), "a")
    # a/one and A/two would both be in the top 3: one row for `a`, counting
    # the four distinct repos that use either, two of them `a`'s own.
    var top = most_depended(repos, used_by, stars, forks, 3)
    assert_equal(len(top), 3)
    assert_equal(top[0].name, "a/*")
    assert_true(top[0].group)
    assert_equal(top[0].used_by, 4)
    assert_equal(top[0].internal, 2)
    assert_equal(len(top[0].members), 2)
    assert_equal(top[0].members[0], 0)
    assert_equal(top[0].stars, 6)
    assert_equal(top[0].forks, 3)
    assert_equal(top[1].name, "b/lib")
    assert_true(not top[1].group)
    assert_equal(top[1].used_by, 2)
    assert_equal(top[1].internal, 0)
    assert_equal(top[1].stars, 9)
    assert_equal(top[2].name, "c/x")
    assert_equal(top[2].internal, 1)
    # A fourth slot brings c/y in beside c/x: `c` is collapsed in turn and
    # the slot goes to d/z.
    top = most_depended(repos, used_by, stars, forks, 4)
    assert_equal(len(top), 4)
    assert_equal(top[2].name, "c/*")
    assert_equal(top[2].used_by, 2)
    assert_equal(top[2].internal, 1)
    assert_equal(top[2].stars, 5)
    assert_equal(top[3].name, "d/z")
    # Nothing depended on: no rows.
    var none: List[List[String]] = [[], [], [], [], [], [], []]
    assert_equal(len(most_depended(repos, none, stars, forks, 10)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
