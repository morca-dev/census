"""The lake's tables, shared by the pipelines and the console."""

from std.os import getenv

from iceberg.catalog.filesystem import FilesystemCatalog, Table
from iceberg.io import FileIO
from iceberg.json import json_quote
from iceberg.schema import Schema
from iceberg.transforms import PartitionField, PartitionSpec, parse_transform
from iceberg.types import P_DATE, P_TIMESTAMPTZ
from iceberg.values import Datum

comptime EVENTS = "gharchive.events"
comptime REPOS = "mojo.repos"
comptime COMMITS = "mojo.commits"
comptime MIGRATIONS = "mojo.migrations"
comptime CHECKED = "mojo.checked"
comptime REPO_STATS = "mojo.repo_stats"
comptime ACTIVITY = "mojo.activity"
comptime RELEASES = "mojo.releases"
comptime ACTIVITY_REPOS = "mojo.activity_repos"
comptime TAGS = "mojo.tags"
comptime CONTRIBUTORS = "mojo.contributors"
comptime REPO_VERSIONS = "mojo.repo_versions"
comptime REPO_DEPS = "mojo.repo_deps"
comptime DEP_FORKS = "mojo.dep_forks"
comptime CANDIDATES = "gharchive.candidates"
comptime REPO_HOUR = "gharchive.repo_hour"
comptime GH_RELEASES = "gharchive.releases"
comptime REPO_EMBEDDINGS = "mojo.repo_embeddings"
comptime ISSUES = "mojo.issues"
comptime LIVE_COMMITS = "mojo.live_commits"
comptime LIVE_HEADS = "mojo.live_heads"

comptime EVENTS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"id","required":true,"type":"long"},'
    '{"id":2,"name":"type","required":true,"type":"string"},'
    '{"id":3,"name":"created_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"repo","required":true,"type":"string"},'
    '{"id":5,"name":"actor","required":false,"type":"string"},'
    '{"id":6,"name":"payload","required":false,"type":"string"}]}'
)

comptime REPOS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"created_at","required":false,"type":"timestamptz"},'
    '{"id":3,"name":"first_seen","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"found_by","required":true,"type":"string"},'
    '{"id":5,"name":"stars","required":false,"type":"long"},'
    '{"id":6,"name":"forks","required":false,"type":"long"},'
    '{"id":7,"name":"license","required":false,"type":"string"},'
    '{"id":8,"name":"default_branch","required":false,"type":"string"},'
    '{"id":9,"name":"description","required":false,"type":"string"},'
    '{"id":10,"name":"size_kb","required":false,"type":"long"},'
    '{"id":11,"name":"language","required":false,"type":"string"},'
    '{"id":12,"name":"fork","required":false,"type":"boolean"},'
    '{"id":13,"name":"topics","required":false,"type":'
    '{"type":"list","element-id":14,"element":"string","element-required":true}},'
    '{"id":15,"name":"repo_id","required":false,"type":"long"}]}'
)
"""mojo_history is keyed on `repo` (`owner/name`), the name the repository
was found under, which stays its key after a rename (`names.mojo`).
`topics` and `repo_id` (GitHub's id) came later (ensure_table adds them;
rows from before read them as null)."""

comptime COMMITS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"sha","required":true,"type":"string"},'
    '{"id":3,"name":"committed_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"seq","required":true,"type":"long"},'
    '{"id":5,"name":"mojo_lines","required":true,"type":"long"},'
    '{"id":6,"name":"mojo_files","required":true,"type":"long"},'
    '{"id":7,"name":"tooling","required":true,"type":"string"},'
    '{"id":8,"name":"mojo_version","required":false,"type":"string"},'
    '{"id":9,"name":"version_source","required":false,"type":"string"},'
    '{"id":10,"name":"packaging","required":false,"type":"string"},'
    '{"id":11,"name":"subject","required":false,"type":"string"},'
    '{"id":12,"name":"changes","required":false,"type":"string"}]}'
)
"""`packaging`, `subject` and `changes` (`filemix.FileMix.encode`, #121)
came later (ensure_table adds them; rows from before read them as null until
mojo_retool reads their history again)."""

comptime MIGRATIONS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"sha","required":true,"type":"string"},'
    '{"id":3,"name":"committed_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"kind","required":true,"type":"string"},'
    '{"id":5,"name":"from_value","required":false,"type":"string"},'
    '{"id":6,"name":"to_value","required":false,"type":"string"}]}'
)


comptime CHECKED_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"checked_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"outcome","required":true,"type":"string"},'
    '{"id":4,"name":"signals","required":false,"type":"string"},'
    '{"id":5,"name":"how","required":false,"type":"string"},'
    '{"id":6,"name":"first_seen","required":false,"type":"timestamptz"},'
    '{"id":7,"name":"sha","required":false,"type":"string"}]}'
)
"""Every candidate mojo_repos asked GitHub about, so it asks once."""

comptime REPO_STATS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"as_of","required":true,"type":"date"},'
    '{"id":3,"name":"fetched_at","required":true,"type":"timestamptz"},'
    '{"id":4,"name":"state","required":true,"type":"string"},'
    '{"id":5,"name":"stars","required":false,"type":"long"},'
    '{"id":6,"name":"forks","required":false,"type":"long"},'
    '{"id":7,"name":"open_issues","required":false,"type":"long"},'
    '{"id":8,"name":"watchers","required":false,"type":"long"},'
    '{"id":9,"name":"topics","required":false,"type":'
    '{"type":"list","element-id":10,"element":"string","element-required":true}},'
    '{"id":11,"name":"archived","required":false,"type":"boolean"},'
    '{"id":12,"name":"pushed_at","required":false,"type":"timestamptz"},'
    '{"id":13,"name":"homepage","required":false,"type":"string"},'
    '{"id":14,"name":"license","required":false,"type":"string"},'
    '{"id":15,"name":"description","required":false,"type":"string"},'
    '{"id":16,"name":"size_kb","required":false,"type":"long"},'
    '{"id":17,"name":"default_branch","required":false,"type":"string"},'
    '{"id":18,"name":"renamed_to","required":false,"type":"string"},'
    '{"id":19,"name":"repo_id","required":false,"type":"long"}]}'
)
"""One row per repository per daily refresh (mojo_stats). `state` is `ok`,
`renamed` (GitHub redirected to `renamed_to`), `gone` (404/410), `blocked`
(451) or `error HTTP n`. `repo_id` is GitHub's id for the repository, which
a rename keeps (null on rows from before it was recorded, #181)."""

comptime ACTIVITY_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"day","required":true,"type":"date"},'
    '{"id":3,"name":"events","required":true,"type":"long"},'
    '{"id":4,"name":"stars","required":true,"type":"long"},'
    '{"id":5,"name":"forks","required":true,"type":"long"},'
    '{"id":6,"name":"releases","required":true,"type":"long"},'
    '{"id":7,"name":"issues_opened","required":true,"type":"long"},'
    '{"id":8,"name":"prs_opened","required":true,"type":"long"},'
    '{"id":9,"name":"pushes","required":true,"type":"long"},'
    '{"id":10,"name":"actors","required":true,"type":"long"}]}'
)
"""A repository's GH Archive events on one day (UTC), for the repositories
in mojo.repos; a row only for days with an event. `stars` counts
WatchEvents, `forks` ForkEvents, `releases` published ReleaseEvents,
`issues_opened`/`prs_opened` IssuesEvents/PullRequestEvents with action
`opened`, `pushes` PushEvents, `actors` distinct actors of any event."""

comptime RELEASES_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"day","required":true,"type":"date"},'
    '{"id":3,"name":"tag","required":true,"type":"string"},'
    '{"id":4,"name":"name","required":false,"type":"string"},'
    '{"id":5,"name":"published_at","required":false,"type":"timestamptz"},'
    '{"id":6,"name":"prerelease","required":false,"type":"boolean"},'
    '{"id":7,"name":"actor","required":false,"type":"string"}]}'
)
"""Published ReleaseEvents of the repositories in mojo.repos; `day` is the
event's day, which the table is replaced by."""

comptime ACTIVITY_REPOS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"added_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"days","required":true,"type":"long"}]}'
)
"""The repositories mojo_activity has caught up: their activity on every
day gharchive.events had when they were added (`days`). Later days include
them as members of mojo.repos."""

comptime TAGS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"tag","required":true,"type":"string"},'
    '{"id":3,"name":"commit","required":true,"type":"string"},'
    '{"id":4,"name":"annotated","required":true,"type":"boolean"},'
    '{"id":5,"name":"tagged_at","required":false,"type":"timestamptz"},'
    '{"id":6,"name":"tooling","required":false,"type":"string"},'
    '{"id":7,"name":"mojo_version","required":false,"type":"string"},'
    '{"id":8,"name":"packaging","required":false,"type":"string"}]}'
)
"""Each repository's git tags (mojo_history): the commit a tag points at
(peeled), the tagger's date for an annotated tag or the commit's for a
lightweight one, and the tooling, Mojo version and packaging at that commit when it
is on the first-parent history mojo.commits has."""

comptime CONTRIBUTORS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"month","required":true,"type":"date"},'
    '{"id":3,"name":"author","required":true,"type":"string"},'
    '{"id":4,"name":"commits","required":true,"type":"long"}]}'
)
"""Each repository's contributors by month (mojo_history,
`contributors.read_authors`): one row per (repository, month, person) with
the commits they authored or co-authored that month, over every commit
reachable from HEAD. `month` is its first day, by author time; `author` is
`contributors.author_id`, a hash of the email (no emails or names are
kept). Bots are left out."""

comptime REPO_VERSIONS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"read_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"head_sha","required":false,"type":"string"},'
    '{"id":4,"name":"mojo_version","required":false,"type":"string"},'
    '{"id":5,"name":"version_source","required":false,"type":"string"},'
    '{"id":6,"name":"version_file","required":false,"type":"string"},'
    '{"id":7,"name":"version_estimate","required":false,"type":"string"},'
    '{"id":8,"name":"estimate_source","required":false,"type":"string"},'
    '{"id":9,"name":"last_mojo_commit","required":false,"type":"timestamptz"},'
    '{"id":10,"name":"declared_deps","required":false,"type":"long"}]}'
)
"""One row per repository (mojo_versions): the Mojo version its HEAD states
and where (`lock`, `manifest`, `file`, `ci`, `docker`, `readme`, `repo`), the
file it was read from, and, apart from it, the release current at the last
commit that touched a Mojo file (`version_estimate`, source `date`). A
repository with a manifest still has its row; the console prefers the
version mojo.commits has and falls back to this one. `declared_deps` came
later (ensure_table adds it): the number of distinct dependencies HEAD's
manifests declare, toolchain left out, null for a row read before."""

comptime REPO_EMBEDDINGS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"model","required":true,"type":"string"},'
    '{"id":3,"name":"model_rev","required":true,"type":"string"},'
    '{"id":4,"name":"input_hash","required":true,"type":"string"},'
    '{"id":5,"name":"input","required":true,"type":"string"},'
    '{"id":6,"name":"dim","required":true,"type":"int"},'
    '{"id":7,"name":"vector","required":true,"type":"binary"},'
    '{"id":8,"name":"embedded_at","required":true,"type":"timestamptz"}]}'
)
"""One row per repository (mojo_embed): the sentence embedding of its name,
description and topics (`input`, the text the model read). `vector` is `dim`
float32 values, little-endian, L2-normalized, so a dot product is the
cosine. `model` names the model (MOJO_EMBED_MODEL_NAME) and `model_rev` is
a hash of its weights; `input_hash` hashes the input and model_rev, and a
run re-embeds a repository only when it changes."""

comptime REPO_DEPS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"read_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"relation","required":true,"type":"string"},'
    '{"id":4,"name":"kind","required":true,"type":"string"},'
    '{"id":5,"name":"dep_name","required":true,"type":"string"},'
    '{"id":6,"name":"dep_repo","required":false,"type":"string"},'
    '{"id":7,"name":"section","required":false,"type":"string"},'
    '{"id":8,"name":"file","required":true,"type":"string"}]}'
)
"""What each repository's manifests at HEAD declare (mojo_versions, beside
mojo.repo_versions and replaced with it): a row per dependency (`relation`
`depends`; `kind` `conda`, `pypi`, `git`, `url` or `path`; `dep_repo` the
`owner/name` of a GitHub URL) and per name the repository publishes itself
under (`provides`; `package`, `recipe`, `pyproject` or `workspace`), with
the table or requirements list (`section`) and the file. Which of them are
Mojo libraries of the census, and the reverse counts, the console works out
(`deps.resolve`), so they follow mojo.repos without a rerun."""

comptime DEP_FORKS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"fetched_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"state","required":true,"type":"string"},'
    '{"id":4,"name":"fork","required":false,"type":"boolean"},'
    '{"id":5,"name":"parent","required":false,"type":"string"},'
    '{"id":6,"name":"source","required":false,"type":"string"}]}'
)
"""The GitHub repositories that census repositories name as dependencies
(mojo.repo_deps' `dep_repo`) and that aren't census repositories
themselves, asked about once each by mojo_stats: whether each is a `fork`,
and its `parent` and the root of its fork network (`source`). `state` is
mojo.repo_stats': `ok`, `gone`, `blocked` or `error HTTP n` (asked again).
The console rolls a fork's dependents up into its source (`deps.resolve`)."""

comptime CANDIDATES_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"hour","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"reason","required":true,"type":"string"},'
    '{"id":4,"name":"first_seen","required":true,"type":"timestamptz"},'
    '{"id":5,"name":"sha","required":false,"type":"string"}]}'
)
"""What gharchive's hour tasks found while they parsed the events: one row
per (repository, hour, reason), the reasons `detect.scan_event` knows
(`name`, `language`, `push`, `manifest`, `description`). `first_seen` is the
earliest event of that repository in the hour that made it a candidate for
any reason, `sha` the first pushed commit that may touch `.mojo` files."""

comptime REPO_HOUR_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"hour","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"actor","required":false,"type":"string"},'
    '{"id":4,"name":"events","required":true,"type":"long"},'
    '{"id":5,"name":"stars","required":true,"type":"long"},'
    '{"id":6,"name":"forks","required":true,"type":"long"},'
    '{"id":7,"name":"releases","required":true,"type":"long"},'
    '{"id":8,"name":"issues_opened","required":true,"type":"long"},'
    '{"id":9,"name":"prs_opened","required":true,"type":"long"},'
    '{"id":10,"name":"pushes","required":true,"type":"long"}]}'
)
"""Every event of GH Archive counted per (repository, actor, hour), sorted
by repository, so a day's distinct actors of a repository are the distinct
`actor`s of its rows. Counts as in `mojo.activity`; `actor` is null for an
event without one. About half a row an event."""

comptime GH_RELEASES_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"created_at","required":true,"type":"timestamptz"},'
    '{"id":3,"name":"actor","required":false,"type":"string"},'
    '{"id":4,"name":"tag","required":true,"type":"string"},'
    '{"id":5,"name":"name","required":false,"type":"string"},'
    '{"id":6,"name":"published_at","required":false,"type":"timestamptz"},'
    '{"id":7,"name":"prerelease","required":true,"type":"boolean"}]}'
)
"""Every published ReleaseEvent, of every repository."""


def candidates_schema() raises -> Schema:
    return Schema.parse(CANDIDATES_SCHEMA)


def repo_hour_schema() raises -> Schema:
    return Schema.parse(REPO_HOUR_SCHEMA)


def gh_releases_schema() raises -> Schema:
    return Schema.parse(GH_RELEASES_SCHEMA)


def index_properties() -> Dict[String, String]:
    """The tables written beside gharchive.events keep its week of snapshots,
    and `gharchive.candidates` and `gharchive.releases` small row groups, so a
    scan for a few repositories reads a few of each file's row groups."""
    var p = _week_of_snapshots()
    p["write.parquet.row-group-size-rows"] = "16384"
    return p^


def repo_hour_properties() -> Dict[String, String]:
    """`gharchive.repo_hour`: a day is one file in (repo, actor, hour) order,
    and 16,384-row groups only made a dictionary larger than plain. With
    dictionaries (the default), zstd 9 and row groups of up to 1M rows a day
    is 41% smaller on 1.9M rows (magmalake/mojo-census#28). A scan for a few
    repositories still skips by the file's and pages' min/max, which the sort
    makes tight."""
    var p = _week_of_snapshots()
    p["write.parquet.row-group-size-rows"] = "1048576"
    p["write.parquet.compression-level"] = "9"
    return p^


def hour_spec(source_id: Int, name: String) raises -> PartitionSpec:
    """By the day of a timestamp column."""
    return PartitionSpec(
        0,
        [PartitionField.single(source_id, 1000, name, parse_transform("day"))],
    )


def candidates_spec() raises -> PartitionSpec:
    return hour_spec(2, "hour_day")


def repo_hour_spec() raises -> PartitionSpec:
    return hour_spec(2, "hour_day")


def gh_releases_spec() raises -> PartitionSpec:
    return hour_spec(2, "created_day")


def events_schema() raises -> Schema:
    return Schema.parse(EVENTS_SCHEMA)


def _week_of_snapshots() -> Dict[String, String]:
    """A week of snapshots (168 hourly commits) instead of thirty days, which
    keeps `metadata.json`, rewritten on every commit, small. The scheduler's
    expiry also keeps whatever a live run still needs."""
    var p = Dict[String, String]()
    p["history.expire.max-snapshot-age-ms"] = String(7 * 86_400_000)
    return p^


def events_properties() -> Dict[String, String]:
    """gharchive.events' table properties beyond morca's defaults: a week of
    snapshots, and zstd 9 rather than the default level: about 13% smaller,
    for 0.35 s more write time in an hour task of 2.4 s
    (magmalake/mojo-census#28). Needs iceberg-mojo's
    `write.parquet.compression-level`; an older one ignores the property."""
    var p = _week_of_snapshots()
    p["write.parquet.compression-level"] = "9"
    return p^


def events_spec() raises -> PartitionSpec:
    """gharchive.events is partitioned by the day of `created_at`."""
    return PartitionSpec(
        0,
        [PartitionField.single(3, 1000, "created_day", parse_transform("day"))],
    )


def _month_spec(source_id: Int, name: String) raises -> PartitionSpec:
    return PartitionSpec(
        0,
        [PartitionField.single(source_id, 1000, name, parse_transform("month"))],
    )


def repo_stats_schema() raises -> Schema:
    return Schema.parse(REPO_STATS_SCHEMA)


def repo_stats_spec() raises -> PartitionSpec:
    """By the month of `as_of`: about four refreshes a partition."""
    return _month_spec(2, "as_of_month")


def activity_schema() raises -> Schema:
    return Schema.parse(ACTIVITY_SCHEMA)


def activity_spec() raises -> PartitionSpec:
    """By the month of `day`."""
    return _month_spec(2, "month")


def releases_schema() raises -> Schema:
    return Schema.parse(RELEASES_SCHEMA)


def releases_spec() raises -> PartitionSpec:
    return _month_spec(2, "month")


def activity_repos_schema() raises -> Schema:
    return Schema.parse(ACTIVITY_REPOS_SCHEMA)


def tags_schema() raises -> Schema:
    return Schema.parse(TAGS_SCHEMA)


def contributors_schema() raises -> Schema:
    return Schema.parse(CONTRIBUTORS_SCHEMA)


def repo_versions_schema() raises -> Schema:
    return Schema.parse(REPO_VERSIONS_SCHEMA)


comptime ISSUES_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"number","required":true,"type":"long"},'
    '{"id":3,"name":"kind","required":true,"type":"string"},'
    '{"id":4,"name":"state","required":true,"type":"string"},'
    '{"id":5,"name":"title","required":true,"type":"string"},'
    '{"id":6,"name":"labels","required":false,"type":'
    '{"type":"list","element-id":7,"element":"string","element-required":true}},'
    '{"id":8,"name":"author","required":false,"type":"string"},'
    '{"id":9,"name":"comments","required":true,"type":"long"},'
    '{"id":10,"name":"created_at","required":true,"type":"timestamptz"},'
    '{"id":11,"name":"updated_at","required":true,"type":"timestamptz"},'
    '{"id":12,"name":"closed_at","required":false,"type":"timestamptz"},'
    '{"id":13,"name":"merged_at","required":false,"type":"timestamptz"},'
    '{"id":14,"name":"fetched_at","required":true,"type":"timestamptz"}]}'
)
"""One row per issue or pull request of a census repository (mojo_issues),
as GitHub had it when last fetched: `kind` is `issue` or `pr`, `state`
`open` or `closed`. Titles only, no bodies."""


def issues_schema() raises -> Schema:
    return Schema.parse(ISSUES_SCHEMA)


comptime LIVE_COMMITS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"sha","required":true,"type":"string"},'
    '{"id":3,"name":"subject","required":false,"type":"string"},'
    '{"id":4,"name":"committed_at","required":true,"type":"timestamptz"},'
    '{"id":5,"name":"seen_at","required":true,"type":"timestamptz"}]}'
)
"""Commits to census repos' default branches as the live poller (mojo_live)
saw them: appended a poll at a time, newest last."""

comptime LIVE_HEADS_SCHEMA = (
    '{"schema-id":0,"type":"struct","fields":['
    '{"id":1,"name":"repo","required":true,"type":"string"},'
    '{"id":2,"name":"head","required":false,"type":"string"},'
    '{"id":3,"name":"seen_at","required":true,"type":"timestamptz"}]}'
)
"""Each census repo's default-branch head at the poller's last look,
rewritten whole by a poll that saw one move."""


def live_commits_schema() raises -> Schema:
    return Schema.parse(LIVE_COMMITS_SCHEMA)


def live_heads_schema() raises -> Schema:
    return Schema.parse(LIVE_HEADS_SCHEMA)


def repo_embeddings_schema() raises -> Schema:
    return Schema.parse(REPO_EMBEDDINGS_SCHEMA)


def repo_deps_schema() raises -> Schema:
    return Schema.parse(REPO_DEPS_SCHEMA)


def dep_forks_schema() raises -> Schema:
    return Schema.parse(DEP_FORKS_SCHEMA)


def checked_schema() raises -> Schema:
    return Schema.parse(CHECKED_SCHEMA)


def repos_schema() raises -> Schema:
    return Schema.parse(REPOS_SCHEMA)


def commits_schema() raises -> Schema:
    return Schema.parse(COMMITS_SCHEMA)


def migrations_schema() raises -> Schema:
    return Schema.parse(MIGRATIONS_SCHEMA)


def ts(micros: Int64) -> Datum:
    """A `timestamptz` value."""
    return Datum.integral(P_TIMESTAMPTZ, micros)


def date(days: Int64) -> Datum:
    """A `date` value: days since 1970-01-01."""
    return Datum.integral(P_DATE, days)


def ts_or_null(micros: Int64) -> Datum:
    if micros == 0:
        return Datum.none()
    return ts(micros)


def json_strings(items: List[String]) -> String:
    """A `list<string>` cell for `NestedBuilder.add`."""
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += json_quote(items[i])
    out += "]"
    return out^


def str_or_null(s: String) -> Datum:
    if s.byte_length() == 0:
        return Datum.none()
    return Datum.string_(s)


def warehouse() -> String:
    """The lake: MORCA_WAREHOUSE (on AWS, the public bucket), else a directory."""
    return getenv("MORCA_WAREHOUSE", "build/warehouse")


def load(namespace: String, name: String) raises -> Table:
    var root = warehouse()
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(String(root.rstrip("/")), FileIO()).load_table(
            namespace, name
        )
    return FilesystemCatalog.local(root).load_table(namespace, name)


def exists(namespace: String, name: String) raises -> Bool:
    var root = warehouse()
    if "://" in root and not root.startswith("file://"):
        return FilesystemCatalog(
            String(root.rstrip("/")), FileIO()
        ).table_exists(namespace, name)
    return FilesystemCatalog.local(root).table_exists(namespace, name)


def try_load(namespace: String, name: String) raises -> Optional[Table]:
    """The table, or none when it doesn't exist. One round trip to the
    store when it does (`exists` then `load` is two or three)."""
    try:
        return load(namespace, name)
    except e:
        if exists(namespace, name):
            raise e^
        return None
