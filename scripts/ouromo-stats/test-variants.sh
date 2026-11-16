#!/bin/bash
# How to build and run the tests, timed (run inside `pixi run`, at the
# repository's root, with `ouromo` on PATH):
#
#   scripts/ouromo-stats/test-variants.sh OUT.tsv
#
#   jit            `mojo run` each test file: what `pixi run test` does
#   each           `mojo build` each test file, then run it
#   one            one multi-call binary of every test (scripts/multicall.sh),
#                  then run each test
#   each-ouromo    as `each`, with ouromo and an empty split cache
#   each-ouromo-w  the same again, the cache now warm
#   one-ouromo     as `one`, with ouromo and an empty split cache
#   one-ouromo-w   the same again, the cache now warm
#
# Mojo's own compile cache is emptied before each. One line per variant:
#   variant  build_s  run_s  total_s  failed  bytes_of_binaries
set -u
out=$1; : > "$out"
tests=$(ls tests/test_*.mojo)
sc=$(mktemp -d); logs=$(dirname "$out")/variant-logs; mkdir -p "$logs"
now() { date +%s.%N; }
fresh() { rm -rf build/tv .pixi/envs/default/share/max/cache "$HOME/.modular/cache"; mkdir -p build/tv; }
report() { printf '%s\t%.1f\t%.1f\t%.1f\t%s\t%s\n' "$1" "$2" "$3" "$(echo "$2 + $3" | bc)" "$4" "$5" | tee -a "$out"; }
runall() { # runs build/tv/<name> for every test; sets run, failed
    failed=0; s=$(now)
    for f in $tests; do n=$(basename $f .mojo); build/tv/$n >> "$logs/$1.run" 2>&1 || failed=$((failed + 1)); done
    run=$(echo "$(now) - $s" | bc)
}
jit() {
    fresh; failed=0; s=$(now)
    for f in $tests; do mojo run -I src $f >> "$logs/jit.run" 2>&1 || failed=$((failed + 1)); done
    report jit 0 "$(echo "$(now) - $s" | bc)" $failed 0
}
each() { # label compiler...
    l=$1; shift; fresh; bf=0; s=$(now)
    for f in $tests; do "$@" -I src $f -o build/tv/$(basename $f .mojo) >> "$logs/$l.build" 2>&1 || bf=$((bf + 1)); done
    b=$(echo "$(now) - $s" | bc); runall $l
    report $l $b $run "$failed(+$bf build)" "$(cat build/tv/test_* | wc -c)"
}
one() { # label compiler...
    l=$1; shift; fresh; s=$(now)
    MOJO="$*" sh "$(dirname "$0")/multicall-tests.sh" build/tv $tests > "$logs/$l.build" 2>&1; rc=$?
    b=$(echo "$(now) - $s" | bc); runall $l
    report $l $b $run "$failed(build rc $rc)" "$(stat -c %s build/tv/multicall-tests 2>/dev/null)"
}
jit
each each mojo build
one one mojo build
each each-ouromo ouromo build --split-cache-dir $sc
each each-ouromo-w ouromo build --split-cache-dir $sc
rm -rf $sc; mkdir -p $sc
one one-ouromo ouromo build --split-cache-dir $sc
one one-ouromo-w ouromo build --split-cache-dir $sc
