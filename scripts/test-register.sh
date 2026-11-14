#!/bin/sh
# Registers every census pipeline into a fresh morca state, as a deploy's
# `morca register` does, once for each config: morca.toml (production),
# morca.dev.toml (beta) and morca.lab.toml. A pipeline that can't be
# registered (a cycle through the datasets pipelines read and write, a
# partition kind that doesn't match, a bad setting) fails the run, so it
# fails CI instead of a deploy (#181's cycle failed 1.8.0's on beta).
#
# Needs `pixi run build` first, and runs inside the pixi environment:
#
#   pixi run test-register
set -eu
cd "$(dirname "$0")/.."

for config in morca.toml morca.dev.toml morca.lab.toml; do
    echo "== $config"
    work=$(mktemp -d "${TMPDIR:-/tmp}/census-register.XXXXXX")
    # A fresh state and warehouse each: nothing registered before, as on a
    # new server.
    MORCA_CONFIG=$PWD/$config MORCA_PIPELINES_DIR=$PWD/build \
        MORCA_WAREHOUSE=$work/warehouse MORCA_LOGS=$work/logs \
        sh scripts/with-postgres.sh ./build/morca register || {
        rm -rf "$work"
        echo "registering $config failed" >&2
        exit 1
    }
    rm -rf "$work"
done
