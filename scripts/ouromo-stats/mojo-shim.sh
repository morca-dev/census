#!/bin/bash
# OUROMO-STATS-SHIM. Stands in for bin/mojo while scripts/ouromo-stats/run.sh
# measures CI with `ouromo`. `mojo build` becomes `ouromo build` with the
# split cache; `mojo run FILE ARGS` becomes a cached build of FILE and a run
# of the binary (the JIT cannot use the cache); anything else goes to ouromo
# unchanged.
set -eu
here=$(dirname "$0")
sc=${OUROMO_STATS_CACHE:?}
case ${1:-} in
build)
    shift
    exec "$here/ouromo" build --split-cache-dir "$sc" "$@"
    ;;
run)
    shift
    build=()
    while [ $# -gt 0 ]; do
        build+=("$1")
        case $1 in *.mojo) shift; break ;; esac
        shift
    done
    out=$(mktemp "${TMPDIR:-/tmp}/ouromo-test.XXXXXX")
    trap 'rm -f "$out"' EXIT
    "$here/ouromo" build --split-cache-dir "$sc" "${build[@]}" -o "$out"
    "$out" "$@"
    ;;
*)
    exec "$here/ouromo" "$@"
    ;;
esac
