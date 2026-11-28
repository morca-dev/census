"""mojo.dep_names: which names of `conda` dependencies are conda-forge
packages, as mojo_stats asks anaconda.org and the console reads them
(`model.conda_forge_names`, passed to `deps.resolve`). A name conda-forge
has (`requests`, `sqlite`) is its package, not a census repository's of
that name.
"""

from morca.tables import BatchBuilder
from parquet import RecordBatch

from lake import dep_names_schema


comptime DEP_NAMES_REASK_DAYS = 30
"""How old a name's answer in mojo.dep_names may be before it is asked again:
whether conda-forge has a package hardly ever changes."""
comptime DEP_NAMES_MAX_ASK = 400
"""The most names one run asks anaconda.org about; the rest wait a day."""
comptime CONDA_FORGE_PACKAGE = "https://api.anaconda.org/package/conda-forge/"


@fieldwise_init
struct DepName(Copyable, Movable):
    """A row of `mojo.dep_names`."""

    var name: String
    var fetched_at: Int64
    var state: String
    var conda_forge: Bool

    def settled(self) -> Bool:
        """Whether anaconda.org answered (200 or 404)."""
        return self.state == "ok"


def names_due(
    lookups: Dict[String, List[String]], stored: Dict[String, DepName], now_us: Int64
) -> List[String]:
    """The names of `lookups` to ask about now, sorted: those without a
    settled row in `stored` (by name) or whose settled row is older than
    `DEP_NAMES_REASK_DAYS`."""
    var stale = now_us - Int64(DEP_NAMES_REASK_DAYS) * 86_400_000_000
    var out = List[String]()
    for n in lookups.keys():
        if n in stored:
            try:
                ref st = stored[n]
                if st.settled() and st.fetched_at >= stale:
                    continue
            except:
                pass
        out.append(n)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            out.swap_elements(j - 1, j)
            j -= 1
    return out^


def name_answer(name: String, fetched: Int64, statuses: List[Int]) -> DepName:
    """What the statuses of the requests about `name`'s forms say: on
    conda-forge if one was 200, not if every one was 404, else an error
    (the first status that was neither)."""
    var other = 0
    for s in statuses:
        if s == 200:
            return DepName(name, fetched, "ok", True)
        if s != 404 and other == 0:
            other = s
    if other != 0 or len(statuses) == 0:
        return DepName(name, fetched, String("error HTTP ", other) if other != 0 else String("error"), False)
    return DepName(name, fetched, "ok", False)


def merge_names(stored: List[DepName], asked: List[DepName]) -> List[DepName]:
    """`stored` with `asked` in: an answer replaces the name's row, an
    error replaces it only when it had no answer either, so a failed
    request keeps the last answer."""
    var by = Dict[String, Int]()
    var out = List[DepName]()
    for ref s in stored:
        by[s.name] = len(out)
        out.append(s.copy())
    for ref a in asked:
        var i = by.get(a.name, -1)
        if i < 0:
            by[a.name] = len(out)
            out.append(a.copy())
        elif a.settled() or not out[i].settled():
            out[i] = a.copy()
    return out^


def dep_names_batch(rows: List[DepName]) raises -> RecordBatch:
    """`rows` as a batch of `mojo.dep_names`."""
    var b = BatchBuilder(dep_names_schema())
    var c_name = b.col("name")
    var c_fetched = b.col("fetched_at")
    var c_state = b.col("state")
    var c_forge = b.col("conda_forge")
    for ref r in rows:
        b.add_str(c_name, r.name)
        b.add_int(c_fetched, r.fetched_at)
        b.add_str(c_state, r.state)
        if r.settled():
            b.add_bool(c_forge, r.conda_forge)
        else:
            b.add_null(c_forge)
    return b^.build()
