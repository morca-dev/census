"""The console's `Cache`: the repos, the overview and every repo page's
lists as of one build, which the refresher builds from the lake and the
pages only read; and how often it looks (`refresh_secs`)."""

from std.os import getenv

from contributors import RepoContributors, read_contributors
from deps import Depended, most_depended
from listing import NEW_30D, NEW_LAST_MONTH, NEW_MONTH
from model import (
    Gain,
    Library,
    Migration,
    MonthActivity,
    Point,
    Release,
    Sources,
    VersionMonth,
    activity_all,
    activity_months,
    histories,
    libraries,
    merge_months,
    merge_releases,
    migrations,
    gains_since,
    releases_all,
    versions_of,
)
from overview import (
    ACTIVE_DAYS,
    Builder,
    Overview,
    bucket_of,
    family_of,
    month_of_days,
    rising_score,
    tool_code,
    top_gains,
    unversioned,
)

from console_migrations import _migrations_body
from issues import RepoIssues, add_issue_months, read_issue_rows, summarize
from similar import Embeddings, Neighbor, nearest, read_embeddings
from categories import categorize


comptime REFRESH_SECS = 1800
"""How often the tables' current snapshots are looked at, unless
`CONSOLE_REFRESH_SECONDS` says otherwise."""
comptime RETRY_SECS = 30
"""How soon to look again after a failed build or while nothing is built."""
comptime RISING_SHOWN = 10
comptime ACTIVE_SHOWN = 10
comptime DEPENDED_SHOWN = 10


struct RepoData(Copyable, Movable):
    """What a repo's page lists, read with every other repo's when the cache
    is built."""

    var pts: List[Point]
    """Its commits, oldest first."""
    var ms: List[Migration]
    var rels: List[Release]
    var acts: List[MonthActivity]
    var issues: RepoIssues
    """Its issues and pull requests (mojo.issues), summarized."""
    var contributors: RepoContributors
    """Its distinct commit authors, in all and by month (mojo.contributors)."""

    def __init__(out self):
        self.pts = List[Point]()
        self.ms = List[Migration]()
        self.rels = List[Release]()
        self.acts = List[MonthActivity]()
        self.issues = RepoIssues()
        self.contributors = RepoContributors.empty()


def _duplicate(key: String, key_of: Dict[String, String], name_of: Dict[String, String]) -> Bool:
    """Whether rows keyed `key` are a duplicate's: a name of a repo whose
    rows are under another key (`Library.key`), so they're left out."""
    return key not in key_of and key.lower() in name_of


struct Cache(Movable):
    """The repos and the overview, as of one build. A `Cache` is never changed
    once it is in the `Swap`: the refresher thread builds the next one beside
    it, so any number of requests can read it without a lock."""

    var ready: Bool
    var libs: List[Library]
    """Biggest (lines of Mojo now) first."""
    var lines: List[Int64]
    var files: List[Int64]
    var stars: List[Int64]
    var forks: List[Int64]
    var used_by: List[Int64]
    """How many census repos depend on each repo."""
    var buckets: List[String]
    """`bucket_of` each repo's current Mojo version."""
    var families: List[String]
    """`family_of` each repo's current Mojo version (old `?version=` links)."""
    var est_buckets: List[String]
    """`buckets` with the estimate by date for a repo with no detected version."""
    var est_families: List[String]
    var news: List[Int]
    """Bits of `listing.new_bit` for when each repo's first Mojo commit was."""
    var active: List[Bool]
    var ov: Overview
    var details: Dict[String, RepoData]
    """Per repo: the lists its page shows, all read at once at each build."""
    var loaded: List[String]
    """The months of GH Archive in mojo.activity."""
    var version_rows: List[VersionMonth]
    var migrations_body: String
    """The Migrations page's HTML, rendered at each build."""
    var commits30: List[Int64]
    """Commits in the last 30 days, per repo."""
    var active_repos: List[String]
    """The `ACTIVE_SHOWN` repos with the most commits in the last 30 days."""
    var active_commits: List[Int64]
    var active_lines: List[Int64]
    """Their net change in lines of Mojo over the 30 days."""
    var rising: List[String]
    """The `RISING_SHOWN` repos with the highest `rising_score`."""
    var rising_gain: List[Int64]
    """Stars gained in the last 30 days."""
    var rising_forks: List[Int64]
    """Forks gained in the last 30 days."""
    var rising_used_by: List[Int64]
    var rising_score: List[Int64]
    var rising_stars: List[Int64]
    """Stars now."""
    var depended: List[Depended]
    """The `DEPENDED_SHOWN` rows of Most depended on (`most_depended`):
    the repos the most census repos depend on, an owner's collapsed into
    `owner/*` when two or more would be shown."""
    var sources: Sources
    var built_day: Int
    var built_at: Int64
    """When it was built, in seconds since the epoch."""
    var repo_rows: Int
    """Rows of mojo.repos, duplicates included (for the checks)."""
    var history: List[Int64]
    """Per repo, the first-parent commits mojo_history recorded (its last
    seq + 1), for the checks."""
    var similar: Dict[String, List[Neighbor]]
    """Per repo with an embedding: its `SIMILAR_SHOWN` nearest repos."""
    var embed_model: String
    """The model and revision of the embeddings `similar` compares."""
    var embed_rev: String
    var embed_snapshot: Int64
    """The mojo.repo_embeddings snapshot they're from, -1 for none."""
    var emb: Embeddings
    """The embeddings read (one model and revision), for search by meaning."""
    var categories: List[String]
    """Each repo's category key (`categories.categorize`), in `libs`' order;
    "" for one not embedded yet."""
    var moved: Dict[String, String]
    """A renamed or transferred repo's old names, lowercased, to its
    current name, for the redirects from its old pages (#181)."""

    def __init__(out self):
        self.ready = False
        self.libs = List[Library]()
        self.lines = List[Int64]()
        self.files = List[Int64]()
        self.stars = List[Int64]()
        self.forks = List[Int64]()
        self.used_by = List[Int64]()
        self.buckets = List[String]()
        self.families = List[String]()
        self.est_buckets = List[String]()
        self.est_families = List[String]()
        self.news = List[Int]()
        self.active = List[Bool]()
        self.ov = Overview()
        self.details = Dict[String, RepoData]()
        self.loaded = List[String]()
        self.version_rows = List[VersionMonth]()
        self.migrations_body = String()
        self.commits30 = List[Int64]()
        self.active_repos = List[String]()
        self.active_commits = List[Int64]()
        self.active_lines = List[Int64]()
        self.rising = List[String]()
        self.rising_gain = List[Int64]()
        self.rising_forks = List[Int64]()
        self.rising_used_by = List[Int64]()
        self.rising_score = List[Int64]()
        self.rising_stars = List[Int64]()
        self.depended = List[Depended]()
        self.sources = Sources()
        self.built_day = 0
        self.built_at = 0
        self.repo_rows = 0
        self.history = List[Int64]()
        self.similar = Dict[String, List[Neighbor]]()
        self.embed_model = String()
        self.embed_rev = String()
        self.embed_snapshot = -1
        self.emb = Embeddings()
        self.categories = List[String]()
        self.moved = Dict[String, String]()

    def _build(mut self, today: Int, var src: Sources) raises:
        var b = Builder(today)
        var libs = libraries(b)
        var ov = b.finish(len(libs))
        # Per repo in `libs`' order (biggest first), joined by name: `b.accs`
        # is in mojo.repos' order, so its index is no repo's index in `libs`.
        var names = List[String]()
        for ref l in libs:
            names.append(l.repo)
        var recent = b.recent(names)
        var commits30 = recent.commits30.copy()
        var lines_delta = recent.lines_delta.copy()
        # The tables are keyed by the name a repo was found under (`key`),
        # and the ones from GH Archive's events by the name it had on each
        # day: both to the current name (#181). What its kept row's key has
        # comes from that key only (another key of the same repo is a
        # duplicate row, read again); the events of every name add up.
        var key_of = Dict[String, String]()
        var name_of = Dict[String, String]()
        var moved = Dict[String, String]()
        for ref l in libs:
            key_of[l.key] = l.repo
            name_of[l.repo.lower()] = l.repo
            for ref a in l.aliases:
                name_of[a.lower()] = l.repo
                if a.lower() != l.repo.lower():
                    moved[a.lower()] = l.repo
        var gains = Dict[String, Gain]()
        for e in gains_since(today - 30).items():
            var cur = name_of.get(e.key.lower(), e.key)
            var g = gains.get(cur, Gain(0, 0))
            gains[cur] = Gain(g.stars + e.value.stars, g.forks + e.value.forks)
        var cutoff = Int64(today - ACTIVE_DAYS) * 86_400_000_000
        var lines = List[Int64]()
        var files = List[Int64]()
        var stars = List[Int64]()
        var forks = List[Int64]()
        var used_by = List[Int64]()
        var users = List[List[String]]()
        var buckets = List[String]()
        var families = List[String]()
        var est_buckets = List[String]()
        var est_families = List[String]()
        var news = List[Int]()
        var now_month = month_of_days(today)
        var cut30 = Int64(today - 30) * 86_400_000_000
        var active = List[Bool]()
        var score_list = List[Int64]()
        var history = List[Int64]()
        for ref l in libs:
            var id = b.id_of(l.repo)
            history.append(b.accs[id].last_seq + 1 if id >= 0 else 0)
            lines.append(l.mojo_lines)
            files.append(l.mojo_files)
            stars.append(l.stars)
            forks.append(l.forks)
            used_by.append(Int64(len(l.used_by)))
            users.append(l.used_by.copy())
            var why = unversioned(l.commits, tool_code(l.tooling))
            buckets.append(bucket_of(l.mojo_version, why))
            families.append(family_of(l.mojo_version, why))
            var ev = l.mojo_version if l.mojo_version.byte_length() > 0 else l.version_estimate
            est_buckets.append(bucket_of(ev, why))
            est_families.append(family_of(ev, why))
            # As the Overview counts new repos: by the first Mojo commit.
            var bits = 0
            if l.commits > 0:
                var fm = month_of_days(Int(l.first_commit // 86_400_000_000))
                if fm == now_month:
                    bits |= NEW_MONTH
                elif fm == now_month - 1:
                    bits |= NEW_LAST_MONTH
                if l.first_commit > cut30:
                    bits |= NEW_30D
            news.append(bits)
            active.append(l.commits > 0 and l.last_commit >= cutoff)
            var g = gains.get(l.repo, Gain(0, 0))
            score_list.append(rising_score(g.stars, g.forks, Int64(len(l.used_by))))
        self.rising = List[String]()
        self.rising_gain = List[Int64]()
        self.rising_forks = List[Int64]()
        self.rising_used_by = List[Int64]()
        self.rising_score = List[Int64]()
        self.rising_stars = List[Int64]()
        for i in top_gains(score_list, RISING_SHOWN):
            var g = gains.get(libs[i].repo, Gain(0, 0))
            self.rising.append(libs[i].repo)
            self.rising_gain.append(g.stars)
            self.rising_forks.append(g.forks)
            self.rising_used_by.append(Int64(len(libs[i].used_by)))
            self.rising_score.append(score_list[i])
            self.rising_stars.append(libs[i].stars)
        self.depended = most_depended(names, users, stars, forks, DEPENDED_SHOWN)
        var details = Dict[String, RepoData]()
        for e in histories().items():
            if _duplicate(e.key, key_of, name_of):
                continue
            var cur = key_of.get(e.key, e.key)
            details[cur] = RepoData()
            details[cur].pts = e.value.copy()
        var all_ms = migrations()
        var kept_ms = List[Migration]()
        for ref m in all_ms:
            if _duplicate(m.repo, key_of, name_of):
                continue
            var mm = m.copy()
            mm.repo = key_of.get(m.repo, m.repo)
            kept_ms.append(mm^)
        var rows = versions_of(kept_ms)
        for ref m in kept_ms:
            if m.repo not in details:
                details[m.repo] = RepoData()
            details[m.repo].ms.append(m.copy())
        for e in releases_all().items():
            var cur = name_of.get(e.key.lower(), e.key)
            if cur not in details:
                details[cur] = RepoData()
            var prev = details[cur].rels.copy()
            details[cur].rels = merge_releases(prev, e.value)
        for e in activity_all().items():
            var cur = name_of.get(e.key.lower(), e.key)
            if cur not in details:
                details[cur] = RepoData()
            var prev = details[cur].acts.copy()
            details[cur].acts = merge_months(prev, e.value)
        var issue_rows = read_issue_rows()
        add_issue_months(ov, issue_rows)
        for e in summarize(issue_rows).items():
            if _duplicate(e.key, key_of, name_of):
                continue
            var cur = key_of.get(e.key, e.key)
            if cur not in details:
                details[cur] = RepoData()
            details[cur].issues = e.value.copy()
        for e in read_contributors().items():
            if _duplicate(e.key, key_of, name_of):
                continue
            var cur = key_of.get(e.key, e.key)
            if cur not in details:
                details[cur] = RepoData()
            details[cur].contributors = e.value.copy()
        self.loaded = activity_months()
        self.migrations_body = _migrations_body(rows) if len(rows) > 0 else String()
        self.version_rows = rows^
        self.details = details^
        self.commits30 = commits30.copy()
        self.active_repos = List[String]()
        self.active_commits = List[Int64]()
        self.active_lines = List[Int64]()
        for i in top_gains(commits30, ACTIVE_SHOWN):
            self.active_repos.append(libs[i].repo)
            self.active_commits.append(commits30[i])
            self.active_lines.append(lines_delta[i])
        self.ov = ov^
        self.lines = lines^
        self.files = files^
        self.stars = stars^
        self.forks = forks^
        self.used_by = used_by^
        self.buckets = buckets^
        self.families = families^
        self.est_buckets = est_buckets^
        self.est_families = est_families^
        self.news = news^
        self.active = active^
        self.libs = libs^
        self.history = history^
        var keep = Dict[String, Bool]()
        for ref n in names:
            keep[n] = True
        var emb = read_embeddings()
        for i in range(len(emb.repos)):
            if emb.repos[i] in key_of:
                emb.repos[i] = key_of[emb.repos[i]]
            elif _duplicate(emb.repos[i], key_of, name_of):
                emb.repos[i] = String()  # matches no repo
        self.similar = nearest(emb, keep)
        var cats = categorize(emb)
        self.categories = List[String]()
        for ref n in names:
            self.categories.append(cats.get(n, String()))
        self.embed_model = emb.model
        self.embed_rev = emb.model_rev
        self.embed_snapshot = emb.snapshot
        self.emb = emb^
        self.moved = moved^
        self.repo_rows = b.repo_rows
        self.sources = src^
        self.built_day = today
        self.ready = True

    def data(self, repo: String) -> RepoData:
        return self.details.get(repo, RepoData())

    def category_of(self, repo: String) -> String:
        for i in range(len(self.libs)):
            if self.libs[i].repo == repo:
                return self.categories[i] if i < len(self.categories) else String()
        return String()

    def moved_to(self, repo: String) -> String:
        """The current name of a repo `repo` is an old name of, or ""."""
        return self.moved.get(repo.lower(), String())

    def find(self, repo: String) -> Optional[Library]:
        for ref l in self.libs:
            if l.repo == repo:
                return l.copy()
        return None


def refresh_secs() -> Int:
    """`CONSOLE_REFRESH_SECONDS`, else `REFRESH_SECS`."""
    var v = getenv("CONSOLE_REFRESH_SECONDS")
    if v.byte_length() > 0:
        try:
            var n = Int(v)
            if n > 0:
                return n
        except:
            pass
    return REFRESH_SECS
