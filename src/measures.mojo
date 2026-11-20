"""The census's numbers about itself, for How it works' "By the numbers"
(#124): what the pipelines measured of their own runs (mojo.measures), how
long a GH Archive day takes to reach the site (from snapshot metadata the
console reads anyway), and the console's memory and image size.

Each number keeps where it came from: a measurement its pipeline and run,
the freshness the run whose commit made the day visible."""

from std.os import getenv

from morca.tables import BatchBuilder, Table
from parquet import RecordBatch

from cols import col, f64_at, i64_at, str_at
from days import days_of
from lake import measures_schema, try_load

comptime EMBED_RATE = "embed_texts_per_s"
"""mojo_embed: texts encoded a second, the model loaded."""
comptime EMBED_LOAD = "embed_model_load_s"
"""mojo_embed: seconds to load the model (`Encoder(dir)`)."""


@fieldwise_init
struct Measure(Copyable, Movable):
    """A row of mojo.measures."""

    var pipeline: String
    var run: Int
    """morca's run number; 0 for a run outside morca."""
    var name: String
    var value: Float64
    var unit: String
    var at: Int64
    """Microseconds since the epoch."""


def measures_batch(rows: List[Measure]) raises -> RecordBatch:
    var b = BatchBuilder(measures_schema())
    var cs = b.roots.copy()
    for ref r in rows:
        b.add_str(cs[0], r.pipeline)
        b.add_int(cs[1], Int64(r.run))
        b.add_str(cs[2], r.name)
        b.add_float(cs[3], r.value)
        b.add_str(cs[4], r.unit)
        b.add_int(cs[5], r.at)
    return b^.build()


def measure_rows(b: RecordBatch) raises -> List[Measure]:
    var out = List[Measure]()
    var c_pipe = col(b, "pipeline")
    var c_run = col(b, "run")
    var c_name = col(b, "name")
    var c_value = col(b, "value")
    var c_unit = col(b, "unit")
    var c_at = col(b, "at")
    for r in range(b.num_rows):
        out.append(Measure(
            str_at(b.column(c_pipe), r), Int(i64_at(b.column(c_run), r)),
            str_at(b.column(c_name), r), f64_at(b.column(c_value), r),
            str_at(b.column(c_unit), r), i64_at(b.column(c_at), r),
        ))
    return out^


def measure_key(pipeline: String, name: String) -> String:
    return String(pipeline, "/", name)


def latest_of(rows: List[Measure]) -> Dict[String, Measure]:
    """The newest row (by `at`) of each pipeline and name, keyed
    `measure_key`."""
    var out = Dict[String, Measure]()
    for ref r in rows:
        var k = measure_key(r.pipeline, r.name)
        var prev = out.get(k)
        if not prev or prev.value().at <= r.at:
            out[k] = r.copy()
    return out^


def latest_measures() raises -> Dict[String, Measure]:
    """`latest_of` mojo.measures; empty when it doesn't exist yet."""
    var t = try_load("mojo", "measures")
    if not t or not t.value().metadata.has_current_snapshot:
        return Dict[String, Measure]()
    var rows = List[Measure]()
    for b in t.value().scan().to_batches():
        for ref r in measure_rows(b):
            rows.append(r.copy())
    return latest_of(rows)


@fieldwise_init
struct Published(Copyable, Movable):
    """When the newest GH Archive day loaded reached the site."""

    var day: String
    """`YYYY-MM-DD`; "" when no day is loaded or its commit is expired."""
    var lag_s: Int64
    """From the end of the day's last hour (00:00 UTC the next day) to the
    commit that made it visible."""
    var pipeline: String
    """The pipeline and run of that commit (`orca.pipeline`, `orca.run`);
    run 0 when the snapshot doesn't name one."""
    var run: Int

    @staticmethod
    def none() -> Published:
        return Published(String(), 0, String(), 0)


def _names_day(summary: Dict[String, String], day: String) -> Bool:
    for key in summary.get("orca.partitions", String("")).split(","):
        if key.strip() == day:
            return True
    return False


def first_commit(t: Table, day: String) -> Optional[Int]:
    """The index in `t.metadata.snapshots` of the oldest snapshot whose
    `orca.partitions` names `day`, if one is left."""
    var best = -1
    for i in range(len(t.metadata.snapshots)):
        ref s = t.metadata.snapshots[i]
        if _names_day(s.summary, day) and (
            best < 0 or s.timestamp_ms < t.metadata.snapshots[best].timestamp_ms
        ):
            best = i
    if best < 0:
        return None
    return best


def archive_published(
    day: String, repo_hour: Optional[Table], activity: Optional[Table]
) raises -> Published:
    """How long `day` (the newest loaded, `Sources.last_day`) took to reach
    the site. The overview counts it once gharchive.repo_hour has a commit
    for it, and its repos' counts show once mojo.activity has one (the
    rebuild that a mojo.* snapshot starts): the later of the two first
    commits naming the day. mojo.activity is left out when none of its
    snapshots names the day (not run yet, or expired)."""
    if day.byte_length() == 0 or not repo_hour:
        return Published.none()
    var end_ms = (days_of(day) + 1) * 86_400_000
    ref rh = repo_hour.value()
    var i = first_commit(rh, day)
    if not i:
        return Published.none()
    ref snap = rh.metadata.snapshots[i.value()]
    var ms = snap.timestamp_ms
    var summary = snap.summary.copy()
    if activity:
        ref act = activity.value()
        var j = first_commit(act, day)
        if j and act.metadata.snapshots[j.value()].timestamp_ms > ms:
            ms = act.metadata.snapshots[j.value()].timestamp_ms
            summary = act.metadata.snapshots[j.value()].summary.copy()
    var run = 0
    try:
        run = Int(summary.get("orca.run", String("0")))
    except:
        pass
    return Published(day, (ms - end_ms) // 1000, summary.get("orca.pipeline", String()), run)


def vmrss_bytes(status: String) -> Int64:
    """`VmRSS` of a `/proc/<pid>/status` text (`VmRSS:  1234 kB`), in
    bytes; -1 without one."""
    var k = status.find("VmRSS:")
    if k < 0:
        return -1
    var b = status.as_bytes()
    var i = k + 6
    while i < len(b) and (b[i] == UInt8(ord(" ")) or b[i] == UInt8(ord("\t"))):
        i += 1
    var n = Int64(0)
    var digits = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        n = n * 10 + Int64(b[i] - UInt8(ord("0")))
        digits += 1
        i += 1
    if digits == 0:
        return -1
    return n * 1024  # the kernel gives it in kB


def console_rss_bytes() -> Int64:
    """This process's resident memory, from /proc/self/status (Linux); -1
    where there is none (macOS)."""
    try:
        with open("/proc/self/status", "r") as f:
            return vmrss_bytes(f.read())
    except:
        return -1


def image_bytes() -> Int64:
    """`MORCA_IMAGE_BYTES`, the size of the image this container runs, which
    morca sets at deploy; -1 when it is unset or not a number."""
    var v = getenv("MORCA_IMAGE_BYTES")
    if v.byte_length() == 0:
        return -1
    try:
        var n = Int(String(v.strip()))
        return Int64(n) if n > 0 else -1
    except:
        return -1
