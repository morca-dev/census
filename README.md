# mojo-census

The code behind [Mojourney: the Mojo ecosystem census](https://mojourney.dev).

A lake of GitHub activity built on [magmalake](https://magmalake.org), and
a console that shows how Mojo repos have grown. Everything is Mojo, in
one pixi project: five [morca](https://github.com/morca-dev/morca)
pipelines write Iceberg tables, the project's own `morca` schedules them,
and a [flare](https://github.com/magmalake/flare_mlake) app reads the
tables.

It runs on AWS: the console is at <https://mojourney.dev>, and morca's UI,
with every run, log and table, at <https://orca.mojourney.dev>. The
[getting-started guide](https://mlake.dev/getting-started/) builds it two
ways, with an agent from [PROMPT.md](PROMPT.md) or step by step.

```
GH Archive ──gharchive──▶ gharchive.events ──mojo_repos──▶ mojo.repos ─┬──────────┐
 (daily, 03:00 UTC,         (by day)    │    (sensor on    mojo.checked │          │
                            + .candidates,  │    .candidates)                │          │
                            .repo_hour,     │                                │          │
                            .releases       │                                │          │
  a dista task per hour)                │                               │          │
                                        └──mojo_activity──▶ mojo.activity          │
                                           (sensor on both; mojo.releases          │
                                            a dista task    mojo.activity_repos    │
                                            per day read)        (by month)        │
                            mojo.commits ◀──mojo_history───────────────────────────┤
                            mojo.migrations  (keyed by repository, 50 a run,       │
                            mojo.tags         a dista task per clone)              │
                            mojo.repo_stats ◀──mojo_stats──────────────────────────┘
                              (by month)       (daily 06:00 UTC, GitHub API)
                                   │
                                   └──mojo_embed──▶ mojo.repo_embeddings
                                      (daily 07:00 UTC, reads mojo.repos too;
                                       bge-small on the CPU, changed text only)
                                   │
                                   ▼
                          bin/console (flare)
```

- **`pipelines/gharchive.mojo`**: each day of [GH Archive](https://www.gharchive.org/)
  from 2023-01-01, at 03:00 UTC for the day before, into `gharchive.events`
  (`id`, `type`, `created_at`, `repo`, `actor`, `payload` as JSON text),
  partitioned by day. A day's hours are dista tasks: each streams its
  hour in on a reader thread while it gunzips and parses what has
  arrived, a window at a time, and writes the Parquet files on the worker
  (a 50,000-row file at a time, sorted by repository and type, in 16 MB row
  groups, so an hour in flight takes about 450 MB:
  `tools/hour_memory.mojo` measures it); the step commits each hour's files
  to the events as one append, in order, and a retry skips the hours already
  committed. A new run of a day that has rows (`morca backfill --rerun`)
  replaces them: its first hour's commit removes the day's earlier files.
  While an hour's task parses its events it also builds three small tables'
  rows: `gharchive.candidates` (one row per repository, hour and reason: the
  `detect.scan_event` rules below), `gharchive.repo_hour` (the counts
  `mojo.activity` needs, per repository, actor and hour, of **every**
  repository: about 100K rows an hour, sorted, so a repository found later
  has its whole history without reading events again) and `gharchive.releases`
  (published ReleaseEvents). The step keeps those files and commits each of
  the three tables **once a day**, at the end, with all the hours' files (the
  day's first commit to each replaces the day's earlier files, as for the
  events). That is one snapshot a table instead of 24, which took about 40 s
  of a day's 80. A retry that skips hours of events committed by the failed
  attempt builds their rows again from `gharchive.events` (the code
  gharchive_index uses), and finds the day's index commits if the attempt
  made them, so they aren't made twice. A day with no rows at all for a
  table gets one row for no repository (`repo = ""`), since a snapshot needs
  a data file. `GHARCHIVE_EVENTS=off` keeps the three tables and drops the
  events ("Without the events" below).
- **`pipelines/gharchive_index.mojo`**: a one-off that fills those three
  tables for days loaded before gharchive wrote them, reading each hour of
  `gharchive.events` once (`morca backfill gharchive_index <days>`).
- **`pipelines/mojo_repos.mojo`**: a sensor on `gharchive.candidates` (and
  `mojo.repo_stats`, for renamed repositories' names). For each
  day it reads the candidates (repository names, the `language` of repository
  objects that pull-request and fork payloads embed, commit messages
  naming `.mojo`/`.🔥` files or `mojoproject.toml`) and checks them with
  GitHub (`language: Mojo`, a `pixi.toml` or `mojoproject.toml` naming a
  Mojo package, or the pushed commit's files). Mojo repositories go into
  `mojo.repos` (created, first seen, how found, stars, forks, license,
  default branch, description, size, topics); every answer goes into
  `mojo.checked`, so a repository is asked about once. Forks are left out,
  and so is a repository it has under another name (renamed or transferred,
  by name or GitHub's repo id; see mojo_stats).
- **`pipelines/mojo_history.mojo`**: keyed by repository (the `repo`
  column of `mojo.repos`, `owner/name`), 50 a run, and a sensor on
  `mojo.repos`: each snapshot mojo_repos commits starts runs for the
  repositories it adds. Each repository is cloned in a
  dista task and its first-parent history read into `mojo.commits` (lines
  and files of Mojo at each commit, the tooling (none, magic, pixi, bazel,
  or a Python build tool that installs Mojo from PyPI: uv, poetry, pdm,
  pip), the packaging (a rattler-build `recipe.yaml`, a conda-build
  `meta.yaml`, or none) and the Mojo version the lock file or manifest
  names), `mojo.migrations` (each change of tooling, packaging or Mojo
  version) and `mojo.tags` (each git tag: the commit, annotated or not, its
  date, and the tooling, packaging and Mojo version at that commit). A repository already in a table isn't written to it
  again; one with a history and no tags is cloned without file contents
  for its tags only, so `morca backfill --rerun mojo_history @all` fills
  `mojo.tags` for repositories read before tags were.
- **`pipelines/mojo_retool.mojo`**: a one-off that re-reads the histories
  mojo_history already read and replaces their rows (used when `tooling`
  learned `bazel`, a root `MODULE.bazel`/`WORKSPACE`/`BUILD.bazel`, which
  outranks pixi, and again for the Python build tools and `packaging`:
  `morca backfill --rerun mojo_retool @all`).
- **`pipelines/mojo_versions.mojo`**: keyed by repository like mojo_history
  (50 a run, a sensor on `mojo.repos`), for the repositories whose lock file
  and manifest name no Mojo version (early projects, installed with `modular
  install mojo` before magic and pixi: 105 of 211 in 2026-11). Each is
  cloned without file contents and its HEAD read for a version: lock file,
  manifest (also `pyproject.toml`, `requirements.txt`), a version file,
  CI workflows, Dockerfiles and dev containers, README, in that order of
  precedence (`versions.mojo`: `script_version`, `readme_version`,
  `pick_version`); `modular/modular` states its own in `Mojo/pixi.lock`.
  `mojo.repo_versions` has one row each: the version and its source (`lock`,
  `manifest`, `file`, `ci`, `docker`, `readme`, `repo`) and the file, and
  apart from them the release current at the last commit that touched a
  Mojo file (`version_estimate`, source `date`, from the table in
  `mojo_releases.mojo`). Rows are replaced like mojo_retool's, so
  `morca backfill --rerun mojo_versions @all` fills the repositories already
  in the lake and a rerun gives the same rows. The console shows the
  detected version with its source ("24.4, from CI"), `no-manifest` apart
  from `unknown`, and the estimate as "~24.3 by date" (the Overview's donuts
  and `/repos?version=` count it with `?estimate=1`, off by default).
  The same read collects the dependencies HEAD's manifests declare
  (`deps.mojo`: the root `pixi.toml`, `mojoproject.toml`, `pyproject.toml`,
  `requirements*.txt`, and a `recipe.yaml` at the root or in `recipe/`,
  `recipes/`, `conda/`) into `mojo.repo_deps`: a row per dependency
  (`depends`, with its table, kind `conda`/`pypi`/`git`/`url`/`path`, and
  the `owner/name` of a GitHub URL) and per name the repository publishes
  (`provides`: `[package]`, recipe, pyproject or workspace name), replaced
  with its `mojo.repo_versions` row, whose `declared_deps` counts them
  (toolchain left out; null for a row read before dependencies were). The
  console resolves them to census repositories at each build
  (`deps.resolve`: GitHub URL, then a published package name, then a unique
  repository name) and shows "Depends on" (Mojo libraries, of the declared
  total) and "Used by" on each repo page, a Used by column in the Repos
  table and "Most depended on" on the Overview. "Used by" counts a
  repository that depends on a fork of the library (`mojo.dep_forks`, from
  mojo_stats) as one of its dependents, and the repo page and
  `/api/repos/...` give those (`used_by_forks`) and the second degree, the
  repositories that depend on it through its dependents (`second_degree`). To fill them for the
  repositories read before (new ones get them from their first run), after
  deploying the image: `docker exec scheduler morca register` (the step now
  reads and writes `mojo.repo_deps`), then `docker exec scheduler morca
  backfill --rerun mojo_versions @all` (runs of 50; the console picks the
  rows up at its next refresh).
  `tools/head_versions.mojo` tries the readers on named repositories and
  prints the dependency rows.
- **`pipelines/mojo_activity.mojo`**: daily, a sensor on
  `gharchive.repo_hour`, `gharchive.releases`, `mojo.repos` and
  `mojo.repo_stats` (for renamed repositories' new names), no API calls
  and no event bytes. For each day, every repository in
  `mojo.repos`: `mojo.activity` (events, stars as WatchEvents, forks,
  published releases, issues and pull requests opened, pushes, distinct
  actors) and `mojo.releases` (tag, name, published, prerelease), both by
  month. A repository not yet in `mojo.activity_repos` is caught up: the
  run also reads every other day `gharchive.repo_hour` has (from the day the
  repository was created) for it, a dista task a day, so a repository
  found today has its whole history. A run replaces the rows of the
  (repository, day) pairs it computed and keeps the rest, one run at a
  time, so reruns don't duplicate rows.
- **`pipelines/mojo_stats.mojo`**: daily at 06:00 UTC (daily partitions
  from 2026-11-08), one `GET /repos/{owner}/{repo}` per repository in
  `mojo.repos` into `mojo.repo_stats` (stars, forks, open issues, watchers,
  topics, archived, last push, homepage, license, description, size), by
  month of `as_of`, so stars become a time series. A repository that is
  gone, blocked or renamed is a row with that `state`, a renamed or
  transferred one's with its new name (`renamed_to`), and every answer
  with GitHub's `repo_id`. `src/names.mojo` joins a repository's names
  from these rows (the tables stay keyed by the name it was found under):
  the console shows it under its current name, redirects its old
  `/repos/` and `/api/repos/` links, searches and resolves dependencies by
  every name, and mojo_activity counts the events of each name it had. A rate limit is
  waited out by `Retry-After` / `X-RateLimit-Reset`. A rerun of a day
  replaces that day's rows. Then it asks once about each GitHub repository
  that `mojo.repo_deps` names and `mojo.repos` doesn't have, and keeps
  whether it is a fork, its `parent` and its `source` in `mojo.dep_forks`.
- **`pipelines/mojo_embed.mojo`**: daily at 07:00 UTC (daily partitions
  from 2026-11-10), a sentence embedding of each repository's name,
  description and topics into `mojo.repo_embeddings` (384 float32 values,
  L2-normalized, as `binary`; a renamed repository's under its new name), with
  [encoder.mojo](https://github.com/magmalake/encoder.mojo) running
  `BAAI/bge-small-en-v1.5` in the step's process (no Python, no dista). The
  text is `mojo.repos`'s, overridden by the latest `ok` row of
  `mojo.repo_stats`. Only the repositories whose text or model changed are
  embedded again (`input_hash`), so most runs embed a few or none and
  commit nothing. All 1,216 repositories take about 2 s on an M4 and about
  7 s on four arm64 cores. The model isn't in the image: a run downloads
  what `MOJO_EMBED_MODEL` lacks (133 MB) from Hugging Face, pinned to a
  revision, and checks the weights' hash (`model_rev`).
- **`pipelines/mojo_live.mojo`**: hourly partitions (morca `Hourly`), one run
  an hour that polls every 20 minutes until the hour ends: GitHub's GraphQL
  API gives the default-branch heads of 100 repositories a query (1 point),
  and each repository whose head moved gives its latest commits. The new
  ones go to `mojo.live_commits` with the time the poll saw them, the heads
  to `mojo.live_heads`. The console's `/live` page reads the last two days
  of it every minute.
- **`bin/console.mojo`**: an overview (`/`: repos, commits and lines of
  Mojo with their change over 30 days, repos per Mojo version family,
  monthly curves from `mojo.commits`, adoption of the newest version,
  tooling share, the repos rising in stars), the repos by size and age
  (`/repos`, sortable by lines, files or stars with `?sort=`, filterable
  with `?version=1.x` and `?active=1y`), search by name, topic or
  description (`/search`), the Mojo versions they moved to over time
  (`/migrations`), and a page per repository (`/repos/<owner>/<name>`:
  current stars, forks and topics from the latest `mojo.repo_stats` row,
  stars per month from `mojo.activity`, releases and tags), each also as
  JSON under `/api/` (`/api/overview`, `/api/repos`, `/api/repos?q=`, ...),
  and `/llms.txt`, `/llms-full.txt`, `/sitemap.xml` and `/robots.txt` for
  crawlers and language models, all written from `src/console_pages.mojo`'s
  list of pages (`tests/test_console_routes.mojo` checks it against the
  routes). The repos and
  the overview are computed once and kept in memory; the tables' current
  snapshots are checked every five minutes and everything is read again
  only when one moved.
- **`src/`**: the tables (`lake.mojo`), the JSON scanner, HTTP, detection, git history, and `versions.mojo`, which orders Mojo versions
  across Modular's renumbering (24.x, 25.x, 0.25.x, 0.26.x, 1.x);
  `tests/test_versions.mojo` tests that order. `activity.mojo` counts a
  day's events, `stats.mojo` reads GitHub's repository JSON, and
  `replace.mojo` replaces a table's rows by partition. `overview.mojo` computes the
  Overview's numbers, `listing.mojo` the Repos table's sorting and filters,
  and `charts.mojo` draws the SVG charts.
- **`tools/drop_run.mojo`**: removes the rows one morca run appended to one
  partition (how 2026-10-13, loaded twice before gharchive replaced a
  rerun's day, was repaired).

What the magmalake libraries were missing while this was built is tracked as
GitHub issues in each library's repository (morca, iceberg.mojo,
dista.mojo, json_mlake, flare_mlake, deflate.mojo, threads.mojo, and mojoshelf);
the census's own open work is in [this repository's issues](https://github.com/morca-dev/census/issues).

## Run it locally

[Develop locally](https://mlake.dev/getting-started/develop) on mlake.dev
covers this section with timings, what needs the network, and how to try a
change to morca, iceberg or parquet in the census before it is released. It
builds for macOS arm64 and linux-aarch64 (`pixi.toml`'s platforms); there is
no linux-64 build. The first `pixi run build` compiles every dependency and
takes about nine minutes and 19 GB under `.pixi` (`.pixi/bld`, 18 GB of it, is
build scratch).

You need [pixi](https://pixi.sh) and the mojoshelf CLI (`pixi global install
--channel https://mojoshelf.org/channel mojoshelf`). Build inside the pixi
environment; the built binaries also run from a plain shell (since
zstd-mojo 0.1.5 they find their shared libraries without `CONDA_PREFIX`),
though Postgres and `git` come from the pixi environment.

```sh
pixi run build      # build/morca, build/console, build/{gharchive,mojo_repos,...}: links to two multi-call binaries
pixi run build-gharchive   # one program alone (build-morca, build-console, build-mojo-stats...)
pixi run test       # version ordering, history and tag parsing, events, activity, GitHub stats
```

### The console on the deployed data

The quickest way to try a console change: build it and point it at the
warehouse the AWS pipelines write. It only reads. The S3 client takes
credentials from the environment, so export your AWS login first:

```sh
pixi run build-console
eval "$(aws configure export-credentials --profile <profile> --format env)"
export AWS_REGION=us-east-2
MORCA_WAREHOUSE=s3://mlake-public-617847241090/warehouse PORT=8080 pixi run ./build/console
```

### The pipelines on their own

`pixi run test-daily` (network, three hours of GH Archive, about 50 seconds)
checks gharchive's day commits against a gharchive that commits an hour at a
time, through a failed-and-retried step and a rerun, and the same with
`GHARCHIVE_EVENTS=off` (`scripts/test-daily.sh`).
It needs that older build as `build/gharchive-main`, and `origin/main` no
longer is one (it already commits daily, and the check fails with "old
gharchive.candidates: not three snapshots"). Build the commit before the
change:

```sh
mkdir -p build/main-src && git archive 8922605~1 | tar -x -C build/main-src
pixi run mojo build -I build/main-src/src build/main-src/pipelines/gharchive.mojo -o build/gharchive-main
pixi run test-daily
```

No database needed; `GHARCHIVE_HOURS` keeps the download to two hourly files
(about 100 MB each):

```sh
export MORCA_WAREHOUSE=$PWD/build/warehouse
GHARCHIVE_HOURS=15,17 pixi run ./build/gharchive run --partitions 2024-06-12
pixi run ./build/mojo_repos run --partitions 2024-06-12
MOJO_HISTORY_MAX_KB=100000 pixi run ./build/mojo_history run --partitions @all
pixi run ./build/mojo_activity run --partitions 2024-06-12
pixi run ./build/mojo_versions run --partitions @all
pixi run ./build/mojo_stats run --partitions $(date +%F)   # GITHUB_TOKEN helps
pixi run ./build/mojo_embed run --partitions $(date +%F)   # downloads the model once
PORT=8080 pixi run ./build/console      # http://127.0.0.1:8080
```

mojo_stats takes today's date: its partitions start on 2026-11-01, and a
date before that is refused. Without a token mojo_repos checks 25 candidates
a run (1000 with `GITHUB_TOKEN`). The whole sequence takes about 40 seconds
once the download is under way.

### Timeouts and retries

A GH Archive hour download and a git clone each have a deadline, and a
transient failure is tried again with exponential backoff and jitter (1 s,
2 s, 4 s ... up to 30 s, each between half and all of that; a 429's or 503's
`Retry-After` instead). Each retry prints a `retry:` line in the worker's
log. A download that stops mid-body resumes from the byte it stopped at
(`Range`). A 404 (an hour not yet published) and a repository that is gone
or private are not retried; a repository whose clone still fails is logged
as failed for that run, and mojo_versions keeps its old row. The settings,
all in the environment (morca.toml's `env`):

| Variable | Default | What it bounds |
|---|---|---|
| `GHARCHIVE_CONNECT_SECONDS` | 20 | the TCP connect and TLS handshake of one request |
| `GHARCHIVE_IDLE_SECONDS` | 30 | silence on a connection: a stalled read fails after it |
| `GHARCHIVE_TIMEOUT_SECONDS` | 900 | an hour's download, every try and wait included (not the time the decoder holds it back) |
| `GHARCHIVE_RETRIES` | 4 | retries after the first try |
| `GHARCHIVE_MISSING_AFTER_HOURS` | 48 | a 404 for an hour that ended longer ago than this is a gap GH Archive will never fill: with `GHARCHIVE_EVENTS=off` the day is loaded without it (#77) |
| `GIT_TIMEOUT_SECONDS` | 600 | one clone (or a blobless clone's `git show`): its process group is killed after it |
| `GIT_RETRIES` | 3 | retries of a clone after the first try |
| `GIT_LOW_SPEED_LIMIT`, `GIT_LOW_SPEED_SECONDS` | 1000, 60 | git's own stall detector (`http.lowSpeedLimit`, `http.lowSpeedTime`): under 1000 B/s for 60 s aborts the transfer |

`tests/test_fetch.mojo` checks them against a local server that stalls,
fails and cuts connections (`tests/http_faults.py`, which needs `python3`).

### Without the events

`gharchive.events` is about 1.1 GB a day, 97% of the bucket, and only
gharchive_index reads it. `GHARCHIVE_EVENTS=off` (default `on`) stops
writing it: each hour's task parses the hour into the rows of
`gharchive.candidates`, `gharchive.repo_hour` and `gharchive.releases` only,
from the same parse as with the events on, so those rows are the same, byte
for byte (`tests/test_eventsoff.mojo` runs one hour both ways and compares
the files; `scripts/test-daily.sh` compares three real hours). Nothing is
written to `gharchive.events`, and the table isn't created if it is missing.

- An hour in flight takes about 200 MB instead of about 450 MB: no
  rows, no Parquet row groups, no zstd contexts (`eventrows.HOUR_INDEX_MEMORY_MB`,
  `tools/hour_memory.mojo ... noevents`).
- Retries: the index tables are still committed once a day, and a retry
  still finds those commits (`find_commit` on each of them) rather than
  committing twice. With no hourly commits to skip, a retry before the
  index commits downloads every hour again, and one after them downloads
  nothing.
- A rerun of a day loaded with the events on replaces its index rows and
  leaves its events where they are.
- The step still declares `gharchive.events` in `writes=`: a declared write
  that isn't made fails nothing, and the declaration is part of the
  pipeline's registry hash, so the hash, and which runs count as done, is
  the same whichever way it is set.
- What reads `gharchive.events` gets no new days: gharchive_index (paused;
  it has nothing to do for a day without events) and the tools
  (`dump_index gharchive.events`, `events_digest`, `compare_activity`,
  `drop_run`). The console's count of loaded days (`model.read_days`)
  counts the days named by the snapshots of the events or of
  `gharchive.repo_hour`, which gharchive commits either way.

It is set in the environment of the server's gharchive pipeline (morca.toml's
`env` is where it would go).

### The morca way: Postgres, the scheduler and the UI

A Postgres that lasts between sessions, under `build/` (from conda-forge's
`postgresql`, in `pixi.toml`):

```sh
pixi run initdb -D build/pg --auth=trust --username=postgres -E UTF8 --locale=C
pixi run pg_ctl -D build/pg -l build/pg.log -o "-k $PWD/build -c listen_addresses=" -w start
pixi run createdb -h "$PWD/build" -U postgres orca
```

`scripts/env.sh` sets `MORCA_DATABASE_URL` to it, the warehouse and logs
under `build/`, `GHARCHIVE_HOURS=15,17`, `MOJO_HISTORY_MAX_KB=100000` (skips
modular/modular, which is over a gigabyte) and a 10-second sense interval.
Register the pipelines **before** loading data (a sensor only counts
snapshots made after it is registered; if you ran the pipelines on their own
above, delete `build/warehouse` first), then backfill one day:

```sh
pixi shell
. scripts/env.sh
for p in gharchive mojo_repos mojo_history mojo_activity mojo_stats; do ./build/morca locate build/$p --root .; done
./build/morca register ./build/gharchive ./build/mojo_repos ./build/mojo_history ./build/mojo_activity ./build/mojo_stats
./build/morca scheduler &                 # fires, senses, starts runs
./build/morca ui &                        # http://127.0.0.1:8270
./build/morca backfill gharchive 2024-06-12
```

The scheduler then runs gharchive for the day, which starts mojo_repos for
the same day (sensor), whose snapshot of `mojo.repos` starts mojo_history
for the repositories it added (keyed sensor). Watch it in the UI or in
`build/logs/<pipeline>/<run>/`. If port 8270 is taken (another morca UI),
start the UI with `MORCA_UI_ADDR=127.0.0.1:8275`. `./build/morca lineage
mojo.commits` traces the histories back to the `gharchive.events` snapshot
and run they came from.
`scripts/with-postgres.sh` (from morca) runs a command against a throwaway
server instead.

Without a token, GitHub allows 60 API requests an hour, and mojo_repos
spends one to three per candidate; a day with more candidates than that
leaves the rest as `unchecked` in `mojo.checked`, and the next run checks
them first. To check them for that day once the limit has reset (an hour
later), re-run the day, which already succeeded:

```sh
./build/morca backfill --rerun mojo_repos 2024-06-12
```

Set `GITHUB_TOKEN` to lift the limit. Stop everything with
`kill` on the scheduler's and UI's PIDs and `pg_ctl -D build/pg stop`.

### Registering on the server

`morca.toml` at the repository root says how each scheduled pipeline runs
(`max_runs`, fills, `DISTA_WORKER_SLOTS`, secrets), each setting with a
comment. `Dockerfile.morca` puts it in the image at `/opt/morca/morca.toml`
(`MORCA_CONFIG`), next to the pipelines (`MORCA_PIPELINES_DIR`), so on the
server registering is `docker exec scheduler morca register` (morca after
0.10.0). To change a setting: edit `morca.toml`, merge, deploy the new image,
register again. `mojo_retool` has no schedule and runs only by hand, but it is in the file too, so registering keeps it available for a release's upgrade steps (`upgrade.toml`).

### The dev stack

morca's [dev stack](https://github.com/morca-dev/morca/blob/main/docs/hetzner.md#a-dev-stack)
is a second, smaller server for trying a release or a deploy-script change
before production. Its scheduler reads `morca.dev.toml` (the image has it at
`/opt/morca/morca.dev.toml`; the stack sets `MORCA_CONFIG` to it): the same
pipelines, without fills or the bgent pool, so it never backfills from 2023.
CI keeps the two files' pipelines the same.

Both stacks' images come from the `dev` branch: a push to `dev` builds and
pushes `ghcr.io/morca-dev/census:<short sha>` and `:dev`. main builds no image
(`:latest` stays at main's last one, `c1f9fd7`). To release, bring `dev` up
to main (`git push origin origin/main:dev`, or a merge of main into `dev` when
it has commits of its own), deploy the short sha to the dev stack, then the
same tag to production. To try a morca commit, pin it on `dev`
(`morca-mojo = { git = ..., rev = "<sha>" }` in `pixi.toml`, then `pixi
lock`) and push.

### A second machine

The git-heavy pipelines, mojo_history, mojo_versions and mojo_activity, can run
on a second machine as a morca remote worker, while the CAX21 keeps the
scheduler, the UI, Postgres, the site, gharchive's fill, mojo_repos and
mojo_stats. The worker holds no database credentials and needs only outbound
HTTPS to the UI and to the bucket, no inbound ports. The census ran it on
"bgent", an Apple-silicon Mac running Docker: arm64 like the CAX21, so the same
image. (morca's [docs/workers.md](https://github.com/morca-dev/morca/blob/main/docs/workers.md)
and the [Workers page](https://mlake.dev/s/orca/docs/workers) cover the
general case; remote workers need morca 0.14.0.) It did that while gharchive's
backfill had the CAX21's cores; since 2026-11-09 they run on the server
again, and this section is how to move them back.

On the server, a token for the pool, printed once (copy it to the worker
machine as `worker-token`):

```sh
docker exec scheduler morca worker-token create --pool bgent --label bgent
```

Place the three pipelines on the pool in `morca.toml`, then deploy and register
again as in [Registering on the server](#registering-on-the-server):

```toml
[pipelines.mojo_history]
placement = "worker:bgent"
env = { DISTA_WORKER_SLOTS = "3" }
```

(the same for mojo_versions and mojo_activity). Until a worker is running their
runs wait, queued, "waiting for a worker of pool bgent".

On the worker, put the token in a Docker volume. Docker Desktop's VM may not
see a file bind-mounted from under `~/.config`: the mount shows up as an empty
directory.

```sh
docker run --rm -i --entrypoint sh -v orca-worker-secrets:/s ghcr.io/morca-dev/census:<tag> \
  -c 'cat > /s/token && chmod 600 /s/token' < worker-token
```

Then the worker, with `s3.env` holding the bucket's `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`:

```sh
docker run -d --name orca-worker --restart always \
  --env-file s3.env -v orca-worker-secrets:/etc/orca/w:ro \
  -e MORCA_WAREHOUSE=s3://census-mlake-dev/warehouse -e MORCA_LOGS=s3://census-mlake-dev/logs \
  -e AWS_REGION=nbg1 -e AWS_ENDPOINT_URL_S3=https://nbg1.your-objectstorage.com \
  -e MOJO_HISTORY_WORKDIR=/work/clones -v census-work:/work \
  ghcr.io/morca-dev/census:<tag> worker --pool bgent --max-runs 3 --remote https://orca.mojourney.dev --token-file /etc/orca/w/token
```

`--max-runs 3` lets the three pipelines run at once; the worker admits runs
against its own host (its log says, for example, "grants up to 8 CPUs and
11421 MB", less `MORCA_RESERVE_CPUS` and `MORCA_RESERVE_MEMORY_MB`).
`MOJO_HISTORY_WORKDIR` keeps the clones on a volume. Check it in Ops › Workers
(`/api/workers`): heartbeat, CPUs and memory.

Limits: the worker must run the server's image tag, so deploy the server first
and then restart the worker on the same tag; fills (`fills = "all"`) don't run
on worker pools yet (morca #177), so use `morca backfill` for a pool; and a
pipeline that needs secrets needs `MORCA_SECRET_FETCH` on the worker (these
three need none: mojo_history uses no token, and mojo_stats stays on the
server). With morca main (0.15.0), `MORCA_WORKER_ADDR` serves the worker API on
a listener of its own, so slow page renders don't delay workers.

### Edge caching

The console answers pages and JSON with `Cache-Control: public, max-age=60,
s-maxage=1800, stale-while-revalidate=60, stale-if-error=86400` (the
warming-up page, `/checks` and any answer but a 200 with `no-store`): a
minute in the browser, 30 minutes at Cloudflare, the refresher's period.
Cloudflare may then serve its copy for a minute while it refetches, and for
a day while the console can't answer, so a deploy's restart (connection
refused, then the warming-up 503) shows readers the last page, not an error.
Only pages someone has fetched recently at that edge have a copy. The tunnel's
traffic goes through Cloudflare's proxy, but by default Cloudflare caches only
static file types, never HTML (`cf-cache-status: DYNAMIC`), so mojourney.dev
needs a cache rule: Caching → Cache Rules → hostname equals `mojourney.dev`,
Cache eligibility "Eligible for cache", Edge TTL "Use cache-control header if
present", and Caching → Configuration → Browser Cache TTL "Respect Existing
Headers" (its default, 4 hours, overrides the minute). Or with the API, a
token with Cache Rules: Edit on the zone and the zone ID from its Overview
page: `PUT /client/v4/zones/<zone>/rulesets/phases/http_request_cache_settings/entrypoint`
with one rule, expression `(http.host eq "mojourney.dev")`, action
`set_cache_settings`, `{"cache": true, "edge_ttl": {"mode": "respect_origin"}}`.
Check with two GETs (`curl -s -D - -o /dev/null https://mojourney.dev/ | grep
cf-cache`: `MISS`, then `HIT`; HEAD requests aren't a reliable test). PostHog keeps working: the snippet runs in
the browser, and the `mojourney-ph` Worker serves `/ph` ahead of the cache.
Don't add the rule for orca.mojourney.dev: its pages are live and some are
behind a login.

### robots.txt

mojourney.dev's robots.txt has Cloudflare's managed content signals
(Security → Settings → "Instruct AI bot traffic with robots.txt"). Cloudflare
puts them in front of the origin's file, so the console's `/robots.txt`
(`User-agent: *`, `Allow: /` and the `Sitemap:` line) shows below them; it
needs no Cloudflare change. Check with `curl -s https://mojourney.dev/robots.txt | tail -3`.
If the managed setting were off, the console's file is served alone.

### Analytics

With `POSTHOG_KEY` set to a PostHog project key (`phc_...`, a public
client-side key), every console page's `<head>` loads PostHog the way the
magmalake.org website does: `array.js` and the events go through `/ph` on
the page's own origin, with memory-only persistence (no cookies, no
`localStorage`, so no consent banner), and `site: "mojourney"` registered on
every event (morca's UI sends `site: "morca"`), so one PostHog project can hold
both sites. If the key is unset or not a `phc_` key, the snippet is left out
(`src/analytics.mojo`). The console doesn't serve `/ph`: on mojourney.dev
the `mojourney-ph` Cloudflare Worker in magmalake/magmalake.org does
(`npx wrangler deploy -c worker/mojourney-ph/wrangler.jsonc`).

On the Hetzner server the console is a morca-stack app, which gets its
environment from `/etc/orca/app.env`. That file is written from
`settings.env` and carries `MORCA_POSTHOG_KEY` across as `POSTHOG_KEY`
(morca's `deploy/hetzner`, after morca 0.12.0). So set `POSTHOG_KEY=phc_...`
in `hetzner.env` and run `./up.sh`, or add `MORCA_POSTHOG_KEY=phc_...` to
`/etc/orca/settings.env` and run `morca-stack apply`. The same key also turns
on morca's UI. Locally: `POSTHOG_KEY=phc_... PORT=8080 pixi run ./build/console`.

### What a local run produced

On 2024-06-12, hours 15 and 17: 476,227 events (154 MB of Parquet), 23
candidates, 4 Mojo repositories (NuMojo, Mojonet, mojo-flx and
modular/modular, which was skipped for size), 3 histories read, 372
commits and 27 migrations. [docs/first-local-run.md](docs/first-local-run.md)
has the run as the scheduler did it, on morca 0.3.1.

## Table history

Every table keeps thirty days of snapshots (morca's default) and
`gharchive.events` a week (`lake.events_properties`, 168 hourly commits);
each commit deletes the metadata files beyond the last hundred. The
scheduler expires every table by that policy once a day through
`build/morca_maintain` (`bin/morca_maintain.mojo`, built by `pixi run build`
beside `morca`), keeping whatever a run that can still resume read or
committed, and the last run's snapshots. By hand:

```
./build/morca expire gharchive.events --older-than 7d --dry-run --report
./build/morca expire --all          # each table by its own policy
```

## What's left for AWS

Not done in this local run:

- `morca aws up` (stack, hostnames for the UI and the console, Budgets
  email), `morca aws push` (the linux-aarch64 image; `pixi.toml` already has
  the platform, `postgresql` and `git`), `morca aws register --workers 0..4
  gharchive mojo_repos mojo_history`, `morca aws app console`.
- A `GITHUB_TOKEN` in Secrets Manager (`orca/github-token`) registered with
  `--secret GITHUB_TOKEN=orca/github-token` for mojo_repos; with it the
  check budget is 1000 a run. GitHub code search (finding `pixi.toml`s that
  name Mojo directly) needs a token and isn't used.
- Unset `GHARCHIVE_HOURS` and `MOJO_HISTORY_MAX_KB` on AWS (all 24 hours,
  every repository); check the size of a day's run instance, since the
  history step holds 50 repositories' rows and modular/modular is large.
- Backfill one month (`./build/morca aws ...` then `morca backfill gharchive
  2025-01-01..2025-01-31`) to see the cost, then the rest from 2023-01-01.
  Note that recent hours of GH Archive carry much smaller payloads.
- `mojo.repos` stars and forks are as of the day a repository was found;
  `mojo.repo_stats` has them day by day from 2026-11-08, and `mojo.activity` day by day
  from GH Archive.
