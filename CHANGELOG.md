# Changelog

The fragments in [changes/](changes/README.md) are written here at each
release.

## 1.19.0 - 2026-11-23

- **MCP server:** `POST /mcp` serves the census to agents as six read-only MCP tools, and with `POSTHOG_KEY` set each request is a PostHog event. (#230)

- **morca-mojo 0.43.0:** hosts you run yourself can be joined with `morca host join` (morca #591), drained and removed from Ops > Pools or with `morca --remote host ...` (morca #590), and follow the server's worker image (`morca host upgrade`, morca #593). Nothing changes for the census unless a host is joined. (#231)

## 1.18.0 - 2026-11-22

- **morca-mojo 0.42.0:** a pipeline's page in the morca UI keeps the links to its code after a run starts (morca #584); self-hosted pools and `morca host` (morca #587); opt-in working-set probing (`learn = "working_set"`, morca #588) and swap offload (`MORCA_RUN_SWAP_PCT`, morca #589), both off unless set. dista-mojo at its published 0.6.0. (#227)

## 1.17.0 - 2026-11-21

- **Mojo 1.3 nightly:** the census now requires Mojo 1.3.0.dev2026111805, with morca-mojo, dista-mojo and every tin at revisions built with it (#222).

- **By the numbers:** How it works shows mojo_embed's embedding rate and model load time (new table `mojo.measures`), how soon a GH Archive day and a push reach the site, and the console's memory and image size, each linked to its run (#124).

- **morca-mojo 0.40.0:** every container gets `MORCA_IMAGE_BYTES`, shown on /how; deploy tools 0.38.0 (morca #551). (#224)

## 1.16.0 - 2026-11-19

- **morca-mojo 0.39.0:** the UI can ask visitors for Cloudflare Turnstile before data reads, answers a missing snapshot with a quick 404, and keeps recent data reads in memory (morca #547, #548). (#220)

## 1.15.0 - 2026-11-19

- **morca-mojo 0.38.0:** the UI limits requests per client, caps data reads running at once, and puts the time in its log (morca #545). (#218)

## 1.14.0 - 2026-11-18

- **morca-mojo 0.37.0:** the UI serves a robots.txt that turns all crawlers away and marks its pages noindex (morca #542). (#215)

## 1.13.0 - 2026-11-18

- **morca-mojo 0.36.0:** the UI serves on several threads and logs each request (morca #539). (#213)

## 1.12.0 - 2026-11-17

- **morca-mojo 0.34.0:** gharchive coverage counts again under the current data version, and Weekly partitions are available; with dista 0.5.2, flare_mlake 0.14.2 and k8s-mojo 0.1.5. (#210)

- **morca-mojo 0.35.0:** pipelines say `fire=` for `fills=`; the UI's Retry is Resume, and `morca start` runs have trigger `cli`. (#211)

## 1.11.0 - 2026-11-16

- **Overview column names say what they count:** Outside the org, Lines, 30 days, and one spelling for the 30-day columns. (#201)

- **Repo page tabs**: the chart over time has Lines of Mojo, Commits and Issues tabs, each titled with its total. (#203)

## 1.10.0 - 2026-11-15

- **Upgrade steps checked in CI:** every `morca backfill` step of upgrade.toml is dry-run against earlier runs (`pixi run test-upgrade`, morca-mojo 0.31.0). (#194)

- **morca-mojo 0.32.0:** pipelines' Data tab and its cache, and morca_maintain on liblake, so the pipelines binary no longer compiles iceberg; the image carries `dev.morca.hetzner-min` for deploy.sh's tools check. (#195)

- **morca-mojo 0.33.0:** the redesigned Data tab; images need deploy tools 0.34.0 or later. (#196)

- **mojo_live runs one at a time across the cluster**, also across a deploy. (#197)

## 1.9.1 - 2026-11-14

- **Beta: the mojo_repos search fill runs a month a run**, after the other pipelines. (#190)

- **The 1.9.0 search backfill step passes `--allow-append`**, without which morca refused to rerun the days mojo_repos had already appended to. (#191)

## 1.9.0 - 2026-11-14

- **Beta: mojo_history asks for 2 GB**, not a learned size beta's host can't grant (morca#462). (#184)

- **Mojo repos found whatever their name:** mojo_repos also asks GitHub's search for `language:Mojo` repos, since GH Archive's recent hours no longer have the events that named them; a backfill after deploying finds the ones missed, such as magmalake/flare_mlake. (#185)

- **Registering works again:** mojo_repos no longer reads mojo.repo_stats, which made a cycle with mojo_stats that 1.8.0 couldn't register; CI now registers every pipeline. (#185)

- **Republishes count for their upstream:** a project using magmalake/flare_mlake, json_mlake or mozz_mlake is listed as a user of the ehsanmok repo it republishes, through a fork. (#185)

- **The console shows contributors and fork data as soon as they change**, not at its next daily rebuild. (#186)

- **Image builds retry the git download:** the image fetches git's source tarball with retries from three kernel.org mirrors and checks its sha256. (#187)

- **Every pipeline on morca-mojo 0.30.0's liblake:** the lake's iceberg and parquet code comes prebuilt with morca, so a pipeline builds faster; the mojo_repos search backfill after deploying runs as fill runs, a month a run overnight. (#188)

**After deploying** (deploy.sh shows these and runs the commands):

- Run `morca backfill --rerun --allow-append --as-fill mojo_repos 2023-01-01..2026-11-13`.

## 1.8.0 - 2026-11-14

- **Renamed and transferred repos:** shown and found under their current name, old links redirect; a backfill after deploying counts their activity under the new name. (#182)

**After deploying** (deploy.sh shows these and runs the commands):

- Run `morca backfill --rerun --allow-append mojo_activity 2026-11-13`.
- Run `morca backfill --rerun mojo_embed 2026-11-13`.

## 1.7.0 - 2026-11-14

- **Contributors per repo:** distinct commit authors, in all and per month, on the repo page and in its JSON; a backfill after deploying counts the repos read before. (#175)

- **Dependents through forks and second degree:** "Used by" counts projects that depend on a fork of a library (mojo_stats records forks in the new mojo.dep_forks), and the repo page and API show the second degree. (#176)

- **morca 0.28.0:** with json_mlake 0.5.1, flare_mlake 0.14.1, k8s-mojo 0.1.4 and dista 0.5.0; the full `mojo` package is pinned for llvm-symbolizer. (#179)

**After deploying** (deploy.sh shows these and runs the commands):

- Run `morca backfill --rerun --allow-append mojo_history @all`.
- Run `morca backfill --rerun mojo_stats 2026-11-14`.

## 1.6.0 - 2026-11-13

- **AI-friendly mojourney.dev:** the console serves `/llms.txt`, `/llms-full.txt`, `/sitemap.xml` and a `/robots.txt` with the sitemap, every page has a meta description and a link to its JSON, and `/api/repos?q=` filters as `/api/search` does. (#171)

- **morca-mojo 0.27.0:** cgroups and overlapping schedulers on by default; deploy with morca-hetzner 0.27.0. (#172)

## 1.5.1 - 2026-11-12

- **mojo_live hands over to a newer deploy** (morca-mojo 0.26.0): a run that is outdated stops between polls and succeeds, and the new code polls from the next hour. (#166)

## 1.5.0 - 2026-11-12

- **Commit types from the files a commit changes**: a commit the subject rules call other is typed like its nearest hand-labelled commits by the kinds of files it changed, and a commit can show secondary types (`Fix +test`); mojo.commits gains `changes`. (#161)

- **CI keeps Mojo's compile cache between image builds**, and pull requests build with `-g1` again, as pushed images do; a rerun of the same commit reuses part of the compile. (#162)

- **On morca-mojo 0.25.1**: images get the commit and source as environment, not `-D` defines, so the commit no longer changes what is compiled. (#163)

**After deploying** (deploy.sh shows these and runs the commands):

- Run `morca backfill --rerun mojo_retool @all`.

## 1.4.1 - 2026-11-12

- **A Mojo pin that adapts code is a migration**: a subject that moves to a Mojo version and also says it refreshed, fixed, ported, adapted or reworked something (`lock mojo 1.2.0..., refresh MOJO_NOTES`) is typed migration, not version. (#157)

- **mojo_live survives a 502 from GitHub**: a heads query GitHub fails is tried again, then split in halves, and a small batch that still fails is skipped for that poll instead of failing it; batches are 50 repos, not 100. (#158, #159)

## 1.4.0 - 2026-11-12

- **Ready for Mojo 1.3**: `Pointer` in place of the deprecated `UnsafePointer`, and `__deinit__` in place of `__del__`. (#149)

- **Issues and PRs per month**: the overview charts issues opened and closed and pull requests opened and merged each month, from mojo.issues; `/api/overview` months gain `issues`. (#150)

- **Fewer commits typed other**: tags, more prefixes (`toolchain:`, `accel:`, `migrate:`), Mojo release numbers without the word Mojo, and `Initial commit` get a type; on a sample, `other` went from 49% to 43%. (#151)

- **On morca-mojo 0.25.0, as morca** (breaking for operators): the image has `/opt/morca`, `morca.toml` (and `morca.dev.toml`, `morca.lab.toml`) and every `MORCA_*` variable in place of their orca names; a stack deploying it needs its `ORCA_*` settings renamed `MORCA_*` first. (#154)

- **Pull request images build without line tables** (`-g0`), about 15% faster with 30% less peak memory; images pushed from dev, lab and tags keep `-g1`. (#155)

## 1.3.1 - 2026-11-12

- **mojo_retool registered**: the upgrade step that re-reads every history works; 1.3.0's failed with "pipeline mojo_retool isn't registered". (#143)

- **Live polls every 20 minutes**: mojo_live checks the repositories three times an hour instead of every 3 minutes. (#144)

- **orca 0.24.0**: the census builds on orca 0.24.0 and dista 3f86c92. (#145)

- **New names**: the image is now ghcr.io/morca-dev/census; the repo moved to morca-dev/census, and orca and dista to morca-dev/morca and morca-dev/dista. (#146)

- **git without a shell**: the census runs git directly, without `sh` or `iconv`, a step towards a distroless runtime image. (#147)

## 1.3.0 - 2026-11-11

- **Commit subjects**: `mojo.commits` keeps each commit's subject line. (#102, #131)

- **Commit types**: each commit is labelled feature, fix, Mojo version, migration and so on from its subject, on the repo page and in the JSON. (#121, #132)

- **Live page**: `mojo_live` polls every census repo every 3 minutes; `/live` shows the new commits and how fresh they are. (#123, #134)

- **Version in the footer**: the console shows the release it runs. (#136)

- **Release steps**: a release's before- and after-deploy steps ship in the image as `upgrade.toml`, for deploy.sh to show and run. (#137, #138)

- **Build on Debian**: the image's build stages start from pixi's bookworm image, like its runtime stages. (#141)

**Before deploying:**

- Deploy with orca's deploy package 0.23.0 (`orca-hetzner-0.23.0`) or later: its deploy.sh reads `upgrade.toml` and runs the step below. An older one doesn't, so run it by hand.

**After deploying** (deploy.sh shows these and runs the commands):

- Run `orca backfill --rerun mojo_retool @all`.

## 1.2.0 - 2026-11-11

- **Python build tools and packaging**: tooling knows uv, poetry, pdm and pip; a new `packaging` column (rattler, conda-build). Run `mojo_retool` after deploying. (#118)

- **Issues and pull requests**: a daily pipeline, `mojo_issues` (08:00 UTC), keeps every census repo's issues and pull requests in `mojo.issues` from the GitHub API; each repo page lists its open issues and newest pull requests. Needs the GitHub token secret, as mojo_stats does. (#120, #127)

- **Embedding model from the bucket**: mojo_embed and the console fetch the model from the stack's bucket, copied there from Hugging Face once. (#128)

## 1.1.0 - 2026-11-10

- **`mojo_embed`, repository embeddings**: a daily pipeline (07:00 UTC) writes `mojo.repo_embeddings`, a bge-small-en-v1.5 vector per repository from its description and topics, with encoder-mojo 0.1.0 on the CPU; it re-embeds only repositories whose text changed and downloads the model (133 MB) to `MOJO_EMBED_MODEL` on its first run. (#100, #103)

- **orca 0.21.1**: runs held at their memory limit are killed and retried bigger, out-of-memory raises expire after 20 good runs, and learned CPUs fit the host. (#104)

- **A changelog and GitHub releases**: each PR adds a fragment to `changes/`, `scripts/changelog.sh` writes them here at a release, and a tag's CI makes its GitHub release from its section. (#105)

- **A Changelog tab**: How it works has a third tab, `/how/changelog`, with CHANGELOG.md, each entry linking its pull request; the image carries the file at `/opt/orca/CHANGELOG.md` (`CENSUS_CHANGELOG`). (#107)

- **A lab stack**: `orca.lab.toml` and `lab` images, for testing orca. (#108)

- **amd64 images**: each image is built for arm64 and amd64. (#109)

- **Reruns without `--allow-append`**: four pipelines that rewrite their rows declare `replaces=`, on orca 0.22.0. (#111)
- **Search model uses less memory**: encoder.mojo with the sized safetensors read (encoder #6). (#111)

- **Similar repos**: each repo page and its JSON list the 5 repos nearest it by embedding, with the model and snapshot they come from. (#101, #112)

- **Repo categories**: each repo gets an approximate category (ML, bindings, libraries, learning, games, web, other) from its description and embedding, as a filter on /repos, a tile on its page and a table on the overview. (#101, #113)

- **Search by meaning**: /search and /api/search list repos related to the query by embedding after the text matches; the console downloads the model (133 MB) on its first start and needs about 270 MB more memory; `CONSOLE_SEMANTIC=0` turns it off. (#101, #114)

## 1.0.0 - 2026-11-10

The census as it ran at mojourney.dev before embeddings, with orca-mojo
0.21.0, tagged after the fact at the merge of #99.

- **GH Archive**: each day from 2023-01-01 into `gharchive.events`, with its candidate, hourly and release tables (`gharchive`, `gharchive_index`).
- **Mojo repositories**: found from the candidates (`mojo_repos`), with their histories, migrations, tags and Mojo versions (`mojo_history`, `mojo_versions`, `mojo_retool`), activity by month (`mojo_activity`) and GitHub stats (`mojo_stats`).
- **The console**: a flare app at mojourney.dev over those tables.
- **The dev stack**: images from the `dev` branch, `orca.dev.toml` and the dev-only `ballast` pipeline (#87, #97, #99).
