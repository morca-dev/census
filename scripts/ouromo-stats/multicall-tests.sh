#!/bin/sh
# Every test in one binary, as scripts/multicall.sh does for the programs:
#   MOJO="mojo build" multicall-tests.sh DIR tests/test_a.mojo...
# writes DIR/multicall-tests and a link DIR/<test> for each.
set -eu
dir=$1; shift
gen=$PWD/build/multicall-gen/tests; rm -rf "$gen"; mkdir -p "$gen" "$dir"
main=$gen/multicall_tests_main.mojo
{
    echo 'from std.sys import argv'
    for f in "$@"; do m=$(basename "$f" .mojo); echo "from $m import main as ${m}__main"; done
    echo; echo 'def main() raises:'
    echo '    var me = String(argv()[0])'
    echo '    var slash = me.rfind("/")'
    echo '    var name = String(me[byte = slash + 1 :]) if slash >= 0 else me'
    kw=if
    for f in "$@"; do m=$(basename "$f" .mojo); echo "    $kw name == \"$m\":"; echo "        ${m}__main()"; kw=elif; done
    echo '    else:'; echo '        raise Error(name, ": not a test of this binary")'
} > "$main"
$MOJO -I tests -I src "$main" -o "$dir/multicall-tests"
for f in "$@"; do ln -sf multicall-tests "$dir/$(basename "$f" .mojo)"; done
