#!/bin/sh
# One program, built for development with `ouromo`, an experimental build of
# the 1.2.0 compiler that keeps each function's object code under
# build/.split-cache (MOJO_SPLIT_CACHE_DIR moves it) and compiles only the
# functions an edit changed:
#
#   pixi run -e ouromo dev-build pipelines/mojo_issues.mojo [mojo build flags...]
#
# writes build/mojo_issues. On Linux x86-64 a rebuild after an edit takes
# 42 s where `mojo build` takes 75 s. The binary runs a few percent slower
# and is larger, so CI, the image and the releases build with `mojo`
# (scripts/build.sh), not with this.
#
# Off for now: the only ouromo published is built on Mojo 1.2.0, which can't
# be installed beside the census's Mojo, so pixi.toml has the ouromo
# environment commented out until one built on that Mojo exists.
set -eu
src=$1
shift
mkdir -p build
out=build/$(basename "$src" .mojo)
rm -f "$out"
exec ouromo build --split-cache-dir "${MOJO_SPLIT_CACHE_DIR:-build/.split-cache}" -I src "$@" "$src" -o "$out"
