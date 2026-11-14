"""A repository's current name, and the names it had before (#181).

The census keys a repository by the `owner/name` it was found under
(`mojo.repos`' `repo`), and every table mojo_history, mojo_versions,
mojo_stats and mojo_issues write uses that key. GitHub keeps a renamed or
transferred repository's id, and redirects its old name: mojo_stats's daily
`GET /repos/{key}` comes back with the new `full_name` (a `renamed` row of
`mojo.repo_stats`, with `renamed_to`) and the `id` (`repo_id`). GH Archive's
events after the rename carry the new name only.

`names_from` joins the names that belong together, through `renamed_to` and
through a shared `repo_id` (two keys of mojo.repos that are one repository,
the second found under its new name), and gives each group its current
name: the one GitHub gave on the latest day it answered. The rows stay
keyed as they were written, which keeps every migration additive; readers
map a name to the current one with `Names.canon`, and the old names are
kept as aliases (`Names.names_of`), which the console's search and
redirects, mojo_activity's members, `deps.resolve` and mojo_repos's check
for repositories it already has use.

A name GitHub gives a new repository after the old one moved away isn't
told apart from the old one: it would be joined to the renamed repository.
"""

from iceberg.catalog.filesystem import Table
from parquet import RecordBatch

from cols import col, has_col, i32_at, i64_at, str_at


@fieldwise_init
struct NameRow(Copyable, Movable):
    """What one row of `mojo.repo_stats` says about a repository's name."""

    var repo: String
    """The census's key for it (mojo.repos' `repo`), the name asked about."""
    var as_of: Int64
    """The day of the row (days since 1970)."""
    var state: String
    var renamed_to: String
    """GitHub's `full_name` when it differs from `repo`, else ""."""
    var repo_id: Int64
    """GitHub's `id`; 0 when the row is from before it was recorded."""

    def answered(self) -> Bool:
        """Whether GitHub answered with the repository (`ok` or `renamed`)."""
        return self.state == "ok" or self.state == "renamed"

    def name(self) -> String:
        """The repository's name on the row's day."""
        if self.state == "renamed" and self.renamed_to.byte_length() > 0:
            return self.renamed_to
        return self.repo


def name_columns(t: Table) -> List[String]:
    """The columns of `mojo.repo_stats` `name_rows` reads, to `select`:
    `repo_id` only once the table has it (mojo_stats adds it on its first
    run since #181)."""
    var out: List[String] = ["repo", "as_of", "state", "renamed_to"]
    try:
        _ = t.metadata.schema().find_by_name("repo_id")
        out.append("repo_id")
    except:
        pass
    return out^


def name_rows(b: RecordBatch) raises -> List[NameRow]:
    """The name columns of a scanned `mojo.repo_stats` batch; a table from
    before `repo_id` was added reads it as 0."""
    var out = List[NameRow]()
    var c_repo = col(b, "repo")
    var c_as_of = col(b, "as_of")
    var c_state = col(b, "state")
    var c_new = col(b, "renamed_to")
    var c_id = col(b, "repo_id") if has_col(b, "repo_id") else -1
    for r in range(b.num_rows):
        out.append(NameRow(
            str_at(b.column(c_repo), r),
            i32_at(b.column(c_as_of), r),
            str_at(b.column(c_state), r),
            str_at(b.column(c_new), r),
            i64_at(b.column(c_id), r) if c_id >= 0 else Int64(0),
        ))
    return out^


struct Names(Copyable, Movable):
    """Every name the census knows a repository by, lowercased, to its
    current name, and per current name all of them."""

    var current: Dict[String, String]
    """A lowercased name (a key or a name GitHub gave) to the current name."""
    var all: Dict[String, List[String]]
    """A current name to every name of the repository, the current one
    first and then the others sorted."""
    var ids: Dict[Int64, String]
    """GitHub's repository id to the current name."""

    def __init__(out self):
        self.current = Dict[String, String]()
        self.all = Dict[String, List[String]]()
        self.ids = Dict[Int64, String]()

    def canon(self, name: String) -> String:
        """The current name of the repository `name` is a name of (case
        ignored); `name` itself when it isn't a known one."""
        return self.current.get(name.lower(), name)

    def knows(self, name: String) -> Bool:
        """Whether `name` is one of the names (case ignored)."""
        return name.lower() in self.current

    def known_as(self, name: String, id: Int64) -> String:
        """The current name of the repository GitHub calls `name` with id
        `id` (0 for unknown), when it is one of these, else "": mojo_repos
        doesn't add a repository again under a new name."""
        if self.knows(name):
            return self.canon(name)
        if id > 0 and id in self.ids:
            return self.ids.get(id, String())
        return String()

    def names_of(self, name: String) -> List[String]:
        """Every name of the repository `name` is a name of, the current one
        first; just `name` when it isn't a known one."""
        var cur = self.canon(name)
        var ns = self.all.get(cur, List[String]())
        if len(ns) == 0:
            ns.append(name)
        return ns^

    def aliases_of(self, name: String) -> List[String]:
        """The repository's other names: `names_of` without the current one."""
        var out = List[String]()
        var ns = self.names_of(name)
        for i in range(1, len(ns)):
            out.append(ns[i])
        return out^


def _find(mut parent: Dict[String, String], x: String) -> String:
    """The root of `x`'s group (union-find, with path halving)."""
    var cur = x
    while True:
        var p = parent.get(cur, cur)
        if p == cur:
            return cur
        var pp = parent.get(p, p)
        parent[cur] = pp
        cur = pp


def _union(mut parent: Dict[String, String], a: String, b: String):
    var ra = _find(parent, a)
    var rb = _find(parent, b)
    if ra != rb:
        # The smaller string is the root, so the result doesn't depend on
        # the order rows are read in.
        if ra < rb:
            parent[rb] = ra
        else:
            parent[ra] = rb


def names_from(keys: List[String], rows: List[NameRow]) raises -> Names:
    """The names of the repositories `keys` (mojo.repos' `repo` values) from
    mojo.repo_stats' rows: a key, each `renamed_to` of its rows and each key
    with the same `repo_id` are one repository. Its current name is the
    name of its latest row with an answer (`ok` or `renamed`); one without
    any is known by its key (the first of `keys` in its group)."""
    var parent = Dict[String, String]()
    var spelled = Dict[String, String]()  # lowercased name -> as written
    for ref k in keys:
        var low = k.lower()
        if low not in spelled:
            spelled[low] = k
        parent[low] = parent.get(low, low)
    for ref r in rows:
        var low = r.repo.lower()
        if low not in spelled:
            spelled[low] = r.repo
        parent[low] = parent.get(low, low)
        if r.state == "renamed" and r.renamed_to.byte_length() > 0:
            var to = r.renamed_to.lower()
            if to not in spelled:
                spelled[to] = r.renamed_to
            _union(parent, low, to)
        if r.repo_id > 0:
            # Ids join groups as a node of their own; `#` can't start a name.
            _union(parent, low, String("#", r.repo_id))
    # The latest answer per group names it.
    var best_day = Dict[String, Int64]()
    var best = Dict[String, String]()
    var group_id = Dict[String, Int64]()
    for ref r in rows:
        if not r.answered():
            continue
        var root = _find(parent, r.repo.lower())
        if r.repo_id > 0:
            group_id[root] = r.repo_id
        if root in best_day and best_day[root] > r.as_of:
            continue
        best_day[root] = r.as_of
        best[root] = r.name()
    for ref k in keys:
        var root = _find(parent, k.lower())
        if root not in best:
            best[root] = k
    var out = Names()
    var members = Dict[String, List[String]]()
    for e in spelled.items():
        var root = _find(parent, e.key)
        if root not in best:
            continue  # a stats row for a repository mojo.repos doesn't have
        var cur = best[root]
        out.current[e.key] = cur
        if cur not in members:
            members[cur] = List[String]()
        if e.value.lower() != cur.lower():
            members[cur].append(e.value)
    for e in members.items():
        var others = e.value.copy()
        for i in range(1, len(others)):
            var j = i
            while j > 0 and others[j - 1] > others[j]:
                others.swap_elements(j - 1, j)
                j -= 1
        var ns: List[String] = [e.key]
        ns.extend(others^)
        out.all[e.key] = ns^
    for e in group_id.items():
        out.ids[e.value] = best[e.key]
    return out^
