# Changelog

The fragments in [changes/](changes/README.md) are written here at each
release.

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
