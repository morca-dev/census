#!/bin/bash
# CI durations with and without `ouromo`, on one machine:
#
#   scripts/ouromo-stats/run.sh REPO_DIR OUROMO_BINARY OUT.tsv COMMIT...
#
# REPO_DIR is a checkout of this repository that this script moves from
# commit to commit, oldest first, always at the same path. For each commit
# it runs what CI's test job runs (`pixi run build`, `test`, `test-register`,
# `test-upgrade`) twice: with the official compiler, and with ouromo and a
# split cache that is kept from one commit to the next, as a restored CI
# cache would be. Mojo's own compile cache is emptied before each of the two,
# as on a fresh runner. One line per step goes to OUT.tsv:
#
#   commit  mode  step  seconds  exit  cache_objects  cache_mb
set -u
repo=$1; ouromo=$2; out=$3; shift 3
sc=${OUROMO_STATS_CACHE:-$(dirname "$out")/split-cache}
export OUROMO_STATS_CACHE=$sc
shim=$(cd "$(dirname "$0")" && pwd)/mojo-shim.sh
tmp=$(mktemp -d); cp "$shim" "$tmp/shim"; cp "$ouromo" "$tmp/ouromo"
mkdir -p "$sc"; : > "$out"
PIXI=${PIXI:-pixi}
now() { date +%s.%N; }
step() { # commit mode name command...
    c=$1; m=$2; n=$3; shift 3
    s=$(now); "$@" > "$logs/$c-$m-$n.log" 2>&1; rc=$?
    t=$(echo "$(now) - $s" | bc)
    printf '%s\t%s\t%s\t%.1f\t%s\t%s\t%s\n' "$c" "$m" "$n" "$t" "$rc" \
        "$(ls "$sc" | wc -l)" "$(du -sm "$sc" | cut -f1)" | tee -a "$out"
    [ $rc = 0 ] || tail -20 "$logs/$c-$m-$n.log"
}
logs=$(dirname "$out")/logs; mkdir -p "$logs"
cd "$repo" || exit 1
for commit in "$@"; do
    c=$(git rev-parse --short "$commit")
    git checkout -q --detach "$commit" || exit 1
    git clean -fdxq -e .pixi
    step "$c" - install "$PIXI" install
    bin=.pixi/envs/default/bin
    # The official binary, kept beside the shim (a hard link into pixi's
    # cache: moved, never written to).
    grep -q OUROMO-STATS-SHIM "$bin/mojo" 2>/dev/null || { rm -f "$bin/mojo.official"; cp -l "$bin/mojo" "$bin/mojo.official" 2>/dev/null || cp "$bin/mojo" "$bin/mojo.official"; }
    cp "$tmp/ouromo" "$bin/ouromo"
    tasks=$("$PIXI" task list 2>&1)
    for mode in official ouromo; do
        rm -f "$bin/mojo"
        if [ $mode = official ]; then cp -l "$bin/mojo.official" "$bin/mojo" 2>/dev/null || cp "$bin/mojo.official" "$bin/mojo"
        else cp "$tmp/shim" "$bin/mojo"; chmod +x "$bin/mojo"; fi
        rm -rf build .pixi/envs/default/share/max/cache "$HOME/.modular/cache"
        for t in build test test-register test-upgrade; do
            echo "$tasks" | grep -qw -- "$t" || continue
            step "$c" $mode $t "$PIXI" run $t
        done
        [ -e build/multicall-pipelines ] && printf '%s\t%s\tsize\t%s\t0\t-\t-\n' "$c" $mode \
            "$(( $(stat -c %s build/multicall-apps) + $(stat -c %s build/multicall-pipelines) ))" | tee -a "$out"
    done
    rm -f "$bin/mojo"; cp -l "$bin/mojo.official" "$bin/mojo" 2>/dev/null || cp "$bin/mojo.official" "$bin/mojo"
done
