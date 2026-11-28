"""Mojo versions sort in one order across Modular's renumbering, and
manifests and lock files give the tooling and the version.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from versions import (
    ToolFiles,
    compare_versions,
    lock_version,
    manifest_version,
    packaging,
    pylock_version,
    pyproject_tables,
    recipe_kind,
    sort_versions,
    tooling,
    version_key,
)


def test_eras_in_order() raises:
    var vs: List[String] = [
        "1.2.0", "24.1.0", "0.26.1", "25.4", "1.0.0", "24.6", "0.25.7",
        "25.1.0", "1.1.0", "0.25.6.1", "2.0.0",
    ]
    sort_versions(vs)
    var want: List[String] = [
        "24.1.0", "24.6", "25.1.0", "25.4", "0.25.6.1", "0.25.7", "0.26.1",
        "1.0.0", "1.1.0", "1.2.0", "2.0.0",
    ]
    assert_equal(len(vs), len(want))
    for i in range(len(vs)):
        assert_equal(vs[i], want[i])


def test_renumbering_meets_itself() raises:
    # MAX 25.6 shipped Mojo 0.25.6: the same release under both numbers.
    assert_equal(compare_versions("25.6", "0.25.6"), 0)
    assert_equal(compare_versions("25.6.0", "0.25.6"), 0)
    assert_true(compare_versions("25.5", "0.25.6") < 0)
    assert_true(compare_versions("0.25.7", "25.6") > 0)


def test_dev_builds_come_before_their_release() raises:
    assert_true(compare_versions("25.4.0.dev2025050605", "25.4.0") < 0)
    assert_true(compare_versions("25.4.0.dev2025050605", "25.4.0.dev2025060105") < 0)
    assert_true(compare_versions("25.3.0", "25.4.0.dev2025050605") < 0)
    assert_true(compare_versions("1.2.0.dev2026101905", "1.2.0") < 0)
    assert_true(compare_versions("1.1.0", "1.2.0.dev2026101905") < 0)


def test_not_a_version_sorts_first() raises:
    assert_equal(len(version_key("*")), 0)
    assert_true(compare_versions("*", "24.1") < 0)
    assert_equal(compare_versions("", ""), 0)


def test_lock_version() raises:
    var lock = String(
        "version: 6\n  packages:\n",
        "  - conda: https://conda.modular.com/max-nightly/osx-arm64/max-core-25.4.0.dev2025050605-release.conda\n",
        "  - conda: https://conda.modular.com/max-nightly/osx-arm64/max-25.4.0.dev2025050605-release.conda\n",
    )
    assert_equal(lock_version(lock), "25.4.0.dev2025050605")
    var newer = String(
        "  - conda: https://conda.modular.com/max/osx-arm64/mojo-compiler-1.2.0-release.conda\n",
        "  - conda: https://conda.modular.com/max/osx-arm64/mojo-0.25.6-release.conda\n",
    )
    assert_equal(lock_version(newer), "1.2.0")
    assert_equal(lock_version("nothing here"), "")


def test_manifest_version() raises:
    assert_equal(manifest_version('[dependencies]\nmax = ">=24.5.0,<25"\n'), "24.5.0")
    assert_equal(manifest_version('[dependencies]\nmojo = "==0.25.6"\n'), "0.25.6")
    assert_equal(manifest_version('mojo-compiler = "==1.2.0"\npython = "3.12"\n'), "1.2.0")
    assert_equal(manifest_version('[dependencies]\nmax = "*"\n'), "*")
    assert_equal(manifest_version('[dependencies]\npython = "3.12"\n'), "")


def _files(
    pixi_toml: Bool = False, pixi_lock: Bool = False, mojoproject: Bool = False,
    magic_lock: Bool = False, bazel: Bool = False,
) -> ToolFiles:
    var f = ToolFiles()
    f.pixi_toml = pixi_toml
    f.pixi_lock = pixi_lock
    f.mojoproject = mojoproject
    f.magic_lock = magic_lock
    f.bazel = bazel
    return f^


def test_tooling() raises:
    assert_equal(tooling(_files()), "none")
    assert_equal(tooling(_files(mojoproject=True, magic_lock=True)), "magic")
    assert_equal(tooling(_files(pixi_toml=True, magic_lock=True)), "magic")
    assert_equal(tooling(_files(pixi_toml=True, pixi_lock=True)), "pixi")
    # ExtraMojo: moved to pixi and left its magic.lock behind.
    assert_equal(tooling(_files(pixi_toml=True, pixi_lock=True, magic_lock=True)), "pixi")
    assert_equal(tooling(_files(mojoproject=True)), "magic")
    assert_equal(tooling(_files(bazel=True)), "bazel")
    # Bazel ranks above pixi, magic and none.
    assert_equal(tooling(_files(pixi_toml=True, pixi_lock=True, bazel=True)), "bazel")
    assert_equal(tooling(_files(True, False, True, True, True)), "bazel")


def test_python_tooling() raises:
    # A Python tool counts only when a Python manifest depends on Mojo.
    var f = ToolFiles()
    f.uv_lock = True
    assert_equal(tooling(f), "none")
    f.py_mojo = True
    assert_equal(tooling(f), "uv")
    # A lock decides over the pyproject's tables.
    f.pyproject_poetry = True
    assert_equal(tooling(f), "uv")
    f.uv_lock = False
    assert_equal(tooling(f), "poetry")
    f.pyproject_poetry = False
    f.pdm_lock = True
    assert_equal(tooling(f), "pdm")
    f.pdm_lock = False
    assert_equal(tooling(f), "pip")
    # pixi in a pyproject, and any conda tool, ranks above them all.
    f.uv_lock = True
    f.pyproject_pixi = True
    assert_equal(tooling(f), "pixi")
    f.pyproject_pixi = False
    f.magic_lock = True
    assert_equal(tooling(f), "magic")


def test_pyproject_tables() raises:
    var f = ToolFiles()
    pyproject_tables(
        '[project]\nname = "x"\n[tool.uv]\ndev = 1\n[tool.pixi.dependencies]\nmojo = "*"\n[tool.pixiv]\n',
        f,
    )
    assert_true(f.pyproject_uv)
    assert_true(f.pyproject_pixi)
    assert_false(f.pyproject_poetry)
    pyproject_tables('[tool.poetry]\nname = "x"\n[tool.pdm.dev-dependencies]\n', f)
    assert_false(f.pyproject_uv)
    assert_false(f.pyproject_pixi)
    assert_true(f.pyproject_poetry)
    assert_true(f.pyproject_pdm)
    # Only `[tool.pixiv]`: no pixi.
    pyproject_tables("[tool.pixiv]\n", f)
    assert_false(f.pyproject_pixi)


def test_pylock_version() raises:
    # uv.lock (as mojo-tokenizers has it): `mojo` is a package with its
    # own sub-tables; `mojo-compiler` would win if it were there.
    var uv = String(
        'version = 1\nrequires-python = ">=3.11"\n\n',
        '[[package]]\nname = "max"\nversion = "26.1.0"\n\n',
        '[[package]]\nname = "mojo"\nversion = "1.2.0"\nsource = { registry = "https://pypi.org/simple" }\n',
        'dependencies = [\n    { name = "mojo-compiler" },\n]\n',
        '[package.metadata]\nname = "not-a-package"\nversion = "9.9"\n\n',
        '[[package]]\nname = "tokenizers"\nversion = "0.23.3"\n',
    )
    assert_equal(pylock_version(uv), "1.2.0")
    var poetry = String(
        '[[package]]\nname = "Mojo-Compiler"\nversion = "1.1.2"\n\n',
        '[[package]]\nname = "mojo"\nversion = "1.1.2"\n',
    )
    assert_equal(pylock_version(poetry), "1.1.2")
    assert_equal(pylock_version('[[package]]\nname = "numpy"\nversion = "2.1.0"\n'), "")


def test_packaging() raises:
    assert_equal(recipe_kind("recipe.yaml"), "rattler")
    assert_equal(recipe_kind("recipe/recipe.yaml"), "rattler")
    assert_equal(recipe_kind("conda.recipe/meta.yaml"), "conda-build")
    assert_equal(recipe_kind("meta.yaml"), "conda-build")
    assert_equal(recipe_kind("examples/recipe.yaml"), "")
    assert_equal(recipe_kind("recipe/sub/recipe.yaml"), "")
    assert_equal(recipe_kind("recipe.yml"), "")
    assert_equal(packaging(False, False), "none")
    assert_equal(packaging(False, True), "conda-build")
    assert_equal(packaging(True, True), "rattler")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
