"""The Live page (#123): commits to census repos minutes after the push,
from mojo.live_commits (pipeline mojo_live), with how fresh they are.

The table is read by a refresher of its own every `LIVE_REFRESH_SECS`, apart
from the rest of the lake's half-hourly look, and only the last
`LIVE_WINDOW_SECS` of it. So "published" here is the poller seeing a commit
plus at most a minute.
"""

from std.time import sleep

from flare.http import Handler, Request, Response, ok_json
from morca.civil import now

from cols import col, i64_at, str_at
from committype import commit_type, commit_type_title
from console_layout import _empty, _page
from console_pages import page_json, page_line
from jscan import micros_to_iso
from lake import try_load
from live import LiveCommit, freshness
from swap import Swap
from threads import OpaquePtr

comptime LIVE_REFRESH_SECS = 60
comptime LIVE_WINDOW_SECS = 2 * 86_400
comptime LIVE_SHOWN = 100


struct LiveData(Movable):
    var commits: List[LiveCommit]
    """The window's commits, newest seen first, each once."""
    var snapshot: Int64
    """The table's snapshot they were read at; -1 for no table yet."""
    var read_at: Int64
    """Seconds since the epoch."""

    def __init__(out self):
        self.commits = List[LiveCommit]()
        self.snapshot = -1
        self.read_at = 0


def live_snapshot() raises -> Int64:
    var t = try_load("mojo", "live_commits")
    if not t or not t.value().metadata.has_current_snapshot:
        return -1
    return t.value().metadata.current_snapshot_id


def read_live(t_now: Int64) raises -> LiveData:
    """The last `LIVE_WINDOW_SECS` of mojo.live_commits."""
    var out = LiveData()
    out.read_at = t_now
    var t = try_load("mojo", "live_commits")
    if not t or not t.value().metadata.has_current_snapshot:
        return out^
    out.snapshot = t.value().metadata.current_snapshot_id
    var since = micros_to_iso((t_now - LIVE_WINDOW_SECS) * 1_000_000)
    var seen = Dict[String, Bool]()
    var rows = List[LiveCommit]()
    for b in t.value().scan().filter(String('[">=","seen_at","', since, '"]')).to_batches():
        var c_repo = col(b, "repo")
        var c_sha = col(b, "sha")
        var c_subj = col(b, "subject")
        var c_at = col(b, "committed_at")
        var c_seen = col(b, "seen_at")
        for r in range(b.num_rows):
            var sha = str_at(b.column(c_sha), r)
            if sha in seen:
                continue  # a poll that committed twice
            seen[sha] = True
            rows.append(LiveCommit(
                str_at(b.column(c_repo), r), sha^, str_at(b.column(c_subj), r),
                i64_at(b.column(c_at), r), i64_at(b.column(c_seen), r),
            ))
    # Newest seen first; within a poll, newest committed first.
    # Insertion sort: the rows mostly arrive in order already (polls append
    # oldest first), so this is close to one pass.
    rows.reverse()
    for i in range(1, len(rows)):
        var j = i
        while j > 0 and _newer(rows[j], rows[j - 1]):
            rows.swap_elements(j - 1, j)
            j -= 1
    out.commits = rows^
    return out^


def _newer(a: LiveCommit, b: LiveCommit) -> Bool:
    if a.seen_at != b.seen_at:
        return a.seen_at > b.seen_at
    return a.committed_at > b.committed_at


def live_refresher(arg: OpaquePtr) -> OpaquePtr:
    """Reads mojo.live_commits again whenever its snapshot moved, every
    `LIVE_REFRESH_SECS`; `arg` is the address of a `Swap[LiveData]`."""
    ref sw = Pointer[Swap[LiveData], MutUntrackedOrigin](unsafe_from_address=Int(arg))[]
    while True:
        try:
            var cur = sw.get()
            var t = now()
            var snap = live_snapshot()
            if snap != cur[].snapshot or t - cur[].read_at > LIVE_WINDOW_SECS // 8:
                sw.put(read_live(t))
        except e:
            print("console: live:", e)
        sleep(Float64(LIVE_REFRESH_SECS))


def _ago(secs: Int64) -> String:
    if secs < 60:
        return String(secs, " s")
    if secs < 3600:
        return String(secs // 60, " min")
    if secs < 86_400:
        return String(secs // 3600, " h ", (secs % 3600) // 60, " min")
    return String(secs // 86_400, " d")


def _lag(c: LiveCommit) -> String:
    var s = (c.seen_at - c.committed_at) // 1_000_000
    return _ago(s) if s >= 0 else String("&ndash;")


def _esc(s: String) -> String:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&#39;")


def live_page(d: LiveData) raises -> Response:
    var t = now()
    var h = String("<h1>Live</h1>")
    if d.snapshot < 0:
        h.write(_empty(
            "No live commits yet",
            "The poller (mojo_live) hasn't recorded any commits yet; it looks at every census repo every 20 minutes.",
        ))
        return _page("Live", h^, "live", description=page_line("/live"), alternate=page_json("/live"))
    var day_f = freshness(d.commits, (t - 86_400) * 1_000_000)
    var repos = Dict[String, Bool]()
    for ref c in d.commits:
        if c.seen_at >= (t - 86_400) * 1_000_000:
            repos[c.repo] = True
    h.write(
        "<p class=sub>Commits to census repos' default branches, within about 20 minutes of the push.",
        " The poller looks at every repo every 20 minutes; this page reads what it found every minute.</p>",
        "<div class=kpis>",
        "<div class=kpi><span>", day_f.n, "</span><small>commits in the last 24 h, to ", len(repos), " repos</small></div>",
        "<div class=kpi><span>", _ago(Int64(day_f.median_s)) if day_f.n > 0 else String("&ndash;"),
        "</span><small title='From the commit&#39;s time to the poller seeing it, over the last 24 h; add up to a minute for this page'>median commit to seen</small></div>",
        "<div class=kpi><span>", _ago(Int64(day_f.p90_s)) if day_f.n > 0 else String("&ndash;"),
        "</span><small>90th percentile</small></div></div>",
    )
    if len(d.commits) == 0:
        h.write(_empty("Quiet", "No commits seen in the last two days."))
        return _page("Live", h^, "live", description=page_line("/live"), alternate=page_json("/live"))
    h.write(
        "<div class=tbl><table><thead><tr><th>Seen</th><th>Repo</th><th>Type</th>",
        "<th>Subject</th><th>Commit</th><th class=num title='Commit time to seen'>Lag</th></tr></thead><tbody>",
    )
    for i in range(min(LIVE_SHOWN, len(d.commits))):
        ref c = d.commits[i]
        var repo = _esc(c.repo)
        h.write(
            "<tr><td title='", micros_to_iso(c.seen_at), "'>", _ago(t - c.seen_at // 1_000_000), " ago</td>",
            "<td><a href='/repos/", repo, "'>", repo, "</a></td><td>",
            commit_type_title(commit_type(c.subject, False)), "</td><td>", _esc(c.subject),
            "</td><td><a class=mono href='https://github.com/", repo, "/commit/", _esc(c.sha),
            "' rel=noopener>", _esc(String(c.sha[byte = : min(10, c.sha.byte_length())])), "</a></td><td class=num>", _lag(c), "</td></tr>",
        )
    h.write("</tbody></table></div>")
    if len(d.commits) > LIVE_SHOWN:
        h.write("<p class=mute>The latest ", LIVE_SHOWN, " of ", len(d.commits), " in two days; all of them are in <a href='/api/live'>the JSON</a>.</p>")
    var resp = _page("Live", h^, "live", description=page_line("/live"), alternate=page_json("/live"))
    resp.headers.set("Cache-Control", "public, max-age=30")
    return resp^


def _q(s: String) -> String:
    var out = String('"')
    for cp in s.codepoint_slices():
        if cp == '"':
            out += '\\"'
        elif cp == "\\":
            out += "\\\\"
        elif cp == "\n":
            out += "\\n"
        elif cp == "\t":
            out += "\\t"
        else:
            out += cp
    out += '"'
    return out^


def live_json(d: LiveData) raises -> Response:
    var t = now()
    var f = freshness(d.commits, (t - 86_400) * 1_000_000)
    var out = String(
        '{"read_at":', _q(micros_to_iso(d.read_at * 1_000_000)), ',"snapshot":', d.snapshot,
        ',"last_day":{"commits":', f.n, ',"median_lag_s":', f.median_s, ',"p90_lag_s":', f.p90_s,
        '},"commits":[',
    )
    for i in range(len(d.commits)):
        ref c = d.commits[i]
        if i > 0:
            out += ","
        out.write(
            '{"repo":', _q(c.repo), ',"sha":', _q(c.sha), ',"subject":', _q(c.subject),
            ',"type":', _q(commit_type(c.subject, False)),
            ',"committed_at":', _q(micros_to_iso(c.committed_at)),
            ',"seen_at":', _q(micros_to_iso(c.seen_at)), "}",
        )
    out += "]}"
    var resp = ok_json(out)
    resp.headers.set("Cache-Control", "public, max-age=30")
    return resp^


@fieldwise_init
struct LiveSite(Handler, Copyable):
    """`/live` (or `/api/live` with `json`), from the `Swap[LiveData]` at
    `swap`, which lives as long as the process."""

    var swap: Int
    var json: Bool

    def serve(self, req: Request) raises -> Response:
        ref sw = Pointer[Swap[LiveData], MutUntrackedOrigin](unsafe_from_address=self.swap)[]
        var held = sw.get()
        if self.json:
            return live_json(held[])
        return live_page(held[])
