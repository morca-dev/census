"""Versions from CI, Docker, READMEs and version files; their precedence; the
estimate by date; the files worth reading.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from headversion import classify
from mojo_releases import estimate_version
from days import days_of
from versions import (
    ToolFiles,
    file_version,
    manifest_version,
    pick_version,
    pin_version,
    plausible_version,
    readme_version,
    script_version,
    source_label,
    tooling,
)


def test_plausible() raises:
    assert_true(plausible_version("24.4"))
    assert_true(plausible_version("24.4.0"))
    assert_true(plausible_version("0.7"))
    assert_true(plausible_version("0.25.6"))
    assert_true(plausible_version("1.2.0.dev2026101905"))
    assert_true(not plausible_version("2023.1"))
    assert_true(not plausible_version("24"))
    assert_true(not plausible_version("3.12"))
    assert_true(not plausible_version("22.04"))
    assert_true(not plausible_version("10.4"))
    assert_true(not plausible_version("24.9"))


def test_workflow_install() raises:
    var yml = String(
        "name: CI\n"
        "on: [push]\n"
        "jobs:\n"
        "  test:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - uses: actions/checkout@v4\n"
        "      - name: Install Mojo\n"
        "        run: |\n"
        "          curl -s https://get.modular.com | sh -\n"
        "          modular auth ${{ secrets.MODULAR_AUTH }}\n"
        "          modular install mojo==24.4.0\n"
        "      - run: mojo test\n"
    )
    assert_equal(script_version(yml), "24.4.0")
    assert_equal(pin_version("pip install max==25.1.1 numpy==1.26.4"), "25.1.1")
    assert_equal(pin_version("pixi add mojo-compiler~=1.0"), "1.0")
    assert_equal(pin_version("pip install 'max>=24.5'"), "24.5")


def test_pin_ignores_other_things() raises:
    # `max-parallel`, a variable called max, Python's max(), a Node version.
    var yml = String(
        "strategy:\n  max-parallel: 2\n  matrix:\n    node: [18.2, 20.1]\n"
        "run: python -c 'print(max(3, 4))'\n  # max == 3\n"
    )
    assert_equal(pin_version(yml), "")
    assert_equal(script_version(yml), "")
    # A modular library's version, not Mojo's.
    assert_equal(pin_version("pip install modular-utils==2.3.1"), "")


def test_env_and_inputs() raises:
    assert_equal(script_version("env:\n  MOJO_VERSION: 24.3\n"), "24.3")
    assert_equal(script_version("ARG MOJO_VERSION=24.1.1\nRUN modular install mojo\n"), "24.1.1")
    assert_equal(script_version("export MOJO_VERSION=\"0.7.0\"\n"), "0.7.0")
    var act = String(
        "      - uses: modularml/setup-mojo@v1\n"
        "        with:\n"
        "          version: 24.5\n"
        "      - run: mojo build\n"
    )
    assert_equal(script_version(act), "24.5")
    # Another action's version input isn't Mojo's.
    var other = String(
        "      - uses: actions/setup-python@v5\n        with:\n          version: 3.12\n"
    )
    assert_equal(script_version(other), "")
    assert_equal(script_version("modular install mojo\nmojo --version\n"), "")


def test_docker() raises:
    var df = String(
        "FROM ubuntu:22.04\nRUN apt-get update\nRUN modular install mojo\n"
    )
    assert_equal(script_version(df), "")
    assert_equal(script_version("FROM docker.modular.com/modular/max-nvidia-full:25.4.0\n"), "25.4.0")
    assert_equal(script_version("FROM modularml/max-pipelines:24.6\n"), "24.6")
    assert_equal(script_version("FROM modular/max-openai-api:nightly\n"), "")
    assert_equal(script_version("  image: ghcr.io/other/app:25.1\n"), "")
    var dev = String(
        '{\n  "name": "Mojo",\n  "build": {"args": {"MOJO_VERSION": "24.2"}}\n}\n'
    )
    assert_equal(script_version(dev), "24.2")


def test_readme_sentences() raises:
    assert_equal(readme_version("Requires Mojo 24.4 or later.\n"), "24.4")
    assert_equal(readme_version("This project was tested with Mojo 0.7.0 on Ubuntu.\n"), "0.7.0")
    assert_equal(readme_version("Mojo >= 24.1 is needed\n"), "24.1")
    assert_equal(readme_version("- Mojo v0.5.0\n- Python 3.10\n"), "0.5.0")
    assert_equal(readme_version("Mojo version: 24.3.0\n"), "24.3.0")
    assert_equal(readme_version("**Mojo** version 0.6.0 or newer\n"), "0.6.0")
    assert_equal(
        readme_version("![Mojo](https://img.shields.io/badge/Mojo-24.4-orange)\n"), "24.4"
    )
    assert_equal(readme_version("```\nmodular install mojo==24.1.1\n```\n"), "24.1.1")
    assert_equal(readme_version("Install Mojo 25.1 from the SDK page\n"), "25.1")


def test_readme_leaves_noise() raises:
    # News about a release, a year, a URL, and other versions.
    assert_equal(readme_version("Mojo 24.4 added a lot of new things.\n"), "")
    assert_equal(readme_version("Mojo 2023 was the year it launched.\n"), "")
    assert_equal(
        readme_version("See https://docs.modular.com/mojo/changelog#v0.7.0 for more.\n"), ""
    )
    assert_equal(readme_version("Requires Python 3.10 and numpy 1.24.\n"), "")
    assert_equal(readme_version("A fast mojo-based parser. Version 1.2.3 of the spec.\n"), "")
    assert_equal(readme_version("The mojo/24.4 directory holds the old code.\n"), "")


def test_version_files() raises:
    assert_equal(file_version("24.4\n"), "24.4")
    assert_equal(file_version("# the SDK\nv0.7.0\n"), "0.7.0")
    assert_equal(file_version("python 3.11.4\nmojo 24.3.0\n"), "24.3.0")
    assert_equal(file_version("nodejs 20.1\n"), "")


def test_precedence() raises:
    var v = pick_version("1.2.0", "1.1", "24.1", "24.2", "24.3", "24.4")
    assert_equal(v[0], "1.2.0")
    assert_equal(v[1], "lock")
    v = pick_version("", "1.1", "24.1", "24.2", "24.3", "24.4")
    assert_equal(v[1], "manifest")
    # An unpinned manifest (`*`) falls through.
    v = pick_version("", "*", "", "24.2", "24.3", "24.4")
    assert_equal(v[0], "24.2")
    assert_equal(v[1], "ci")
    v = pick_version("", "", "", "", "24.3", "24.4")
    assert_equal(v[1], "docker")
    v = pick_version("", "", "", "", "", "24.4")
    assert_equal(v[0], "24.4")
    assert_equal(v[1], "readme")
    v = pick_version("", "", "", "", "", "")
    assert_equal(v[0], "")
    assert_equal(v[1], "")


def test_pixi_without_mojo() raises:
    # modular/modular-community: a pixi workspace of build tools whose recipes
    # each pin their own Mojo. The manifest names no Mojo package: no version
    # is right, and the tooling is pixi.
    var toml = String(
        '[workspace]\nname = "modular-community"\nchannels = ["conda-forge"]\n\n'
        '[feature.build.dependencies]\nrattler-build = ">=0.30.0,<0.31"\n'
        'python = ">=3.13.0,<3.14"\nconda = ">=25.5.1,<26"\n'
    )
    assert_equal(manifest_version(toml), "")
    var f = ToolFiles()
    f.pixi_toml = True
    f.pixi_lock = True
    assert_equal(tooling(f), "pixi")


def test_source_labels() raises:
    assert_equal(source_label("pixi.lock"), "lock file")
    assert_equal(source_label("magic.lock"), "lock file")
    assert_equal(source_label("pixi.toml"), "manifest")
    assert_equal(source_label("mojoproject.toml"), "manifest")
    assert_equal(source_label("uv.lock"), "lock file")
    assert_equal(source_label("pyproject.toml"), "manifest")
    assert_equal(source_label("requirements.txt"), "manifest")
    assert_equal(source_label("ci"), "CI")
    assert_equal(source_label("readme"), "README")
    assert_equal(source_label("repo"), "the repo itself")


def _at(day: String) raises -> Int64:
    return days_of(day) * 86_400_000_000


def test_estimate_by_date() raises:
    assert_equal(estimate_version(0), "")
    assert_equal(estimate_version(_at("2023-01-01")), "")
    assert_equal(estimate_version(_at("2023-06-15")), "0.1")
    assert_equal(estimate_version(_at("2023-08-24")), "0.2")
    assert_equal(estimate_version(_at("2023-12-31")), "0.6")
    assert_equal(estimate_version(_at("2024-06-01")), "24.3")
    assert_equal(estimate_version(_at("2024-06-07")), "24.4")
    assert_equal(estimate_version(_at("2025-09-22")), "0.25.6")
    assert_equal(estimate_version(_at("2026-02-01")), "0.26.1")
    assert_equal(estimate_version(_at("2026-11-05")), "1.2")


def test_classify_files() raises:
    var paths: List[String] = [
        "README.md", "src/main.mojo", "pixi.toml", "pixi.lock", "Dockerfile",
        ".github/workflows/ci.yml", ".github/workflows/release.yaml",
        ".github/CODEOWNERS", "docs/README.md", "docker/Dockerfile.gpu",
        ".devcontainer/devcontainer.json", "requirements.txt", ".mojoversion",
        "sub/pixi.lock", "Makefile",
    ]
    var c = classify(paths)
    assert_equal(len(c.lock), 1)
    assert_equal(len(c.manifest), 2)
    assert_equal(len(c.file), 1)
    assert_equal(len(c.ci), 3)
    assert_equal(len(c.docker), 3)
    assert_equal(len(c.readme), 1)
    assert_equal(c.readme[0], "README.md")
    # mojo-tokenizers: a uv.lock is a lock file too.
    var uv: List[String] = ["pyproject.toml", "uv.lock", "recipe.yaml", "sub/uv.lock"]
    var cu = classify(uv)
    assert_equal(len(cu.lock), 1)
    assert_equal(cu.lock[0], "uv.lock")
    assert_equal(len(cu.manifest), 1)
    assert_equal(len(cu.deps), 2)
    # ExtraMojo: a magic.lock left from before pixi sorts first in the tree,
    # but pixi.lock is read first; magic.lock alone is still a lock.
    var moved: List[String] = ["magic.lock", "pdm.lock", "pixi.lock", "pixi.toml"]
    var cm = classify(moved)
    assert_equal(len(cm.lock), 3)
    assert_equal(cm.lock[0], "pixi.lock")
    assert_equal(cm.lock[1], "magic.lock")
    assert_equal(cm.lock[2], "pdm.lock")
    var magic: List[String] = ["magic.lock", "mojoproject.toml"]
    var cg = classify(magic)
    assert_equal(len(cg.lock), 1)
    assert_equal(cg.lock[0], "magic.lock")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
