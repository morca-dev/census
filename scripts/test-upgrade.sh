#!/bin/sh
# Dry-runs every `morca backfill` step of upgrade.toml (every version's,
# before and after) against a state where the pipelines have run before, so
# a step morca would refuse on a deploy fails CI instead (#192: 1.9.0's
# search-discovery step lacked --allow-append and was refused on beta).
#
# For morca.toml and morca.dev.toml each, in a fresh state:
# 1. registers every pipeline, as test-register.sh does;
# 2. records a succeeded run of each step's pipeline over a few keys inside
#    the step's range (its ends, or a keyed pipeline's keys), as morca's own
#    tests do (tests/calendar.sh): what morca's append and replace checks
#    look at;
# 3. runs each step with --dry-run right after `backfill` (morca 0.31.0,
#    morca #475), which makes every check and writes nothing, and fails on
#    a non-zero exit with the step's id and morca's message.
# Steps that aren't `morca backfill` (manual ones) are skipped with a note.
#
# The warehouse is empty, so a keyed pipeline's `<binary> keys` (which reads
# mojo.repos) can't answer: its binary is replaced, in the state only, by a
# wrapper that prints two repos for `keys`, and the repos any step names for
# that pipeline (a step over a few named repositories, #259), and runs the
# real one otherwise.
#
# --dry-run applies morca's pending schema migrations, so this runs only
# against the throwaway server with-postgres.sh starts. Needs `pixi run
# build` first, and runs inside the pixi environment:
#
#   pixi run test-upgrade
set -eu
cd "$(dirname "$0")/.."

if [ "${1:-}" != --inside ]; then
    status=0
    for config in morca.toml morca.dev.toml; do
        echo "== $config"
        work=$(mktemp -d "${TMPDIR:-/tmp}/census-upgrade.XXXXXX")
        MORCA_CONFIG=$PWD/$config MORCA_PIPELINES_DIR=$PWD/build \
            MORCA_HANDOVER_WAIT_SECONDS=3600 \
            MORCA_WAREHOUSE=$work/warehouse MORCA_LOGS=$work/logs \
            CENSUS_WORK=$work \
            sh scripts/with-postgres.sh sh scripts/test-upgrade.sh --inside \
            || status=1
        rm -rf "$work"
    done
    [ "$status" = 0 ] || echo "upgrade.toml's steps would be refused (above)" >&2
    exit "$status"
fi

set -f  # the steps' words aren't globs
q() { psql "$MORCA_DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc "$1"; }
work=$CENSUS_WORK
tab=$(printf '\t')

./build/morca register > "$work/register.log" 2>&1 || {
    cat "$work/register.log" >&2
    echo "registering failed" >&2
    exit 1
}

# Every version's steps: from before the first release up to the newest
# (upgrade.toml is newest first), a line each (morca upgrade's format:
# step, ids, when, run|manual, the command).
newest=$(sed -n 's/^version = "\(.*\)"$/\1/p' upgrade.toml | head -n 1)
./build/morca upgrade --file upgrade.toml --from 0.0.0 --to "$newest" > "$work/steps"
grep -q . "$work/steps" || { echo "no steps in upgrade.toml up to $newest" >&2; exit 1; }

# A keyed pipeline's wrapper: for `keys`, two keys and the ones the steps
# name for it (its lines of the seeds file, read when it runs, so the steps
# after the one that wrote it count too); the real binary otherwise.
keyed() {
    real=$(q "SELECT binary_path FROM orca.pipelines WHERE name = '$1'")
    wrapper=$work/keyed-$1
    cat > "$wrapper" <<EOF
#!/bin/sh
if [ "\$#" = 1 ] && [ "\$1" = keys ]; then
    printf '1\nmodular/modular\nmodular/mojo-gpu-puzzles\n'
    grep '^$1 ' "$work/seeds" | cut -d' ' -f2 | grep . \
        | grep -vx 'modular/modular' | grep -vx 'modular/mojo-gpu-puzzles' | sort -u
    exit 0
fi
exec "$real" "\$@"
EOF
    chmod +x "$wrapper"
    q "UPDATE orca.pipelines SET binary_path = '$wrapper' WHERE name = '$1'"
}

# The keys to record a run over for spec $2 of pipeline $1: each range's
# ends, each single key, or (keyed, @all) the wrapper's keys.
seed_keys() {
    case "$2" in
    @all) printf 'modular/modular\nmodular/mojo-gpu-puzzles\n' ;;
    @file:*) ;;
    *) echo "$2" | sed 's/\.\./,/g' | tr ',' '\n' ;;
    esac
}

# Steps' pipelines and keys, then one succeeded run of each pipeline over
# its keys, with every step succeeded for each key.
: > "$work/seeds"
while IFS="$tab" read -r _ id when kind text; do
    case "$kind $text" in
    "run morca backfill "*) ;;
    *) continue ;;
    esac
    set -- $text
    eval "pipeline=\${$(($# - 1))} spec=\${$#}"
    if [ "$(q "SELECT describe->'partitions'->>'kind' FROM orca.pipelines WHERE name = '$pipeline'")" = keyed ]; then
        grep -qx "keyed $pipeline" "$work/seeds" || {
            keyed "$pipeline"
            echo "keyed $pipeline" >> "$work/seeds"
        }
    fi
    seed_keys "$pipeline" "$spec" | sed "s|^|$pipeline |" >> "$work/seeds"
done < "$work/steps"
for pipeline in $(grep -v '^keyed ' "$work/seeds" | cut -d' ' -f1 | sort -u); do
    keys=$(grep "^$pipeline " "$work/seeds" | cut -d' ' -f2 | grep . | sort -u | paste -sd, -)
    [ -n "$keys" ] || continue
    run=$(q "INSERT INTO orca.runs (pipeline, registry_hash, partitions, trigger, status)
        SELECT name, registry_hash, '$keys', 'manual', 'succeeded' FROM orca.pipelines
        WHERE name = '$pipeline' RETURNING id") || exit 1
    q "INSERT INTO orca.steps (run, step, partition, ord, status)
        SELECT $run, x.st->>'name', k, x.n - 1, 'succeeded'
        FROM orca.pipelines p, jsonb_array_elements(p.describe->'steps') WITH ORDINALITY AS x(st, n),
            unnest(string_to_array('$keys', ',')) AS k
        WHERE p.name = '$pipeline'" || exit 1
    echo "recorded a succeeded run of $pipeline over $keys"
done

failed=0
while IFS="$tab" read -r _ id when kind text; do
    case "$kind $text" in
    "run morca backfill "*) ;;
    *)
        echo "skip $id ($when): not a morca backfill"
        continue
        ;;
    esac
    # The step's own words after `morca backfill`, with --dry-run first.
    set -- $text
    shift 2
    if out=$(./build/morca backfill --dry-run "$@" 2>&1); then
        echo "ok   $id ($when): $(echo "$out" | grep '^dry run' || echo "$out" | tail -n 1)"
    else
        code=$?
        echo "FAIL $id ($when): morca backfill --dry-run $* exited $code:" >&2
        echo "$out" | sed 's/^/    /' >&2
        failed=1
    fi
done < "$work/steps"
exit "$failed"
