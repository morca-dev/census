"""The Overview page's numbers, computed once from the commit rows.

A `Builder` is fed every repository (`add_repo`) and every row of
mojo.commits (`add_commit`), in any order, and `finish` gives the cards, the
monthly curves, the repos per Mojo version family and the adoption of the
newest release. Nothing here reads the lake or the clock: the caller passes
today's day, so the tests run over a few in-memory rows.

Per commit the work is a few integer compares into flat arrays: one
`RepoAcc` per repository, and one cell per (repository, month) holding the
repository's last commit of that month. The curves are filled from the cells
at the end, carrying each repository's last state forward month by month.
"""

from search import sort_buckets, sort_families, version_bucket, version_family
from versions import compare_versions, is_python_tool, version_key

comptime DAY_US = Int64(86_400_000_000)
comptime BASE_MONTH = (2022 - 1970) * 12
"""The first month of the curves (months since 1970-01): Mojo's first public
code is from 2022, and an earlier commit counts in this month."""
comptime ARCHIVE_START = 19358
"""2023-01-01, in days since 1970-01-01: the first GH Archive day the
gharchive pipeline loads (its `Daily["2023-01-01"]`)."""
comptime ACTIVE_DAYS = 365
"""A repository is active when its latest commit is this recent."""
comptime TOOL_NONE = UInt8(0)
comptime TOOL_MAGIC = UInt8(1)
comptime TOOL_PIXI = UInt8(2)
comptime TOOL_BAZEL = UInt8(3)
comptime TOOL_PYTHON = UInt8(4)
"""uv, poetry, pdm and pip together: Mojo from PyPI."""


def month_of_days(days: Int) -> Int:
    """Months since 1970-01 of a day number (days since 1970-01-01)."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y - 1970) * 12 + m - 1


def archive_days_due(today: Int) -> Int:
    """The GH Archive days from `ARCHIVE_START` to yesterday: the days
    gharchive should have loaded by `today` (days since 1970-01-01), the
    whole of the home page's coverage."""
    return max(today - ARCHIVE_START, 0)


def month_label(index: Int) -> String:
    """`2025-07` for months-since-1970 `index`."""
    var m = index % 12 + 1
    return String(1970 + index // 12, "-", "0" if m < 10 else "", m)


def tool_code(tooling: String) -> UInt8:
    """`magic` is 1, `pixi` 2, `bazel` 3, a Python build tool (`uv`,
    `poetry`, `pdm`, `pip`) 4, anything else (`none`, empty) 0."""
    if tooling == "magic":
        return TOOL_MAGIC
    if tooling == "pixi":
        return TOOL_PIXI
    if tooling == "bazel":
        return TOOL_BAZEL
    if is_python_tool(tooling):
        return TOOL_PYTHON
    return TOOL_NONE


comptime NO_MANIFEST = "no-manifest"
comptime UNKNOWN = "unknown"


def unversioned(commits: Int, tool: UInt8) -> String:
    """Why a repository has no version: `no-manifest` if its history was read
    and has no manifest or lock file (nothing where the census looks), else
    `unknown` (it has a manifest that names no Mojo version, or its history
    isn't read yet)."""
    if commits > 0 and tool == TOOL_NONE:
        return String(NO_MANIFEST)
    return String(UNKNOWN)


def bucket_of(version: String, why: String = String(UNKNOWN)) -> String:
    """The version bucket of `version`, or `why` (`unknown`, `no-manifest`)
    for no version."""
    if version.byte_length() == 0:
        return why
    return version_bucket(version)


def family_of(version: String, why: String = String(UNKNOWN)) -> String:
    """The Mojo version family of `version`, or `why` for no version."""
    if version.byte_length() == 0:
        return why
    return version_family(version)


@fieldwise_init
struct RepoAcc(Copyable, Movable):
    """What one repository's commits add up to."""

    var name: String
    var commits: Int
    var first_at: Int64
    var last_seq: Int64
    var last_at: Int64
    var last_lines: Int64
    var version: String
    var cut_seq: Int64
    """The newest commit at or before 30 days ago, -1 for none."""
    var cut_lines: Int64
    var commits30: Int
    var commits60: Int
    """Commits 30 to 60 days ago."""
    var estimate: String
    """The release current at the last Mojo commit, by date; a guess."""
    var tool: UInt8
    """The tooling (`tool_code`) at the newest commit."""


struct Overview(Movable):
    """The numbers of the Overview page."""

    var repos: Int
    """Repositories in mojo.repos."""
    var with_history: Int
    var commits: Int
    var commits_30: Int
    var commits_prev_30: Int
    var lines: Int64
    var lines_30_ago: Int64
    var repos_30_ago: Int
    """Repositories whose first commit is at least 30 days old."""
    var new_this_month: Int
    var new_last_month: Int
    var active: Int
    """Repositories with a commit in the last 12 months."""
    var buckets: List[String]
    """The version buckets (`version_bucket`) in Mojo's order: `pre-1.0`, each
    1.x minor, then `other`, `unknown` last."""
    var bucket_repos: List[Int]
    var bucket_active: List[Int]
    var families: List[String]
    """The same repos by the old families (`24.x`, `0.26.x`, `1.x`), for the JSON."""
    var family_repos: List[Int]
    var family_active: List[Int]
    var est_buckets: List[String]
    """`buckets` again, a repository with no detected version counted under
    the release its date estimates (`?estimate=1`)."""
    var est_bucket_repos: List[Int]
    var est_bucket_active: List[Int]
    var est_families: List[String]
    var est_family_repos: List[Int]
    var est_family_active: List[Int]
    var unread: Int
    """Repositories in the `unknown` bucket whose history isn't read yet
    (the rest of `unknown` were read: a manifest that names no version)."""
    var est_unread: Int
    """The same in `est_buckets`: not read, and nothing to estimate from."""
    var months: List[String]
    var lines_series: List[Int64]
    var repos_series: List[Int64]
    var commits_series: List[Int64]
    var tool_none: List[Int64]
    var tool_magic: List[Int64]
    var tool_pixi: List[Int64]
    var tool_bazel: List[Int64]
    var tool_python: List[Int64]
    var issues_opened: List[Int64]
    """Per month of `months`, from mojo.issues (`issues.add_issue_months`):
    issues opened, issues closed, pull requests opened and merged. Empty
    until they are added."""
    var issues_closed: List[Int64]
    var prs_opened: List[Int64]
    var prs_merged: List[Int64]

    def __init__(out self):
        self.repos = 0
        self.with_history = 0
        self.commits = 0
        self.commits_30 = 0
        self.commits_prev_30 = 0
        self.lines = 0
        self.lines_30_ago = 0
        self.repos_30_ago = 0
        self.new_this_month = 0
        self.new_last_month = 0
        self.active = 0
        self.buckets = List[String]()
        self.bucket_repos = List[Int]()
        self.bucket_active = List[Int]()
        self.families = List[String]()
        self.family_repos = List[Int]()
        self.family_active = List[Int]()
        self.est_buckets = List[String]()
        self.est_bucket_repos = List[Int]()
        self.est_bucket_active = List[Int]()
        self.est_families = List[String]()
        self.est_family_repos = List[Int]()
        self.est_family_active = List[Int]()
        self.unread = 0
        self.est_unread = 0
        self.months = List[String]()
        self.lines_series = List[Int64]()
        self.repos_series = List[Int64]()
        self.commits_series = List[Int64]()
        self.tool_none = List[Int64]()
        self.tool_magic = List[Int64]()
        self.tool_pixi = List[Int64]()
        self.tool_bazel = List[Int64]()
        self.tool_python = List[Int64]()
        self.issues_opened = List[Int64]()
        self.issues_closed = List[Int64]()
        self.prs_opened = List[Int64]()
        self.prs_merged = List[Int64]()


struct Recent(Movable):
    """Per repository, in the order asked for (`Builder.recent`)."""

    var commits30: List[Int64]
    """Commits in the last 30 days."""
    var lines_delta: List[Int64]
    """The change in lines of Mojo over the 30 days: now, less the newest
    commit at or before 30 days ago (0 for none)."""

    def __init__(out self):
        self.commits30 = List[Int64]()
        self.lines_delta = List[Int64]()


struct Builder(Movable):
    var now_days: Int
    var months: Int
    """How many months the cells cover, from `BASE_MONTH` to this month."""
    var accs: List[RepoAcc]
    var ids: Dict[String, Int]
    """Each repository's index in `accs`, by name: one accumulator per name,
    however many rows of mojo.repos name it."""
    var repo_rows: Int
    """Rows of mojo.repos read, duplicates included (`model.libraries`
    counts them)."""
    var cell_seq: List[Int64]
    """`accs.len * months` cells: the newest commit's seq of the repository
    in the month, -1 for none."""
    var cell_lines: List[Int64]
    var cell_tool: List[UInt8]
    var commits_by_month: List[Int64]
    var cut30: Int64
    var cut60: Int64
    var cut_active: Int64

    def __init__(out self, now_days: Int):
        self.now_days = now_days
        self.months = max(month_of_days(now_days) - BASE_MONTH + 1, 1)
        self.accs = List[RepoAcc]()
        self.ids = Dict[String, Int]()
        self.repo_rows = 0
        self.cell_seq = List[Int64]()
        self.cell_lines = List[Int64]()
        self.cell_tool = List[UInt8]()
        self.commits_by_month = List[Int64](length=self.months, fill=0)
        self.cut30 = Int64(now_days - 30) * DAY_US
        self.cut60 = Int64(now_days - 60) * DAY_US
        self.cut_active = Int64(now_days - ACTIVE_DAYS) * DAY_US

    def add_repo(mut self, name: String) -> Int:
        """A repository of mojo.repos; the id to give `add_commit`. A name
        added before keeps its id, so a duplicated row adds no second
        accumulator."""
        var known = self.ids.get(name, -1)
        if known >= 0:
            return known
        self.ids[name] = len(self.accs)
        self.accs.append(RepoAcc(name, 0, 0, -1, 0, 0, String(), -1, 0, 0, 0, String(), 0))
        var n = len(self.cell_seq) + self.months
        self.cell_seq.resize(n, -1)
        self.cell_lines.resize(n, 0)
        self.cell_tool.resize(n, 0)
        return len(self.accs) - 1

    def id_of(self, name: String) -> Int:
        """The id `add_repo` gave `name`, or -1."""
        return self.ids.get(name, -1)

    def recent(self, names: List[String]) -> Recent:
        """The last 30 days of each of `names`, in that order, joined by
        name: whatever order the caller sorted its repositories in, the
        numbers stay with their names. A name never added gets zeros."""
        var r = Recent()
        for ref n in names:
            var id = self.id_of(n)
            if id < 0:
                r.commits30.append(0)
                r.lines_delta.append(0)
                continue
            ref a = self.accs[id]
            r.commits30.append(Int64(a.commits30))
            r.lines_delta.append(a.last_lines - (a.cut_lines if a.cut_seq >= 0 else 0))
        return r^

    def add_commit(
        mut self,
        id: Int,
        at: Int64,
        seq: Int64,
        lines: Int64,
        tool: UInt8,
        version: String,
    ):
        var k = min(
            max(month_of_days(Int(at // DAY_US)) - BASE_MONTH, 0), self.months - 1
        )
        self.commits_by_month[k] += 1
        var cell = id * self.months + k
        if seq >= self.cell_seq.unsafe_ptr()[unsafe_offset=cell]:
            self.cell_seq.unsafe_ptr()[unsafe_offset=cell] = seq
            self.cell_lines.unsafe_ptr()[unsafe_offset=cell] = lines
            self.cell_tool.unsafe_ptr()[unsafe_offset=cell] = tool
        ref a = self.accs[id]
        a.commits += 1
        if a.first_at == 0 or at < a.first_at:
            a.first_at = at
        if seq >= a.last_seq:
            a.last_seq = seq
            a.last_at = at
            a.last_lines = lines
            a.version = version
            a.tool = tool
        if at > self.cut30:
            a.commits30 += 1
        elif at > self.cut60:
            a.commits60 += 1
        if at <= self.cut30 and seq >= a.cut_seq:
            a.cut_seq = seq
            a.cut_lines = lines

    def set_version(mut self, id: Int, version: String, estimate: String):
        """The version the repository states (the one its newest commit's
        lock file or manifest names, else what the files at HEAD say) and the
        estimate by date; replaces what `add_commit` set."""
        self.accs[id].version = version
        self.accs[id].estimate = estimate

    def finish(self, repos: Int) -> Overview:
        """The overview, for `repos` repositories in mojo.repos."""
        var o = Overview()
        o.repos = repos
        var now_month = month_of_days(self.now_days)
        for ref a in self.accs:
            if a.commits == 0:
                continue
            o.with_history += 1
            o.commits += a.commits
            o.commits_30 += a.commits30
            o.commits_prev_30 += a.commits60
            o.lines += a.last_lines
            if a.cut_seq >= 0:
                o.lines_30_ago += a.cut_lines
            if a.first_at <= self.cut30:
                o.repos_30_ago += 1
            var fm = month_of_days(Int(a.first_at // DAY_US))
            if fm == now_month:
                o.new_this_month += 1
            elif fm == now_month - 1:
                o.new_last_month += 1
            var active = a.last_at >= self.cut_active
            if active:
                o.active += 1
        # Buckets and families: every repository, including the ones not read.
        var bg = Groups()
        var fg = Groups()
        var ebg = Groups()
        var efg = Groups()
        for ref a in self.accs:
            var is_active = a.commits > 0 and a.last_at >= self.cut_active
            var why = unversioned(a.commits, a.tool)
            bg.add(bucket_of(a.version, why), a.version, is_active)
            fg.add(family_of(a.version, why), a.version, is_active)
            # With the estimate: a repository with no version gets its date's.
            var ev = a.version if a.version.byte_length() > 0 else a.estimate
            if a.commits == 0 and a.version.byte_length() == 0:
                o.unread += 1
                if ev.byte_length() == 0:
                    o.est_unread += 1
            ebg.add(bucket_of(ev, why), ev, is_active)
            efg.add(family_of(ev, why), ev, is_active)
        _order(bg, True)
        _order(fg, False)
        _order(ebg, True)
        _order(efg, False)
        o.est_buckets = ebg.names.copy()
        o.est_bucket_repos = ebg.repos.copy()
        o.est_bucket_active = ebg.active.copy()
        o.est_families = efg.names.copy()
        o.est_family_repos = efg.repos.copy()
        o.est_family_active = efg.active.copy()
        o.buckets = bg.names.copy()
        o.bucket_repos = bg.repos.copy()
        o.bucket_active = bg.active.copy()
        o.families = fg.names.copy()
        o.family_repos = fg.repos.copy()
        o.family_active = fg.active.copy()
        # The curves, from the first month with a commit.
        var m = self.months
        var lines = List[Int64](length=m, fill=0)
        var nrepos = List[Int64](length=m, fill=0)
        var none = List[Int64](length=m, fill=0)
        var magic = List[Int64](length=m, fill=0)
        var pixi = List[Int64](length=m, fill=0)
        var bazel = List[Int64](length=m, fill=0)
        var python = List[Int64](length=m, fill=0)
        var seq_p = self.cell_seq.unsafe_ptr()
        var lines_p = self.cell_lines.unsafe_ptr()
        var tool_p = self.cell_tool.unsafe_ptr()
        for r in range(len(self.accs)):
            var started = False
            var carry_lines = Int64(0)
            var carry_tool = TOOL_NONE
            for k in range(m):
                var cell = r * m + k
                if seq_p[unsafe_offset=cell] >= 0:
                    started = True
                    carry_lines = lines_p[unsafe_offset=cell]
                    carry_tool = tool_p[unsafe_offset=cell]
                if started:
                    lines[k] += carry_lines
                    nrepos[k] += 1
                    if carry_tool == TOOL_MAGIC:
                        magic[k] += 1
                    elif carry_tool == TOOL_PIXI:
                        pixi[k] += 1
                    elif carry_tool == TOOL_BAZEL:
                        bazel[k] += 1
                    elif carry_tool == TOOL_PYTHON:
                        python[k] += 1
                    else:
                        none[k] += 1
        var first = 0
        while first < m - 1 and nrepos[first] == 0:
            first += 1
        for k in range(first, m):
            o.months.append(month_label(BASE_MONTH + k))
            o.lines_series.append(lines[k])
            o.repos_series.append(nrepos[k])
            o.commits_series.append(self.commits_by_month[k])
            o.tool_none.append(none[k])
            o.tool_magic.append(magic[k])
            o.tool_pixi.append(pixi[k])
            o.tool_bazel.append(bazel[k])
            o.tool_python.append(python[k])
        return o^


struct Groups(Copyable, Movable):
    """Repositories counted per group (bucket or family) of their version."""

    var names: List[String]
    var repos: List[Int]
    var active: List[Int]
    var oldest: List[String]
    var index: Dict[String, Int]

    def __init__(out self):
        self.names = List[String]()
        self.repos = List[Int]()
        self.active = List[Int]()
        self.oldest = List[String]()
        self.index = Dict[String, Int]()

    def add(mut self, name: String, version: String, active: Bool):
        if name not in self.index:
            self.index[name] = len(self.names)
            self.names.append(name)
            self.repos.append(0)
            self.active.append(0)
            self.oldest.append(version)
        var i = self.index.get(name, 0)
        self.repos[i] += 1
        if active:
            self.active[i] += 1
        if len(version_key(version)) > 0 and compare_versions(version, self.oldest[i]) < 0:
            self.oldest[i] = version


def _order(mut g: Groups, buckets: Bool):
    """`g` in Mojo's order: the versions oldest first, then `other`, then
    `unknown`; the counts follow."""
    var names = List[String]()
    var old = List[String]()
    var unknown = -1
    var no_manifest = -1
    for i in range(len(g.names)):
        if g.names[i] == "unknown":
            unknown = i
            continue
        if g.names[i] == "no-manifest":
            no_manifest = i
            continue
        names.append(g.names[i])
        old.append(g.oldest[i])
    if buckets:
        sort_buckets(names, old)
    else:
        sort_families(names, old)
    var out = Groups()
    for f in names:
        var i = g.index.get(f, 0)
        out.names.append(f)
        out.repos.append(g.repos[i])
        out.active.append(g.active[i])
    if no_manifest >= 0:
        out.names.append(String("no-manifest"))
        out.repos.append(g.repos[no_manifest])
        out.active.append(g.active[no_manifest])
    if unknown >= 0:
        out.names.append(String("unknown"))
        out.repos.append(g.repos[unknown])
        out.active.append(g.active[unknown])
    g = out^


def bucket_color(bucket: String) -> String:
    """The CSS colour of a version bucket, the same on every chart: `pre-1.0`
    blue, the 1.x minors cycle through eight more colours by minor number
    (1.0 ember, 1.1 green, 1.2 purple, 1.3 amber, 1.4 ...), `other` and
    `unknown` in greys."""
    if bucket == "pre-1.0":
        return String("var(--c0)")
    if bucket == "unknown":
        return String("var(--border-strong)")
    if bucket == "no-manifest":
        return String("var(--border)")
    if bucket == "other":
        return String("var(--c5)")
    var dot = bucket.find(".").or_else(-1)
    if dot < 0:
        return String("var(--c5)")
    try:
        var major = Int(String(bucket[byte=:dot]))
        var minor = Int(String(bucket[byte = dot + 1 :]))
        var slot = (minor + (major - 1) * 3) % 8
        # c1..c4 then c6..c9 (c5 is the grey of `other`).
        return String("var(--c", slot + 1 if slot < 4 else slot + 2, ")")
    except:
        return String("var(--c5)")


def top_gains(gains: List[Int64], n: Int) -> List[Int]:
    """The indices of the `n` largest positive values of `gains`, largest
    first; ties keep the order they came in."""
    var out = List[Int]()
    for i in range(len(gains)):
        if gains[i] <= 0:
            continue
        var j = len(out)
        out.append(i)
        while j > 0 and gains[out[j - 1]] < gains[i]:
            out[j] = out[j - 1]
            j -= 1
        out[j] = i
        if len(out) > n:
            _ = out.pop()
    return out^


comptime RISING_FORK_WEIGHT = Int64(3)
"""What a fork gained in the window counts for in `rising_score`, in stars.
A fork is a stronger sign than a star (someone means to change or build on
the code) and rarer: the census's repos have about one fork for every ten
stars (modular/modular 30,110 and 3,236, tairov/llama2.mojo 2,129 and 139).
At 3 a fork outweighs a star without a handful of forks outranking a
repo's stars."""
comptime RISING_USED_BY_WEIGHT = Int64(5)
"""What each census repo that depends on it counts for, in stars. A
declared dependency is the strongest sign of use, but `mojo.repo_deps` has
HEAD only, no history, so this is the total now, not a gain: kept smaller
than its strength would say, and it only reorders repos that gained a star
or a fork (`rising_score`), so an established library doesn't sit in Rising
for being established."""


def rising_score(stars: Int64, forks: Int64, used_by: Int64) -> Int64:
    """The Rising ranking: `stars` and `forks` gained in the window (GH
    Archive's WatchEvents and ForkEvents), plus the repos that depend on it
    now, weighted (`RISING_FORK_WEIGHT`, `RISING_USED_BY_WEIGHT`). 0 for a
    repo that gained neither stars nor forks."""
    if stars + forks <= 0:
        return 0
    return stars + RISING_FORK_WEIGHT * forks + RISING_USED_BY_WEIGHT * used_by
