"""What the console shows, read from the lake: one `Library` per repository
of mojo.repos (a repository in it twice is one), with what mojo.commits and mojo.migrations say about it, and its
latest row of mojo.repo_stats, and its dependencies (mojo.repo_deps,
resolved to the census's repositories here, a fork named as a dependency
to its source by mojo.dep_forks); and per repository its
activity by month (mojo.activity), releases (mojo.releases) and tags
(mojo.tags)."""

from iceberg.catalog.filesystem import Table

from cols import bool_at, col, has_col, i32_at, i64_at, is_valid, str_at, strs_at
from deps import ForkOf, RepoDep, resolve
from historyrows import repo_dep_rows
from days import day_text
from jscan import micros_to_iso
from names import Names, NameRow, name_columns, name_rows, names_from
from lake import (
    ACTIVITY,
    ACTIVITY_REPOS,
    CANDIDATES,
    CHECKED,
    COMMITS,
    EVENTS,
    GH_RELEASES,
    MIGRATIONS,
    RELEASES,
    REPO_DEPS,
    REPO_HOUR,
    REPO_STATS,
    REPO_VERSIONS,
    REPOS,
    TAGS,
    exists,
    load,
    try_load,
)
from overview import ARCHIVE_START, Builder, tool_code
from versions import compare_versions, usable


@fieldwise_init
struct Library(Copyable, Movable):
    var repo: String
    var description: String
    var created_at: Int64
    var first_seen: Int64
    var found_by: String
    var stars: Int64
    var forks: Int64
    var license: String
    var size_kb: Int64
    var commits: Int
    var first_commit: Int64
    var last_commit: Int64
    var mojo_lines: Int64
    var mojo_files: Int64
    var tooling: String
    var mojo_version: String
    var topics: List[String]
    var stats_as_of: Int64
    """The day (days since 1970) of the mojo.repo_stats row the stars,
    forks and topics come from; 0 when they are from discovery."""
    var open_issues: Int64
    var watchers: Int64
    var archived: Bool
    var state: String
    """mojo.repo_stats' `state` (`ok`, `renamed`, `gone`, ...), or ""."""
    var renamed_to: String
    var version_source: String
    """Where `mojo_version` was read: the lock file or manifest of the last
    commit (`pixi.lock`, `pixi.toml`, ...), or mojo.repo_versions' `ci`,
    `docker`, `readme`, `file`, `repo`; empty for no version."""
    var version_file: String
    """The file of mojo.repo_versions it came from, if it did."""
    var version_estimate: String
    """The release current at the last commit that touched a Mojo file, by
    date (mojo.repo_versions); a guess, kept apart from `mojo_version`."""
    var declared_deps: Int64
    """Distinct dependencies its manifests declare at HEAD, toolchain left
    out; -1 when its dependencies haven't been read."""
    var declared: List[String]
    """Their names."""
    var depends_on: List[String]
    """The census repositories among them (`deps.resolve`): the Mojo
    libraries it depends on."""
    var used_by: List[String]
    """The census repositories that depend on it, directly or through a
    fork of it."""
    var used_by_forks: List[String]
    """Of `used_by`, the ones that depend on it only through a fork."""
    var second_degree: List[String]
    """The census repositories that depend on it through one of `used_by`
    and not directly, each once."""
    var packaging: String
    """How it packages itself for conda at its last commit (`rattler`,
    `conda-build`, `none`); empty when its history was read before
    packaging was."""
    var key: String
    """The name mojo.repos and the tables mojo_history and the other
    pipelines write key it by: the name it was found under, which `repo`
    (its current name) differs from after a rename or a transfer."""
    var aliases: List[String]
    """The other names it had (`names.Names`), which search matches and
    whose pages redirect to `repo`'s."""


@fieldwise_init
struct RepoVersion(Copyable, Movable):
    """A row of mojo.repo_versions."""

    var version: String
    var source: String
    var file: String
    var estimate: String
    var declared_deps: Int64
    """-1 for null: read before dependencies were."""


@fieldwise_init
struct Point(Copyable, Movable):
    var at: Int64
    var lines: Int64
    var sha: String
    var tooling: String
    var version: String
    var subject: String
    """Empty for a commit read before subjects were (#102)."""
    var changes: String
    """`filemix.FileMix.encode` of its files; empty before #121."""


@fieldwise_init
struct Migration(Copyable, Movable):
    var repo: String
    var sha: String
    var at: Int64
    var kind: String
    var from_value: String
    var to_value: String


def _has_field(t: Table, name: String) -> Bool:
    """Whether the table's current schema has a column `name`."""
    try:
        _ = t.metadata.schema().find_by_name(name)
        return True
    except:
        return False


def day(micros: Int64) -> String:
    """`YYYY-MM-DD`, or "" for no time."""
    if micros == 0:
        return String()
    var iso = micros_to_iso(micros)
    return String(iso[byte=:10])


def repo_names(repos: Table) raises -> Names:
    """The current and old names of mojo.repos' repositories (`names.mojo`),
    from mojo.repo_stats and the ids mojo.repos' rows have."""
    var keys = List[String]()
    var rows = List[NameRow]()
    var with_id = _has_field(repos, "repo_id")
    var cols: List[String] = ["repo"]
    if with_id:
        cols.append("repo_id")
    for b in repos.scan().select(cols^).to_batches():
        for r in range(b.num_rows):
            var key = str_at(b.column(0), r)
            keys.append(key)
            if with_id and i64_at(b.column(1), r) > 0:
                rows.append(NameRow(key, -1, "id", "", i64_at(b.column(1), r)))
    var stats = try_load("mojo", "repo_stats")
    if stats:
        for b in stats.value().scan().select(name_columns(stats.value())).to_batches():
            rows.extend(name_rows(b))
    return names_from(keys, rows)


def libraries(mut ob: Builder) raises -> List[Library]:
    """Every library, biggest (lines of Mojo now) first, each under its
    current name (`repo_names`): a repository found under a name it has
    since changed is shown as it is called now, and two rows of mojo.repos
    that are one repository are one library. Each commit row is
    also given to `ob` (the Overview's numbers), so the commits are scanned
    once for both."""
    var out = List[Library]()
    var repos_table = try_load("mojo", "repos")
    if not repos_table:
        return out^
    var names = repo_names(repos_table.value())
    var index = Dict[String, Int]()
    var keys_seen = Dict[String, Bool]()
    var ids = List[Int]()
    for b in repos_table.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_desc = col(b, "description")
        var c_created = col(b, "created_at")
        var c_first = col(b, "first_seen")
        var c_found = col(b, "found_by")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_lic = col(b, "license")
        var c_size = col(b, "size_kb")
        var c_topics = col(b, "topics") if has_col(b, "topics") else -1
        for r in range(b.num_rows):
            ob.repo_rows += 1
            var key = str_at(b.column(c_repo), r)
            var repo = names.canon(key)
            var first_seen = i64_at(b.column(c_first), r)
            var at = index.get(repo, -1)
            # The data checks' repos_unique counts rows twice under one name:
            # a row under another name of the same repo isn't one.
            if at >= 0 and key not in keys_seen:
                ob.repo_rows -= 1
            keys_seen[key] = True
            # One library per repository: a repo in mojo.repos twice (under
            # one name, or an old and a new one) keeps its earliest row (by
            # first_seen; the first one read on a tie), and that row's key.
            if at >= 0 and first_seen >= out[at].first_seen:
                continue
            var lib = Library(
                repo,
                str_at(b.column(c_desc), r),
                i64_at(b.column(c_created), r),
                first_seen,
                str_at(b.column(c_found), r),
                i64_at(b.column(c_stars), r),
                i64_at(b.column(c_forks), r),
                str_at(b.column(c_lic), r),
                i64_at(b.column(c_size), r),
                0, 0, 0, 0, 0, String(), String(),
                strs_at(b, c_topics, r) if c_topics >= 0 else List[String](),
                0, 0, 0, False, String(), String(),
                String(), String(), String(),
                -1, List[String](), List[String](), List[String](), List[String](), List[String](), String(),
                key, names.aliases_of(repo),
            )
            if at >= 0:
                out[at] = lib^
                continue
            index[repo] = len(out)
            ids.append(ob.add_repo(repo))
            out.append(lib^)
    # The rows the pipelines wrote are keyed by the kept row's name.
    var by_key = Dict[String, Int]()
    for i in range(len(out)):
        by_key[out[i].key] = i
    _latest_stats(out, index, names)
    var commits_table = try_load("mojo", "commits")
    if commits_table:
        var last_seq = Dict[String, Int64]()
        var cols: List[String] = ["repo", "committed_at", "seq", "mojo_lines", "mojo_files", "tooling", "mojo_version", "version_source"]
        # `packaging` came later: a table mojo_history hasn't written since
        # doesn't have it yet, and selecting it would fail.
        var with_pack = _has_field(commits_table.value(), "packaging")
        if with_pack:
            cols.append("packaging")
        for b in commits_table.value().scan().select(cols^).to_batches():
            var c_repo = col(b, "repo")
            var c_at = col(b, "committed_at")
            var c_seq = col(b, "seq")
            var c_lines = col(b, "mojo_lines")
            var c_files = col(b, "mojo_files")
            var c_tool = col(b, "tooling")
            var c_ver = col(b, "mojo_version")
            var c_src = col(b, "version_source")
            var c_pack = col(b, "packaging") if with_pack else -1
            for r in range(b.num_rows):
                var repo = str_at(b.column(c_repo), r)
                if repo not in by_key:
                    continue
                ref lib = out[by_key[repo]]
                var at = i64_at(b.column(c_at), r)
                var seq = i64_at(b.column(c_seq), r)
                ob.add_commit(
                    ids[by_key[repo]], at, seq, i64_at(b.column(c_lines), r),
                    tool_code(str_at(b.column(c_tool), r)), str_at(b.column(c_ver), r),
                )
                lib.commits += 1
                if lib.first_commit == 0 or at < lib.first_commit:
                    lib.first_commit = at
                if seq >= last_seq.get(repo, Int64(-1)):
                    last_seq[repo] = seq
                    lib.last_commit = at
                    lib.mojo_lines = i64_at(b.column(c_lines), r)
                    lib.mojo_files = i64_at(b.column(c_files), r)
                    lib.tooling = str_at(b.column(c_tool), r)
                    lib.mojo_version = str_at(b.column(c_ver), r)
                    lib.version_source = str_at(b.column(c_src), r)
                    lib.packaging = str_at(b.column(c_pack), r) if c_pack >= 0 else String()
    # Versions the history couldn't read (no manifest), from the files at HEAD,
    # and the estimate by date.
    var heads = repo_versions()
    for i in range(len(out)):
        ref lib = out[i]
        if lib.key in heads:
            ref rv = heads[lib.key]
            if not usable(lib.mojo_version) and usable(rv.version):
                lib.mojo_version = rv.version
                lib.version_source = rv.source
                lib.version_file = rv.file
            lib.version_estimate = rv.estimate
            lib.declared_deps = rv.declared_deps
        ob.set_version(ids[i], lib.mojo_version, lib.version_estimate)
    _dependencies(out, names)
    # Biggest first.
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].mojo_lines < out[j].mojo_lines:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def repo_versions() raises -> Dict[String, RepoVersion]:
    """Each repository's row of mojo.repo_versions (the newest if there are
    several); empty if the table doesn't exist."""
    var out = Dict[String, RepoVersion]()
    var read = Dict[String, Int64]()
    var t = try_load("mojo", "repo_versions")
    if not t:
        return out^
    for b in t.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "read_at")
        var c_ver = col(b, "mojo_version")
        var c_src = col(b, "version_source")
        var c_file = col(b, "version_file")
        var c_est = col(b, "version_estimate")
        var c_deps = col(b, "declared_deps") if has_col(b, "declared_deps") else -1
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r)
            var at = i64_at(b.column(c_at), r)
            if repo in read and read[repo] >= at:
                continue
            read[repo] = at
            var declared = Int64(-1)
            if c_deps >= 0 and is_valid(b.column(c_deps), r):
                declared = i64_at(b.column(c_deps), r)
            out[repo] = RepoVersion(
                str_at(b.column(c_ver), r), str_at(b.column(c_src), r),
                str_at(b.column(c_file), r), str_at(b.column(c_est), r),
                declared,
            )
    return out^


def _dependencies(mut libs: List[Library], names: Names) raises:
    """Each library's dependencies from mojo.repo_deps, and which of them,
    and of the libraries that depend on it, are census repositories
    (`deps.resolve`). Worked out at every build rather than stored, so a
    library found later is matched to the repositories that already name
    it."""
    var t = try_load("mojo", "repo_deps")
    if not t:
        return
    var rows = List[RepoDep]()
    for b in t.value().scan().to_batches():
        rows.extend(repo_dep_rows(b))
    var repos = List[String]()
    for ref l in libs:
        repos.append(l.repo)
    var g = resolve(repos, rows, dep_forks(), names.current)
    for ref l in libs:
        if l.repo in g.declared:
            l.declared = g.declared[l.repo].copy()
        if l.repo in g.depends_on:
            l.depends_on = g.depends_on[l.repo].copy()
        if l.repo in g.used_by:
            l.used_by = g.used_by[l.repo].copy()
        if l.repo in g.via_forks:
            l.used_by_forks = g.via_forks[l.repo].copy()
        if l.repo in g.second:
            l.second_degree = g.second[l.repo].copy()


def dep_forks() raises -> Dict[String, ForkOf]:
    """The forks among the repositories named as dependencies, by lowercased
    `owner/name`, from mojo.dep_forks (the newest row of each); empty if the
    table doesn't exist."""
    var out = Dict[String, ForkOf]()
    var at = Dict[String, Int64]()
    var t = try_load("mojo", "dep_forks")
    if not t:
        return out^
    for b in t.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "fetched_at")
        var c_fork = col(b, "fork")
        var c_parent = col(b, "parent")
        var c_source = col(b, "source")
        for r in range(b.num_rows):
            var repo = str_at(b.column(c_repo), r).lower()
            var fetched = i64_at(b.column(c_at), r)
            if repo in at and at[repo] >= fetched:
                continue
            at[repo] = fetched
            if is_valid(b.column(c_fork), r) and bool_at(b.column(c_fork), r):
                out[repo] = ForkOf(str_at(b.column(c_parent), r), str_at(b.column(c_source), r))
            elif repo in out:
                _ = out.pop(repo)
    return out^


def _latest_stats(mut libs: List[Library], index: Dict[String, Int], names: Names) raises:
    """Each library's stars, forks and topics from its latest row of
    mojo.repo_stats (under any of its names), when it has one with
    numbers."""
    var stats_table = try_load("mojo", "repo_stats")
    if not stats_table:
        return
    for b in stats_table.value().scan().to_batches():
        var c_repo = col(b, "repo")
        var c_as_of = col(b, "as_of")
        var c_state = col(b, "state")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_issues = col(b, "open_issues")
        var c_watch = col(b, "watchers")
        var c_topics = col(b, "topics")
        var c_arch = col(b, "archived")
        var c_desc = col(b, "description")
        var c_lic = col(b, "license")
        var c_new = col(b, "renamed_to")
        for r in range(b.num_rows):
            var repo = names.canon(str_at(b.column(c_repo), r))
            if repo not in index:
                continue
            ref l = libs[index[repo]]
            var as_of = i32_at(b.column(c_as_of), r)
            if as_of < l.stats_as_of:
                continue
            l.state = str_at(b.column(c_state), r)
            l.renamed_to = str_at(b.column(c_new), r)
            if not is_valid(b.column(c_stars), r):
                continue  # gone, blocked: keep the numbers from before
            l.stats_as_of = as_of
            l.stars = i64_at(b.column(c_stars), r)
            l.forks = i64_at(b.column(c_forks), r)
            l.open_issues = i64_at(b.column(c_issues), r)
            l.watchers = i64_at(b.column(c_watch), r)
            l.topics = strs_at(b, c_topics, r)
            l.archived = bool_at(b.column(c_arch), r)
            var desc = str_at(b.column(c_desc), r)
            if desc.byte_length() > 0:
                l.description = desc
            var lic = str_at(b.column(c_lic), r)
            if lic.byte_length() > 0:
                l.license = lic


@fieldwise_init
struct MonthActivity(Copyable, Movable):
    var month: String
    """`YYYY-MM`."""
    var stars: Int64
    var forks: Int64
    var releases: Int64
    var issues_opened: Int64
    var prs_opened: Int64
    var pushes: Int64
    var days_active: Int


def activity_months() raises -> List[String]:
    """The months mojo.activity has rows in, oldest first: the months of GH
    Archive loaded so far (`YYYY-MM`)."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    if not exists("mojo", "activity"):
        return out^
    for b in load("mojo", "activity").scan().select(["day"]).to_batches():
        for r in range(b.num_rows):
            var m = String(day_text(i32_at(b.column(0), r))[byte=:7])
            if m not in seen:
                seen[m] = True
                out.append(m)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def _repo_filter(repo: String) -> String:
    return String('["=","repo","', repo.replace('"', ""), '"]')


def activity_all(repo: String = "") raises -> Dict[String, List[MonthActivity]]:
    """GH Archive activity summed by month per repo (only `repo`'s when
    given), oldest month first; only the months with events."""
    var out = Dict[String, List[MonthActivity]]()
    if not exists("mojo", "activity"):
        return out^
    var at = Dict[String, Int]()  # repo|month -> index in the repo's list
    var scan = load("mojo", "activity").scan()
    if repo.byte_length() > 0:
        scan = scan.filter(_repo_filter(repo))
    for b in scan.to_batches():
        var c_repo = col(b, "repo")
        var c_day = col(b, "day")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        var c_rel = col(b, "releases")
        var c_iss = col(b, "issues_opened")
        var c_prs = col(b, "prs_opened")
        var c_push = col(b, "pushes")
        for r in range(b.num_rows):
            var name = str_at(b.column(c_repo), r)
            var m = String(day_text(i32_at(b.column(c_day), r))[byte=:7])
            var key = String(name, "|", m)
            if name not in out:
                out[name] = List[MonthActivity]()
            ref list = out[name]
            if key not in at:
                at[key] = len(list)
                list.append(MonthActivity(m, 0, 0, 0, 0, 0, 0, 0))
            ref a = list[at[key]]
            a.stars += i64_at(b.column(c_stars), r)
            a.forks += i64_at(b.column(c_forks), r)
            a.releases += i64_at(b.column(c_rel), r)
            a.issues_opened += i64_at(b.column(c_iss), r)
            a.prs_opened += i64_at(b.column(c_prs), r)
            a.pushes += i64_at(b.column(c_push), r)
            a.days_active += 1
    for e in out.items():
        ref list = out[e.key]
        for i in range(1, len(list)):
            var j = i
            while j > 0 and list[j - 1].month > list[j].month:
                list.swap_elements(j - 1, j)
                j -= 1
    return out^


def merge_months(a: List[MonthActivity], b: List[MonthActivity]) -> List[MonthActivity]:
    """Two lists of a repo's activity by month (oldest first), as one: the
    months of both, a month in both summed. A renamed repo's events are
    under each name it had (#181)."""
    var out = List[MonthActivity]()
    var i = 0
    var j = 0
    while i < len(a) or j < len(b):
        if j >= len(b) or (i < len(a) and a[i].month < b[j].month):
            out.append(a[i].copy())
            i += 1
        elif i >= len(a) or b[j].month < a[i].month:
            out.append(b[j].copy())
            j += 1
        else:
            var m = a[i].copy()
            m.stars += b[j].stars
            m.forks += b[j].forks
            m.releases += b[j].releases
            m.issues_opened += b[j].issues_opened
            m.prs_opened += b[j].prs_opened
            m.pushes += b[j].pushes
            m.days_active += b[j].days_active
            out.append(m^)
            i += 1
            j += 1
    return out^


def merge_releases(a: List[Release], b: List[Release]) -> List[Release]:
    """Two lists of a repo's releases and tags (newest first), as one,
    newest first; a tag in both is kept once, from `a`."""
    var out = a.copy()
    var seen = Dict[String, Bool]()
    for ref r in a:
        seen[r.tag] = True
    for ref r in b:
        if r.tag not in seen:
            seen[r.tag] = True
            out.append(r.copy())
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].at < out[j].at:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def activity_by_month(repo: String) raises -> List[MonthActivity]:
    """`repo`'s GH Archive activity summed by month, oldest first."""
    var all = activity_all(repo)
    if repo in all:
        return all.pop(repo)
    return List[MonthActivity]()


@fieldwise_init
struct Release(Copyable, Movable):
    var tag: String
    var name: String
    var at: Int64
    """Published (microseconds), or the event's day when the payload had no
    date."""
    var prerelease: Bool
    var source: String
    """`release` (GH Archive's ReleaseEvent) or `tag` (git)."""
    var commit: String
    var mojo_version: String


def releases_all(repo: String = "") raises -> Dict[String, List[Release]]:
    """The published releases (mojo.releases) and git tags (mojo.tags) of
    every repo (only `repo`'s when given), newest first; a tag that is also a
    release is listed once, as the release, with the tag's commit and Mojo
    version."""
    var out = Dict[String, List[Release]]()
    var by_tag = Dict[String, Int]()  # repo|tag -> index in the repo's list
    if exists("mojo", "releases"):
        var scan = load("mojo", "releases").scan()
        if repo.byte_length() > 0:
            scan = scan.filter(_repo_filter(repo))
        for b in scan.to_batches():
            var c_repo = col(b, "repo")
            var c_tag = col(b, "tag")
            var c_name = col(b, "name")
            var c_pub = col(b, "published_at")
            var c_day = col(b, "day")
            var c_pre = col(b, "prerelease")
            for r in range(b.num_rows):
                var name = str_at(b.column(c_repo), r)
                var tag = str_at(b.column(c_tag), r)
                var key = String(name, "|", tag)
                if key in by_tag:
                    continue
                var at = i64_at(b.column(c_pub), r)
                if at == 0:
                    at = i32_at(b.column(c_day), r) * 86_400_000_000
                if name not in out:
                    out[name] = List[Release]()
                ref list = out[name]
                by_tag[key] = len(list)
                list.append(Release(
                    tag, str_at(b.column(c_name), r), at,
                    bool_at(b.column(c_pre), r), String("release"), String(), String(),
                ))
    if exists("mojo", "tags"):
        var scan = load("mojo", "tags").scan()
        if repo.byte_length() > 0:
            scan = scan.filter(_repo_filter(repo))
        for b in scan.to_batches():
            var c_repo = col(b, "repo")
            var c_tag = col(b, "tag")
            var c_commit = col(b, "commit")
            var c_at = col(b, "tagged_at")
            var c_ver = col(b, "mojo_version")
            for r in range(b.num_rows):
                var name = str_at(b.column(c_repo), r)
                var tag = str_at(b.column(c_tag), r)
                var commit = str_at(b.column(c_commit), r)
                var ver = str_at(b.column(c_ver), r)
                var key = String(name, "|", tag)
                if name not in out:
                    out[name] = List[Release]()
                ref list = out[name]
                if key in by_tag:
                    ref x = list[by_tag[key]]
                    x.commit = commit
                    x.mojo_version = ver
                    continue
                by_tag[key] = len(list)
                list.append(Release(
                    tag, String(), i64_at(b.column(c_at), r), False, String("tag"),
                    commit, ver,
                ))
    for e in out.items():
        ref list = out[e.key]
        for i in range(1, len(list)):
            var j = i
            while j > 0 and list[j - 1].at < list[j].at:
                list.swap_elements(j - 1, j)
                j -= 1
    return out^


def releases(repo: String) raises -> List[Release]:
    """`repo`'s releases and tags, newest first (`releases_all`)."""
    var all = releases_all(repo)
    if repo in all:
        return all.pop(repo)
    return List[Release]()


def histories(repo: String = "") raises -> Dict[String, List[Point]]:
    """One point per commit of every repo (only `repo`'s when given), oldest
    first."""
    var out = Dict[String, List[Point]]()
    if not exists("mojo", "commits"):
        return out^
    var seqs = Dict[String, List[Int64]]()
    var t = load("mojo", "commits")
    # `subject` (field 11) came later: a table from before has no such column.
    var with_subject = t.metadata.schema().has_field(11)
    var with_changes = t.metadata.schema().has_field(12)
    var scan = t.scan()
    if repo.byte_length() > 0:
        scan = scan.filter(_repo_filter(repo))
    var names: List[String] = ["repo", "committed_at", "seq", "mojo_lines", "sha", "tooling", "mojo_version"]
    if with_subject:
        names.append("subject")
    if with_changes:
        names.append("changes")
    for b in scan.select(names^).to_batches():
        var c_repo = col(b, "repo")
        var c_at = col(b, "committed_at")
        var c_seq = col(b, "seq")
        var c_lines = col(b, "mojo_lines")
        var c_sha = col(b, "sha")
        var c_tool = col(b, "tooling")
        var c_ver = col(b, "mojo_version")
        var c_subj = col(b, "subject") if with_subject else -1
        var c_chg = col(b, "changes") if with_changes else -1
        for r in range(b.num_rows):
            var name = str_at(b.column(c_repo), r)
            if name not in out:
                out[name] = List[Point]()
                seqs[name] = List[Int64]()
            seqs[name].append(i64_at(b.column(c_seq), r))
            out[name].append(
                Point(
                    i64_at(b.column(c_at), r),
                    i64_at(b.column(c_lines), r),
                    str_at(b.column(c_sha), r),
                    str_at(b.column(c_tool), r),
                    str_at(b.column(c_ver), r),
                    str_at(b.column(c_subj), r) if c_subj >= 0 else String(),
                    str_at(b.column(c_chg), r) if c_chg >= 0 else String(),
                )
            )
    # By seq (the scan's order is the files').
    for e in out.items():
        ref list = out[e.key]
        ref sq = seqs[e.key]
        for i in range(1, len(list)):
            var j = i
            while j > 0 and sq[j - 1] > sq[j]:
                sq.swap_elements(j - 1, j)
                list.swap_elements(j - 1, j)
                j -= 1
    return out^


def history(repo: String) raises -> List[Point]:
    """One point per commit of `repo`, oldest first."""
    var all = histories(repo)
    if repo in all:
        return all.pop(repo)
    return List[Point]()


def migrations(repo: String = "") raises -> List[Migration]:
    """Every migration (of `repo`, if given), oldest first."""
    var out = List[Migration]()
    if not exists("mojo", "migrations"):
        return out^
    var scan = load("mojo", "migrations").scan()
    if repo.byte_length() > 0:
        scan = scan.filter(String('["=","repo","', repo.replace('"', ""), '"]'))
    for b in scan.to_batches():
        var c_repo = col(b, "repo")
        var c_sha = col(b, "sha")
        var c_at = col(b, "committed_at")
        var c_kind = col(b, "kind")
        var c_from = col(b, "from_value")
        var c_to = col(b, "to_value")
        for r in range(b.num_rows):
            out.append(
                Migration(
                    str_at(b.column(c_repo), r),
                    str_at(b.column(c_sha), r),
                    i64_at(b.column(c_at), r),
                    str_at(b.column(c_kind), r),
                    str_at(b.column(c_from), r),
                    str_at(b.column(c_to), r),
                )
            )
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].at > out[j].at:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


@fieldwise_init
struct VersionMonth(Copyable, Movable):
    var month: String
    var version: String
    var repos: Int


def versions_by_month() raises -> List[VersionMonth]:
    return versions_of(migrations())


def versions_of(ms: List[Migration]) -> List[VersionMonth]:
    """How many libraries moved to each Mojo version, by month, in version
    order within a month."""
    var counts = Dict[String, Int]()
    var seen = Dict[String, Bool]()
    for ref m in ms:
        if m.kind != "mojo_version" or m.to_value.byte_length() == 0:
            continue
        var month = String(day(m.at)[byte=:7])
        var k = String(month, "|", m.to_value)
        var once = String(k, "|", m.repo)
        if once in seen:
            continue
        seen[once] = True
        counts[k] = counts.get(k, 0) + 1
    var out = List[VersionMonth]()
    for e in counts.items():
        var parts = e.key.split("|")
        out.append(VersionMonth(String(parts[0]), String(parts[1]), e.value))
    for i in range(1, len(out)):
        var j = i
        while j > 0 and (
            out[j - 1].month > out[j].month
            or (
                out[j - 1].month == out[j].month
                and compare_versions(out[j - 1].version, out[j].version) > 0
            )
        ):
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


struct Sources(Copyable, Movable):
    """Where the console's data stood when it was read: the current
    snapshot of each table it builds pages from, to tell when anything
    changed."""

    var ids: List[Int64]
    """The current snapshot id of each table `read_sources` looks at (repos,
    commits, repo_stats, activity, ..., repo_embeddings), -1 for a table that doesn't exist or is
    empty."""
    var as_of_ms: Int64
    """The newest snapshot time of those tables."""
    var days: Int
    """GH Archive days loaded, by gharchive.events' or gharchive.repo_hour's
    snapshots (`read_days`)."""
    var first_day: String
    var last_day: String
    var archive_days: Int
    """Of `days`, the ones from `ARCHIVE_START` to the `until` given
    `count_days`: what the home page's coverage counts against
    `archive_days_due`."""
    var event_days: Int
    """Of `days`, the ones gharchive.events' snapshots name: the days whose
    raw events are kept (loaded with `GHARCHIVE_EVENTS` on)."""
    var stored: List[Stored]
    """What each table of the lake holds (`read_stored`), in `lake_tables`'
    order; a table that doesn't exist or has no snapshot is left out."""

    def __init__(out self):
        self.ids = List[Int64]()
        self.as_of_ms = 0
        self.days = 0
        self.archive_days = 0
        self.event_days = 0
        self.stored = List[Stored]()
        self.first_day = String()
        self.last_day = String()

    def same_as(self, other: Sources) -> Bool:
        if len(self.ids) != len(other.ids):
            return False
        for i in range(len(self.ids)):
            if self.ids[i] != other.ids[i]:
                return False
        return True


def read_sources() raises -> Sources:
    """The snapshots the tables are at now (metadata only) and the time of
    the newest."""
    var out = Sources()
    var names: List[String] = [
        "repos", "commits", "repo_stats", "activity", "migrations", "releases", "tags",
        "repo_embeddings", "issues",
    ]
    for name in names:
        var t = try_load("mojo", name)
        if not t or not t.value().metadata.has_current_snapshot:
            out.ids.append(-1)
            continue
        out.ids.append(t.value().metadata.current_snapshot_id)
        out.as_of_ms = max(out.as_of_ms, t.value().metadata.current_snapshot().timestamp_ms)
    return out^


def read_days(mut src: Sources, until: String = String()) raises:
    """Count the GH Archive days loaded into `src`: the days the snapshots
    of gharchive.events and gharchive.repo_hour name (`count_days`); and
    read what every table holds (`read_stored`), those two loaded once."""
    var events = try_load("gharchive", "events")
    var repo_hour = try_load("gharchive", "repo_hour")
    count_days(src, events, repo_hour, until)
    read_stored(src, events^, repo_hour^)


def count_days(
    mut src: Sources,
    events: Optional[Table],
    repo_hour: Optional[Table],
    until: String = String(),
) raises:
    """The days the snapshots' `orca.partitions` name, of either table.
    gharchive commits both for every day it loads, so with the events on
    they name the same days, and gharchive.repo_hour alone keeps counting
    the days loaded with `GHARCHIVE_EVENTS=off`; the events still count the
    days loaded before that, should their repo_hour snapshots be gone.
    `src.archive_days` counts the ones up to `until` (a `YYYY-MM-DD`)."""
    var seen = Dict[String, Bool]()
    if events:
        _snapshot_days(events.value(), seen, src)
    src.event_days = len(seen)
    if repo_hour:
        _snapshot_days(repo_hour.value(), seen, src)
    src.days = len(seen)
    # The coverage: the days from ARCHIVE_START to `until` (no end if empty).
    var start = day_text(Int64(ARCHIVE_START))
    src.archive_days = 0
    for k in seen.keys():
        if k >= start and (until.byte_length() == 0 or k <= until):
            src.archive_days += 1


def _snapshot_days(t: Table, mut seen: Dict[String, Bool], mut src: Sources) raises:
    """Adds the days `t`'s snapshots name to `seen`, and widens `src`'s
    first and last day to them."""
    for ref s in t.metadata.snapshots:
        for key in s.summary.get("orca.partitions", String("")).split(","):
            var k = String(key.strip())
            # A day looks like 2026-10-13; other keys aren't counted.
            if k.byte_length() == 10 and k[byte=4] == "-" and k not in seen:
                seen[k] = True
                if src.first_day.byte_length() == 0 or k < src.first_day:
                    src.first_day = k
                if k > src.last_day:
                    src.last_day = k


def lake_tables() -> List[String]:
    """Every table the pipelines write: GH Archive's (gharchive.*) and the
    census's (mojo.*)."""
    return [
        EVENTS, CANDIDATES, REPO_HOUR, GH_RELEASES, REPOS, CHECKED, COMMITS, MIGRATIONS, TAGS,
        REPO_VERSIONS, REPO_DEPS, REPO_STATS, ACTIVITY, ACTIVITY_REPOS, RELEASES,
    ]


@fieldwise_init
struct Stored(Copyable, Movable):
    """What a table holds at its current snapshot: the summary's
    `total-records` and `total-files-size` (its data files, in bytes), which
    every commit carries forward, so reading them is metadata only."""

    var table: String
    """`namespace.name`, or for a sum (`stored_total`) the prefix summed."""
    var records: Int64
    var bytes: Int64


def stored_of(name: String, t: Table) raises -> Optional[Stored]:
    """`t`'s `Stored` under `name`; none when it has no snapshot. A summary
    without the totals counts as 0."""
    if not t.metadata.has_current_snapshot:
        return None
    var s = t.metadata.current_snapshot().summary.copy()
    return Stored(
        name,
        Int64(Int(s.get("total-records", String("0")))),
        Int64(Int(s.get("total-files-size", String("0")))),
    )


def read_stored(
    mut src: Sources, events: Optional[Table] = None, repo_hour: Optional[Table] = None
) raises:
    """Fill `src.stored` from every table of `lake_tables` (metadata only);
    gharchive.events and gharchive.repo_hour are the ones given, if any,
    since `read_days` has them loaded already."""
    src.stored = List[Stored]()
    for name in lake_tables():
        var t: Optional[Table]
        if name == EVENTS and events:
            t = events.copy()
        elif name == REPO_HOUR and repo_hour:
            t = repo_hour.copy()
        else:
            var dot = name.find(".")
            t = try_load(String(name[byte=:dot]), String(name[byte = dot + 1 :]))
        if t:
            var st = stored_of(name, t.value())
            if st:
                src.stored.append(st.value().copy())


def stored_total(stored: List[Stored], prefix: String = String()) -> Stored:
    """The sum of the tables whose name starts with `prefix` (`gharchive.`,
    `mojo.`, or a whole table's name); of all of them for none."""
    var out = Stored(prefix, 0, 0)
    for ref st in stored:
        if st.table.startswith(prefix):
            out.records += st.records
            out.bytes += st.bytes
    return out^


@fieldwise_init
struct Gain(Copyable, Movable):
    """What a repository gained over some days, from mojo.activity."""

    var stars: Int64
    """WatchEvents."""
    var forks: Int64
    """ForkEvents."""


def gains_since(since_day: Int) raises -> Dict[String, Gain]:
    """Stars and forks per repository on the days since `since_day` (days
    since 1970-01-01), from mojo.activity; only repositories with some."""
    var out = Dict[String, Gain]()
    var activity_table = try_load("mojo", "activity")
    if not activity_table:
        return out^
    for b in activity_table.value().scan().select(["repo", "day", "stars", "forks"]).to_batches():
        var c_repo = col(b, "repo")
        var c_day = col(b, "day")
        var c_stars = col(b, "stars")
        var c_forks = col(b, "forks")
        for r in range(b.num_rows):
            if Int(i32_at(b.column(c_day), r)) < since_day:
                continue
            var s = i64_at(b.column(c_stars), r)
            var f = i64_at(b.column(c_forks), r)
            if s > 0 or f > 0:
                var repo = str_at(b.column(c_repo), r)
                var g = out.get(repo, Gain(0, 0))
                out[repo] = Gain(g.stars + s, g.forks + f)
    return out^
