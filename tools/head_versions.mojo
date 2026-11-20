"""Reads repositories' HEAD the way the mojo_versions pipeline does and prints
one tab-separated line each: repo, version, source, file, estimate, last Mojo
commit (UTC date), declared dependencies, error; then, indented, the rows of
`mojo.repo_deps` it would write.

For trying the readers on real repositories:

    pixi run mojo run -I src tools/head_versions.mojo owner/name ...

Clones into `MOJO_HISTORY_WORKDIR` (default `$TMPDIR/mojo_history`) and
removes each clone.
"""

from std.sys import argv

from deps import decode_deps
from headversion import read_head_version
from jscan import micros_to_iso


def main() raises:
    var args = argv()
    for i in range(1, len(args)):
        var h = read_head_version(String(args[i]))
        var last = String(micros_to_iso(h.last_mojo_commit)[byte=:10]) if h.last_mojo_commit > 0 else String()
        print(
            h.repo, h.version, h.source, h.file, h.estimate, last,
            h.declared_deps, h.error, sep="\t",
        )
        for ref d in decode_deps(h.deps):
            print("", d.relation, d.kind, d.name, d.dep_repo, d.section, d.file, sep="\t")
