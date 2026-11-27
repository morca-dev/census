"""`POST /mcp`: an MCP server over the console's data, for agents writing
Mojo (#229). Remote and without auth; its tools only read, except
`get_more_tools`, which records a report for us.

The transport is MCP's Streamable HTTP, stateless: one JSON-RPC 2.0 message
in the POST body, one `application/json` answer, no SSE and no session id.
It handles `initialize`, `ping`, `tools/list`, `tools/call` and the
notifications (answered 202 with no body); any other method is JSON-RPC's
"method not found". `GET /mcp` gets the router's 405.

The tools read the same `Cache` as the pages and `/api/` (`search_repos`
the search's matches, `list_repos` the Repos table's selection, `get_repo`
and `similar_repos` a repo's page, `version_adoption` and `overview` the
overview's numbers), so they add no query and their numbers match the
pages'. Each answer is trimmed to what an agent needs and has `as_of` and
the `url` of the page on mojourney.dev.

The seventh tool, last in tools/list, is `get_more_tools`, PostHog's
"missing capability" tool as its SDKs add it (posthog-js
`packages/mcp/src/extensions/tools.ts`, the same name, description, schema,
annotations and answer): an agent that finds no tool for what its user
asked calls it with a `context` saying what it wanted. It reads nothing from
the census and returns no tools: the report becomes a
`$mcp_missing_capability` event (`mcp_events`), the rows of MCP Analytics'
"Missing capabilities" page, and the agent gets the SDK's acknowledgement.
Without `POSTHOG_KEY` it answers the same and nothing is sent. It counts
towards the tools/call limit like the others.

Limits: the body is at most `MAX_BODY` bytes, a bad message gets a JSON-RPC
error (never a 500), and each client (by `CF-Connecting-IP`) may make
`MCP_CALLS_PER_MINUTE` tools/calls a minute (default 60), then gets 429.
`initialize`, `tools/list`, each call to a tool and each `get_more_tools`
report are events in PostHog, in its MCP Analytics schema (`mcp_events`).
"""

from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.time import perf_counter_ns

from flare.http import Handler, Request, Response
from morca.civil import now
from threads import Mutex

from categories import category_keys, is_category
from jscan import Range, field, micros_to_iso, raw, skip_ws, text
from listing import ListQuery, _merge_sort, list_url, select_repos
from querymodel import QueryModel
from search import url_encode, version_family
from similar import Neighbor
from swap import Swap

from console_cache import Cache
from console_layout import SITE_URL, census_version
from console_list import _matches, meaning_hits
from mcp_events import (
    ClientIds, EventQueue, HEADER_MAX, INTENT_MAX, MISSING_CAPABILITY, McpEvent, client_of_agent, cut, event_json, js,
    session_id, trim_arguments,
)


comptime MAX_BODY = 64 * 1024
comptime CALLS_PER_MINUTE = 60
"""tools/calls a client may make a minute, unless `MCP_CALLS_PER_MINUTE`
says otherwise."""
comptime DEFAULT_PROTOCOL = "2025-06-18"
comptime LIMIT_DEFAULT = 10
comptime LIMIT_MAX = 50

comptime PARSE_ERROR = -32700
comptime INVALID_REQUEST = -32600
comptime METHOD_NOT_FOUND = -32601
comptime INVALID_PARAMS = -32602
comptime INTERNAL_ERROR = -32603
comptime RATE_LIMITED = -32000


def supported_protocols() -> List[String]:
    return ["2025-11-25", "2025-06-18", "2025-03-26"]


def calls_per_minute() -> Int:
    """`MCP_CALLS_PER_MINUTE`, else `CALLS_PER_MINUTE`."""
    var v = getenv("MCP_CALLS_PER_MINUTE")
    if v.byte_length() > 0:
        try:
            var n = Int(v)
            if n > 0:
                return n
        except:
            pass
    return CALLS_PER_MINUTE


struct McpState(Movable):
    """What every copy of the `/mcp` handler shares, at one address for the
    life of the process: the tools/call counts of this minute per client,
    the daily-salted client ids and the PostHog event queue."""

    var _lock: Mutex
    var _minute: Int64
    var _calls: Dict[String, Int]
    var calls_per_minute: Int
    var ids: ClientIds
    var events: EventQueue

    def __init__(out self, posthog_key: String, per_minute: Int = -1) raises:
        """`per_minute` -1 is `calls_per_minute()`."""
        self._lock = Mutex()
        self._minute = -1
        self._calls = Dict[String, Int]()
        self.calls_per_minute = per_minute if per_minute >= 0 else calls_per_minute()
        self.ids = ClientIds()
        self.events = EventQueue(posthog_key)

    def admit_call(mut self, client: String, minute: Int64) -> Bool:
        """Whether `client` may make another tools/call in `minute`; counts it
        if so. The counts start again each minute."""
        self._lock.lock()
        if minute != self._minute:
            self._minute = minute
            self._calls = Dict[String, Int]()
        var n = self._calls.get(client, 0)
        var ok = n < self.calls_per_minute
        if ok:
            self._calls[client] = n + 1
        self._lock.unlock()
        return ok


def new_mcp_state(posthog_key: String) raises -> Int:
    """A `McpState` that lives as long as the process; its address."""
    var p = unsafe_alloc[McpState](1)
    p.unsafe_write(McpState(posthog_key))
    return Int(p)


# ── JSON ────────────────────────────────────────────────────────────────


def _hexdigit(c: UInt8) -> Bool:
    return (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x46) or (c >= 0x61 and c <= 0x66)


def _digits(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    while i < end and b[i] >= 0x30 and b[i] <= 0x39:
        i += 1
    return i


def _valid_string(b: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """`i` at a `"`: the index after the string, or -1 if it isn't one."""
    i += 1
    while i < end:
        var c = b[i]
        if c == UInt8(ord('"')):
            return i + 1
        if c < 0x20:
            return -1
        if c == UInt8(ord("\\")):
            if i + 1 >= end:
                return -1
            var e = b[i + 1]
            if e == UInt8(ord("u")):
                if i + 6 > end:
                    return -1
                for k in range(2, 6):
                    if not _hexdigit(b[i + k]):
                        return -1
                i += 6
                continue
            if (
                e != UInt8(ord('"')) and e != UInt8(ord("\\")) and e != UInt8(ord("/")) and e != UInt8(ord("b"))
                and e != UInt8(ord("f")) and e != UInt8(ord("n")) and e != UInt8(ord("r")) and e != UInt8(ord("t"))
            ):
                return -1
            i += 2
            continue
        i += 1
    return -1


def _literal(b: Span[UInt8, _], i: Int, end: Int, word: StaticString) -> Int:
    var w = word.as_bytes()
    if i + len(w) > end:
        return -1
    for k in range(len(w)):
        if b[i + k] != w[k]:
            return -1
    return i + len(w)


def valid_json(b: Span[UInt8, _], start: Int, end: Int, depth: Int = 0) -> Int:
    """The index after the one JSON value at `start` (after any space), or
    -1 if the bytes aren't a valid value; at most 64 levels deep."""
    if depth > 64:
        return -1
    var i = skip_ws(b, start, end)
    if i >= end:
        return -1
    var c = b[i]
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        var obj = c == UInt8(ord("{"))
        var close = UInt8(ord("}")) if obj else UInt8(ord("]"))
        i = skip_ws(b, i + 1, end)
        if i < end and b[i] == close:
            return i + 1
        while i < end:
            if obj:
                if b[i] != UInt8(ord('"')):
                    return -1
                i = _valid_string(b, i, end)
                if i < 0:
                    return -1
                i = skip_ws(b, i, end)
                if i >= end or b[i] != UInt8(ord(":")):
                    return -1
                i += 1
            i = valid_json(b, i, end, depth + 1)
            if i < 0:
                return -1
            i = skip_ws(b, i, end)
            if i >= end:
                return -1
            if b[i] == close:
                return i + 1
            if b[i] != UInt8(ord(",")):
                return -1
            i = skip_ws(b, i + 1, end)
        return -1
    if c == UInt8(ord('"')):
        return _valid_string(b, i, end)
    if c == UInt8(ord("t")):
        return _literal(b, i, end, "true")
    if c == UInt8(ord("f")):
        return _literal(b, i, end, "false")
    if c == UInt8(ord("n")):
        return _literal(b, i, end, "null")
    # A number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    if c == UInt8(ord("-")):
        i += 1
    if i >= end or b[i] < 0x30 or b[i] > 0x39:
        return -1
    i = i + 1 if b[i] == 0x30 else _digits(b, i, end)
    if i < end and b[i] == UInt8(ord(".")):
        var d = _digits(b, i + 1, end)
        if d == i + 1:
            return -1
        i = d
    if i < end and (b[i] == UInt8(ord("e")) or b[i] == UInt8(ord("E"))):
        i += 1
        if i < end and (b[i] == UInt8(ord("+")) or b[i] == UInt8(ord("-"))):
            i += 1
        var d = _digits(b, i, end)
        if d == i:
            return -1
        i = d
    return i


def _first(b: Span[UInt8, _], r: Range) -> UInt8:
    """The first byte of the value at `r`, or 0."""
    if not r.found() or r.end <= r.start:
        return 0
    return b[r.start]


def _is_string(b: Span[UInt8, _], r: Range) -> Bool:
    return _first(b, r) == UInt8(ord('"'))


def _is_object(b: Span[UInt8, _], r: Range) -> Bool:
    return _first(b, r) == UInt8(ord("{"))


def _is_null(b: Span[UInt8, _], r: Range) -> Bool:
    return _first(b, r) == UInt8(ord("n"))


# ── Tool arguments ──────────────────────────────────────────────────────


def _str_arg(b: Span[UInt8, _], args: Range, key: StaticString, required: Bool = False) raises -> String:
    var r = field(b, args, key) if args.found() else Range(-1, -1)
    if not r.found() or _is_null(b, r):
        if required:
            raise Error("Missing argument `", key, "`.")
        return String()
    if not _is_string(b, r):
        raise Error("`", key, "` must be a string.")
    var v = String(text(b, r).strip())
    if required and v.byte_length() == 0:
        raise Error("Missing argument `", key, "`.")
    return v^


def _int_arg(b: Span[UInt8, _], args: Range, key: StaticString, default: Int, most: Int) raises -> Int:
    var r = field(b, args, key) if args.found() else Range(-1, -1)
    if not r.found() or _is_null(b, r):
        return default
    var bad = String("`", key, "` must be an integer from 1 to ", most, ".")
    var c = _first(b, r)
    if not (c == UInt8(ord("-")) or (c >= 0x30 and c <= 0x39)):
        raise Error(bad)
    var n: Int
    try:
        n = Int(raw(b, r))
    except:
        raise Error(bad)
    if n < 1 or n > most:
        raise Error(bad)
    return n


def _bool_arg(b: Span[UInt8, _], args: Range, key: StaticString) raises -> Bool:
    var r = field(b, args, key) if args.found() else Range(-1, -1)
    if not r.found() or _is_null(b, r):
        return False
    var v = raw(b, r)
    if v == "true":
        return True
    if v == "false":
        return False
    raise Error("`", key, "` must be true or false.")


def _category_arg(b: Span[UInt8, _], args: Range) raises -> String:
    var cat = _str_arg(b, args, "category")
    if cat.byte_length() > 0 and not is_category(cat):
        var keys = String()
        for k in category_keys():
            keys.write(", " if keys.byte_length() > 0 else "", k)
        raise Error("Unknown category `", cat, "`; the categories are ", keys, ".")
    return cat^


# ── Tools ───────────────────────────────────────────────────────────────


comptime MORE_TOOLS = "get_more_tools"
"""PostHog's tool for reporting a missing capability (`GET_MORE_TOOLS_NAME`)."""
comptime MORE_TOOLS_DESCRIPTION = (
    "Report that the user's request needs a capability this server does not have. Records the report for the"
    " server's developers; it does not return or add tools."
)
comptime MORE_TOOLS_REPLY = (
    "Unfortunately, we have shown you the full tool list. We have noted your feedback and will work to improve the"
    " tool list in the future."
)
"""What `get_more_tools` answers (the SDK's `getMoreToolsResult`)."""


comptime DATA_NOTE = (
    " The data: public GitHub repos that contain Mojo code, found in GH Archive"
    " and read with the GitHub API and their git history, updated daily"
    " (each answer's `as_of` says how fresh). `url` is the page on mojourney.dev."
)


def tools_json() -> String:
    """tools/list's `tools`."""
    comptime VERSION_PROP = (
        '"version":{"type":"string","description":"Only repos on this Mojo version: a bucket'
        ' such as 1.3, 1.2 or pre-1.0, or a family such as 1.x or 0.26.x."}'
    )
    var cats = String()
    for k in category_keys():
        cats.write("," if cats.byte_length() > 0 else "", js(k))
    var category_prop = String(
        '"category":{"type":"string","enum":[', cats, '],"description":"Only repos in this category (approximate)."}'
    )
    var limit_prop = String(
        '"limit":{"type":"integer","minimum":1,"maximum":', LIMIT_MAX, ',"default":', LIMIT_DEFAULT,
        ',"description":"How many repos to return."}',
    )
    comptime REPO_PROP = '"repo":{"type":"string","description":"The repo as owner/name, e.g. modular/modular."}'
    return String(
        "[",
        '{"name":"search_repos","title":"Search Mojo repos","description":',
        js(
            String(
                "Find Mojo libraries and projects by keywords (name, GitHub topics, description) and by"
                " meaning: e.g. parquet, HTTP server, SQLite bindings, audio processing. Text matches come"
                " first, then repos related by meaning. Each result has its stars, Mojo version, last"
                " commit and tooling, to judge whether it's maintained.",
                DATA_NOTE,
            )
        ),
        ',"inputSchema":{"type":"object","properties":{',
        '"query":{"type":"string","description":"Keywords or a description of what you need."},',
        VERSION_PROP, ",", category_prop, ",", limit_prop, '},"required":["query"]}},',
        '{"name":"list_repos","title":"List Mojo repos","description":',
        js(
            String(
                "List Mojo repos ranked by stars, by commits in the last 30 days (commits), by their last"
                " commit (recent), or by rising (stars, forks and dependents gained in 30 days; the top 10"
                " only), optionally only one Mojo version, one category or the ones active in the last year.",
                DATA_NOTE,
            )
        ),
        ',"inputSchema":{"type":"object","properties":{',
        '"sort":{"type":"string","enum":["stars","commits","recent","rising"],"default":"stars"},',
        VERSION_PROP, ",", category_prop,
        ',"active":{"type":"boolean","description":"Only repos with a commit in the last 12 months."},',
        limit_prop, "}}},",
        '{"name":"get_repo","title":"One Mojo repo","description":',
        js(
            String(
                "One repo: description, license, stars, last commit, Mojo version (and where it was read, or"
                " an estimate by date), tooling and packaging, dependencies, the last 10 releases, its"
                " migrations between Mojo versions and its 20 most recent commits.",
                DATA_NOTE,
            )
        ),
        ',"inputSchema":{"type":"object","properties":{', REPO_PROP, '},"required":["repo"]}},',
        '{"name":"similar_repos","title":"Similar Mojo repos","description":',
        js(
            String(
                "The repos most like one repo, by the embeddings of their names, descriptions and topics,"
                " with a similarity score from 0 to 1.",
                DATA_NOTE,
            )
        ),
        ',"inputSchema":{"type":"object","properties":{', REPO_PROP, ",", limit_prop, '},"required":["repo"]}},',
        '{"name":"version_adoption","title":"Mojo version adoption","description":',
        js(
            String(
                "How far each Mojo version has spread: how many repos are on each version now (and how many"
                " of them are active), and how many moved to each version month by month; the last 12"
                " months, or every month of one family.",
                DATA_NOTE,
            )
        ),
        ',"inputSchema":{"type":"object","properties":{',
        '"family":{"type":"string","description":"One family of versions, e.g. 1.x, 0.26.x or 25.x."}}}},',
        '{"name":"overview","title":"Mojo ecosystem overview","description":',
        js(
            String(
                "The Mojo ecosystem in numbers: repos, commits and lines of Mojo now and 30 days ago, repos"
                " per Mojo version, and the rising, most active and most depended-on repos.",
                DATA_NOTE,
            )
        ),
        ',"inputSchema":{"type":"object","properties":{}}},',
        '{"name":', js(MORE_TOOLS), ',"description":', js(MORE_TOOLS_DESCRIPTION),
        ',"inputSchema":{"type":"object","properties":{"context":{"type":"string","description":',
        '"A description of your goal and what kind of tool would help accomplish it."}},"required":["context"]}',
        ',"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}}',
        "]",
    )


def tool_names() -> List[String]:
    """The tools over the census; tools/list also has `MORE_TOOLS`."""
    return ["search_repos", "list_repos", "get_repo", "similar_repos", "version_adoption", "overview"]


def listed_tool_names() -> List[String]:
    """tools/list's tools, in order: `tool_names` and `MORE_TOOLS`."""
    var out = tool_names()
    out.append(MORE_TOOLS)
    return out^


@fieldwise_init
struct ToolOut(Movable):
    var json: String
    var results: Int
    """How many items it returns (repos, months), for the event."""


def _as_of(c: Cache) -> String:
    return js(micros_to_iso(c.sources.as_of_ms * 1000))


def _iso_or_null(us: Int64) -> String:
    return js(micros_to_iso(us)) if us > 0 else String("null")


def _strs(items: List[String]) -> String:
    var out = String("[")
    for i in range(len(items)):
        out.write("," if i > 0 else "", js(items[i]))
    out += "]"
    return out^


def _repo_url(repo: String) -> String:
    return String(SITE_URL, "/repos/", repo)


def repo_brief(c: Cache, i: Int) -> String:
    """One repo as the lists give it (no closing brace, so a caller can add
    fields): name, page, description, stars, Mojo version and how active."""
    ref l = c.libs[i]
    return String(
        '{"repo":', js(l.repo), ',"url":', js(_repo_url(l.repo)), ',"description":', js(cut(l.description, 300)),
        ',"topics":', _strs(l.topics), ',"stars":', l.stars, ',"forks":', l.forks, ',"license":', js(l.license),
        ',"mojo_version":', js(l.mojo_version), ',"version_estimate":', js(l.version_estimate),
        ',"mojo_lines":', l.mojo_lines, ',"last_commit":', _iso_or_null(l.last_commit),
        ',"commits_30d":', c.commits30[i] if i < len(c.commits30) else 0,
        ',"tooling":', js(l.tooling), ',"used_by":', len(l.used_by),
        ',"category":', js(c.categories[i]) if i < len(c.categories) and c.categories[i].byte_length() > 0 else "null",
        ',"archived":', "true" if l.archived else "false",
    )


def _passes(c: Cache, i: Int, version: String, category: String, active: Bool) -> Bool:
    """Whether repo `i` passes the filters, as the Repos table applies them."""
    if version.byte_length() > 0 and c.buckets[i] != version and c.families[i] != version:
        return False
    if category.byte_length() > 0 and (i >= len(c.categories) or c.categories[i] != category):
        return False
    if active and not c.active[i]:
        return False
    return True


def search_repos(c: Cache, b: Span[UInt8, _], args: Range, qv: List[Float32]) raises -> ToolOut:
    var q = _str_arg(b, args, "query", required=True)
    var version = _str_arg(b, args, "version")
    var category = _category_arg(b, args)
    var limit = _int_arg(b, args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
    var hits = _matches(q, c)
    var out = String(
        '{"as_of":', _as_of(c), ',"url":', js(String(SITE_URL, "/search?q=", url_encode(q))),
        ',"query":', js(cut(q, 200)), ',"by_meaning":', "true" if len(qv) > 0 else "false", ',"results":[',
    )
    var n = 0
    for i in hits:
        if n >= limit:
            break
        if _passes(c, i, version, category, False):
            out.write("," if n > 0 else "", repo_brief(c, i), ',"match":"text"}')
            n += 1
    if n < limit:
        for ref r in meaning_hits(c, qv, hits):
            if n >= limit:
                break
            if _passes(c, r.index, version, category, False):
                out.write("," if n > 0 else "", repo_brief(c, r.index), ',"match":"meaning","score":', r.score, "}")
                n += 1
    out += "]}"
    return ToolOut(out^, n)


def _index_of(c: Cache, repo: String) -> Int:
    """`repo`'s index in `c.libs`, or -1."""
    for i in range(len(c.libs)):
        if c.libs[i].repo == repo:
            return i
    return -1


def _has_family(c: Cache, family: String) -> Bool:
    """Whether a migration went to a version of `family`."""
    for ref r in c.version_rows:
        if version_family(r.version) == family:
            return True
    return False


def list_repos(c: Cache, b: Span[UInt8, _], args: Range) raises -> ToolOut:
    var sort = _str_arg(b, args, "sort")
    if sort.byte_length() == 0:
        sort = "stars"
    var version = _str_arg(b, args, "version")
    var category = _category_arg(b, args)
    var active = _bool_arg(b, args, "active")
    var limit = _int_arg(b, args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
    var idx = List[Int]()
    var url = String(SITE_URL, "/repos")
    if sort == "rising":
        url = String(SITE_URL, "/")
        for ref name in c.rising:
            var i = _index_of(c, name)
            if i >= 0 and _passes(c, i, version, category, active):
                idx.append(i)
    elif sort == "stars" or sort == "commits" or sort == "recent":
        var q = ListQuery(
            "stars" if sort == "stars" else ("commits30" if sort == "commits" else "lines"), False, version, active,
            String(), False, category,
        )
        idx = select_repos(
            q, c.lines, c.files, c.stars, c.buckets, c.active, c.families, c.news, c.commits30, c.forks,
            c.used_by, c.categories,
        )
        if sort == "recent":
            var last = List[Int64]()
            for ref l in c.libs:
                last.append(l.last_commit)
            idx = _merge_sort(idx^, last, False)
        else:
            url = String(SITE_URL, list_url(q))
    else:
        raise Error("`sort` must be stars, commits, recent or rising.")
    var out = String(
        '{"as_of":', _as_of(c), ',"url":', js(url), ',"sort":', js(sort), ',"total":', len(idx), ',"results":[',
    )
    var n = min(limit, len(idx))
    for k in range(n):
        out.write("," if k > 0 else "", repo_brief(c, idx[k]), "}")
    out += "]}"
    return ToolOut(out^, n)


def _resolve(c: Cache, repo: String) raises -> Tuple[Int, String]:
    """The index of `repo` in `c.libs` (by its name, any case, or an old
    name), and the name asked for when it was an old one, else ""."""
    var lower = repo.lower()
    for i in range(len(c.libs)):
        if c.libs[i].repo == repo:
            return (i, String())
    for i in range(len(c.libs)):
        if c.libs[i].repo.lower() == lower:
            return (i, String())
    var moved = c.moved_to(repo)
    if moved.byte_length() > 0:
        for i in range(len(c.libs)):
            if c.libs[i].repo == moved:
                return (i, repo)
    raise Error(
        "No repo `", repo, "` in the census (", len(c.libs), " repos); search_repos finds repos by name or topic."
    )


def _repo_arg(b: Span[UInt8, _], args: Range) raises -> String:
    var repo = _str_arg(b, args, "repo", required=True)
    if "/" not in repo:
        raise Error("`repo` must be owner/name, e.g. modular/modular.")
    return repo^


def get_repo(c: Cache, b: Span[UInt8, _], args: Range) raises -> ToolOut:
    var found = _resolve(c, _repo_arg(b, args))
    var i = found[0]
    ref l = c.libs[i]
    var data = c.data(l.repo)
    var out = String('{"as_of":', _as_of(c), ',"url":', js(_repo_url(l.repo)), ',"repo":', js(l.repo))
    if found[1].byte_length() > 0:
        out.write(',"renamed_from":', js(found[1]))
    out.write(
        ',"description":', js(l.description), ',"topics":', _strs(l.topics), ',"license":', js(l.license),
        ',"stars":', l.stars, ',"forks":', l.forks, ',"open_issues":', l.open_issues,
        ',"archived":', "true" if l.archived else "false",
        ',"category":', js(c.categories[i]) if i < len(c.categories) and c.categories[i].byte_length() > 0 else "null",
        ',"created_at":', _iso_or_null(l.created_at), ',"last_commit":', _iso_or_null(l.last_commit),
        ',"commits":', l.commits, ',"commits_30d":', c.commits30[i] if i < len(c.commits30) else 0,
        ',"mojo_lines":', l.mojo_lines, ',"mojo_files":', l.mojo_files,
        ',"mojo_version":', js(l.mojo_version), ',"version_source":', js(l.version_source),
        ',"version_file":', js(l.version_file), ',"version_estimate":', js(l.version_estimate),
        ',"tooling":', js(l.tooling), ',"packaging":', js(l.packaging),
        ',"depends_on":', _strs(l.depends_on), ',"used_by":', len(l.used_by), ',"releases":[',
    )
    var nr = min(10, len(data.rels))
    for k in range(nr):
        ref x = data.rels[k]
        out.write(
            "," if k > 0 else "", '{"tag":', js(x.tag), ',"name":', js(x.name), ',"at":', _iso_or_null(x.at),
            ',"prerelease":', "true" if x.prerelease else "false", ',"mojo_version":', js(x.mojo_version), "}",
        )
    out += '],"migrations":['
    for k in range(len(data.ms)):
        ref m = data.ms[k]
        out.write(
            "," if k > 0 else "", '{"at":', _iso_or_null(m.at), ',"kind":', js(m.kind), ',"from":', js(m.from_value),
            ',"to":', js(m.to_value), ',"sha":', js(m.sha), "}",
        )
    out += '],"recent_commits":['
    var np = len(data.pts)
    var shown = min(20, np)
    for k in range(shown):
        ref p = data.pts[np - 1 - k]
        out.write(
            "," if k > 0 else "", '{"at":', _iso_or_null(p.at), ',"sha":', js(p.sha), ',"subject":', js(cut(p.subject, 200)),
            ',"mojo_version":', js(p.version), ',"mojo_lines":', p.lines, "}",
        )
    out += "]}"
    return ToolOut(out^, 1)


def similar_repos(c: Cache, b: Span[UInt8, _], args: Range) raises -> ToolOut:
    var found = _resolve(c, _repo_arg(b, args))
    var limit = _int_arg(b, args, "limit", LIMIT_DEFAULT, LIMIT_MAX)
    ref name = c.libs[found[0]].repo
    var out = String(
        '{"as_of":', _as_of(c), ',"url":', js(_repo_url(name)), ',"repo":', js(name), ',"similar":[',
    )
    var n = 0
    var at = Dict[String, Int]()
    for i in range(len(c.libs)):
        at[c.libs[i].repo] = i
    for ref nb in c.similar.get(name, List[Neighbor]()):
        if n >= limit:
            break
        var j = at.get(nb.repo, -1)
        if j < 0:
            continue
        out.write("," if n > 0 else "", repo_brief(c, j), ',"score":', nb.score, "}")
        n += 1
    out += "]"
    if name not in c.similar:
        out += ',"note":"This repo has no embedding yet, so nothing to compare."'
    out += "}"
    return ToolOut(out^, n)


def version_adoption(c: Cache, b: Span[UInt8, _], args: Range) raises -> ToolOut:
    var family = _str_arg(b, args, "family")
    ref ov = c.ov
    if family.byte_length() > 0:
        if family not in ov.families and not _has_family(c, family):
            var fams = String()
            for ref f in ov.families:
                fams.write(", " if fams.byte_length() > 0 else "", f)
            raise Error("Unknown family `", family, "`; the families are ", fams, ".")
    var out = String(
        '{"as_of":', _as_of(c), ',"url":', js(String(SITE_URL, "/migrations")),
        ',"family":', js(family) if family.byte_length() > 0 else "null", ',"repos_now":{"buckets":[',
    )
    var first = True
    for k in range(len(ov.buckets)):
        if family.byte_length() > 0 and version_family(ov.buckets[k]) != family:
            continue
        out.write(
            "" if first else ",", '{"bucket":', js(ov.buckets[k]), ',"repos":', ov.bucket_repos[k],
            ',"active_repos":', ov.bucket_active[k], "}",
        )
        first = False
    out += '],"families":['
    first = True
    for k in range(len(ov.families)):
        if family.byte_length() > 0 and ov.families[k] != family:
            continue
        out.write(
            "" if first else ",", '{"family":', js(ov.families[k]), ',"repos":', ov.family_repos[k],
            ',"active_repos":', ov.family_active[k], "}",
        )
        first = False
    # Without a family, the last 12 months that have a migration.
    var cutoff = String()
    if family.byte_length() == 0:
        var months = List[String]()
        for ref r in c.version_rows:
            if r.month not in months:
                months.append(r.month)
        for i in range(1, len(months)):
            var j = i
            while j > 0 and months[j - 1] > months[j]:
                months.swap_elements(j - 1, j)
                j -= 1
        if len(months) > 12:
            cutoff = months[len(months) - 12]
    out += ']},"moved_to_version_per_month":['
    var n = 0
    for ref r in c.version_rows:
        if family.byte_length() > 0 and version_family(r.version) != family:
            continue
        if cutoff.byte_length() > 0 and r.month < cutoff:
            continue
        out.write(
            "," if n > 0 else "", '{"month":', js(r.month), ',"version":', js(r.version), ',"repos":', r.repos, "}"
        )
        n += 1
    out += "]}"
    return ToolOut(out^, n)


def overview_tool(c: Cache) -> ToolOut:
    ref ov = c.ov
    var out = String(
        '{"as_of":', _as_of(c), ',"url":', js(String(SITE_URL, "/")), ',"repos":', ov.repos,
        ',"repos_with_history":', ov.with_history, ',"repos_30d_ago":', ov.repos_30_ago,
        ',"active_repos":', ov.active, ',"new_repos_this_month":', ov.new_this_month,
        ',"new_repos_last_month":', ov.new_last_month, ',"commits":', ov.commits,
        ',"commits_30d":', ov.commits_30, ',"commits_prev_30d":', ov.commits_prev_30,
        ',"mojo_lines":', ov.lines, ',"mojo_lines_30d_ago":', ov.lines_30_ago, ',"repos_per_version":[',
    )
    for k in range(len(ov.buckets)):
        out.write(
            "," if k > 0 else "", '{"bucket":', js(ov.buckets[k]), ',"repos":', ov.bucket_repos[k],
            ',"active_repos":', ov.bucket_active[k], "}",
        )
    out += '],"rising":['
    for k in range(len(c.rising)):
        out.write(
            "," if k > 0 else "", '{"repo":', js(c.rising[k]), ',"stars_30d":', c.rising_gain[k],
            ',"forks_30d":', c.rising_forks[k], ',"used_by":', c.rising_used_by[k], ',"stars":', c.rising_stars[k], "}",
        )
    out += '],"most_active":['
    for k in range(len(c.active_repos)):
        out.write(
            "," if k > 0 else "", '{"repo":', js(c.active_repos[k]), ',"commits_30d":', c.active_commits[k], "}"
        )
    out += '],"most_depended_on":['
    for k in range(len(c.depended)):
        ref d = c.depended[k]
        out.write("," if k > 0 else "", '{"repo":', js(d.name), ',"used_by":', d.used_by, "}")
    out += "]}"
    return ToolOut(out^, 1)


def call_tool(
    c: Cache, name: String, b: Span[UInt8, _], args: Range, qv: List[Float32] = List[Float32]()
) raises -> ToolOut:
    """Tool `name` (one of `tool_names`) on `args`; raises with a message for
    the agent when the arguments are wrong or the repo isn't there."""
    if name == "search_repos":
        return search_repos(c, b, args, qv)
    if name == "list_repos":
        return list_repos(c, b, args)
    if name == "get_repo":
        return get_repo(c, b, args)
    if name == "similar_repos":
        return similar_repos(c, b, args)
    if name == "version_adoption":
        return version_adoption(c, b, args)
    return overview_tool(c)


# ── JSON-RPC over HTTP ──────────────────────────────────────────────────


struct Outcome(Movable):
    """What a request asked and how it went, for its event."""

    var event: String
    """The PostHog event it is, "" for none."""
    var method: String
    var tool: String
    var arguments: String
    var client_name: String
    var client_version: String
    var protocol_version: String
    var status: String
    var error_type: String
    var results: Int
    var intent: String
    """A `get_more_tools` report, cut to `INTENT_MAX`."""

    def __init__(out self):
        self.event = String()
        self.method = String()
        self.tool = String()
        self.arguments = String()
        self.client_name = String()
        self.client_version = String()
        self.protocol_version = String()
        self.status = String("ok")
        self.error_type = String()
        self.results = 0
        self.intent = String()


def _json_response(status: Int, var body: String) raises -> Response:
    var reason = String("OK")
    if status == 400:
        reason = "Bad Request"
    elif status == 413:
        reason = "Content Too Large"
    elif status == 429:
        reason = "Too Many Requests"
    var resp = Response(status=status, reason=reason, body=List[UInt8](body.as_bytes()))
    resp.headers.set("Content-Type", "application/json")
    resp.headers.set("Cache-Control", "no-store")
    return resp^


def _rpc_result(id: String, result: String) raises -> Response:
    return _json_response(200, String('{"jsonrpc":"2.0","id":', id, ',"result":', result, "}"))


def _rpc_error(mut oc: Outcome, http: Int, id: String, code: Int, message: String) raises -> Response:
    oc.status = "rpc_error" if code != RATE_LIMITED else "rate_limited"
    if code == RATE_LIMITED:
        oc.error_type = "rate_limited"
    else:
        oc.error_type = "internal" if code == INTERNAL_ERROR else "validation"
    return _json_response(
        http, String('{"jsonrpc":"2.0","id":', id, ',"error":{"code":', code, ',"message":', js(message), "}}")
    )


def _tool_result(json: String, is_error: Bool) -> String:
    if is_error:
        return String('{"content":[{"type":"text","text":', js(json), '}],"isError":true}')
    return String('{"content":[{"type":"text","text":', js(json), '}],"structuredContent":', json, ',"isError":false}')


def client_ip(req: Request) -> String:
    """The client's address: Cloudflare's `CF-Connecting-IP` (the console is
    behind its tunnel), else the first of `X-Forwarded-For`, else the peer."""
    var cf = String(req.headers.get("CF-Connecting-IP").strip())
    if cf.byte_length() > 0:
        return cf^
    var xff = req.headers.get("X-Forwarded-For")
    if xff.byte_length() > 0:
        var comma = xff.find(",").or_else(-1)
        var first = String((String(xff[byte=:comma]) if comma >= 0 else xff).strip())
        if first.byte_length() > 0:
            return first^
    return String(req.peer.ip)


def _query_vector(model: Int, c: Cache, q: String) -> List[Float32]:
    """`q` embedded, when the model is loaded and is the revision the repos
    were embedded with; else empty (text search only), as the search page."""
    if model == 0 or q.byte_length() == 0:
        return List[Float32]()
    ref models = Pointer[Swap[QueryModel], MutUntrackedOrigin](unsafe_from_address=model)[]
    var held = models.get()
    if not held[].ready() or held[].rev() != c.embed_rev:
        return List[Float32]()
    try:
        return held[].embed(q)
    except e:
        print("console: MCP search query:", e)
        return List[Float32]()


def _minute_now() -> Int64:
    try:
        return now() // 60
    except:
        return 0


def handle_mcp(req: Request, c: Cache, mut st: McpState, mut oc: Outcome, model: Int = 0) raises -> Response:
    """One POST /mcp: the answer, with `out` filled in for the event."""
    var ua = client_of_agent(req.headers.get("User-Agent"))
    oc.client_name = ua[0]
    oc.client_version = ua[1]
    oc.protocol_version = cut(String(req.headers.get("MCP-Protocol-Version").strip()), 40)
    if len(req.body) > MAX_BODY:
        return _rpc_error(oc, 413, "null", INVALID_REQUEST, "The body is over 64 KB.")
    var b = Span(req.body)
    var n = len(b)
    var end = valid_json(b, 0, n)
    if end < 0 or skip_ws(b, end, n) != n:
        return _rpc_error(oc, 400, "null", PARSE_ERROR, "Parse error: the body isn't one JSON value.")
    var start = skip_ws(b, 0, n)
    var msg = Range(start, end)
    if b[start] == UInt8(ord("[")):
        return _rpc_error(oc, 400, "null", INVALID_REQUEST, "Batches aren't supported: send one message per POST.")
    if b[start] != UInt8(ord("{")):
        return _rpc_error(oc, 400, "null", INVALID_REQUEST, "The message must be a JSON-RPC 2.0 object.")
    var idr = field(b, msg, "id")
    var id = String("null")
    if idr.found():
        var f = _first(b, idr)
        if f == UInt8(ord('"')) or f == UInt8(ord("-")) or (f >= 0x30 and f <= 0x39):
            id = raw(b, idr)
        else:
            return _rpc_error(oc, 400, "null", INVALID_REQUEST, "`id` must be a string or a number.")
    var mr = field(b, msg, "method")
    if text(b, field(b, msg, "jsonrpc")) != "2.0" or not _is_string(b, field(b, msg, "jsonrpc")):
        return _rpc_error(oc, 400, id, INVALID_REQUEST, 'Not JSON-RPC 2.0: `"jsonrpc":"2.0"` is missing.')
    if not mr.found():
        if idr.found() and (field(b, msg, "result").found() or field(b, msg, "error").found()):
            # A response to a request of ours: there are none, but it's accepted.
            return Response(status=202, reason="Accepted")
        return _rpc_error(oc, 400, id, INVALID_REQUEST, "`method` is missing.")
    if not _is_string(b, mr):
        return _rpc_error(oc, 400, id, INVALID_REQUEST, "`method` must be a string.")
    var method = text(b, mr)
    oc.method = cut(method, 100)
    if not idr.found():
        # A notification (notifications/initialized, ...): nothing to answer.
        return Response(status=202, reason="Accepted")
    var params = field(b, msg, "params")
    if params.found() and not _is_null(b, params) and not _is_object(b, params):
        return _rpc_error(oc, 200, id, INVALID_PARAMS, "`params` must be an object.")
    if params.found() and _is_null(b, params):
        params = Range(-1, -1)
    if method == "initialize":
        oc.event = "$mcp_initialize"
        var asked = text(b, field(b, params, "protocolVersion")) if params.found() else String()
        var version = asked if asked in supported_protocols() else String(DEFAULT_PROTOCOL)
        oc.protocol_version = version
        if params.found():
            var info = field(b, params, "clientInfo")
            if _is_object(b, info):
                var name = text(b, field(b, info, "name"))
                if name.byte_length() > 0:
                    oc.client_name = cut(name, 100)
                    oc.client_version = cut(text(b, field(b, info, "version")), 100)
        return _rpc_result(
            id,
            String(
                '{"protocolVersion":', js(version), ',"capabilities":{"tools":{}}',
                ',"serverInfo":{"name":"mojourney","version":', js(census_version()), "}",
                ',"instructions":',
                js(
                    "Read-only tools over Mojourney, the census of public GitHub repos with Mojo code:"
                    " search and list the repos, read one, find similar ones, and see Mojo version adoption."
                    " If none of them can do what the user needs, get_more_tools reports that to Mojourney's"
                    " developers: it reads nothing and returns no tools."
                ),
                "}",
            ),
        )
    if method == "ping":
        return _rpc_result(id, "{}")
    if method == "tools/list":
        oc.event = "$mcp_tools_list"
        oc.results = len(listed_tool_names())
        return _rpc_result(id, String('{"tools":', tools_json(), "}"))
    if method != "tools/call":
        return _rpc_error(oc, 200, id, METHOD_NOT_FOUND, String("Method not found: ", cut(method, 100)))
    var nr = field(b, params, "name") if params.found() else Range(-1, -1)
    if not _is_string(b, nr):
        return _rpc_error(oc, 200, id, INVALID_PARAMS, "tools/call needs `params.name`, the tool's name.")
    var name = text(b, nr)
    var args = field(b, params, "arguments")
    if args.found() and _is_null(b, args):
        args = Range(-1, -1)
    oc.tool = cut(name, 100)
    oc.arguments = trim_arguments(b, args)
    if name in tool_names():
        oc.event = "$mcp_tool_call"
    var minute = _minute_now()
    if not st.admit_call(client_ip(req), minute):
        var resp = _rpc_error(
            oc, 429, id, RATE_LIMITED,
            String("Too many tool calls: at most ", st.calls_per_minute, " a minute per client. Try again in a minute."),
        )
        resp.headers.set("Retry-After", "60")
        return resp^
    if name != MORE_TOOLS and name not in tool_names():
        return _rpc_error(oc, 200, id, INVALID_PARAMS, String("Unknown tool: ", cut(name, 100)))
    if args.found() and not _is_object(b, args):
        return _rpc_error(oc, 200, id, INVALID_PARAMS, "`arguments` must be an object.")
    if name == MORE_TOOLS:
        # Needs no data, so it answers while the census warms up too. Only an
        # accepted report is an event, and never a tool call.
        var context: String
        try:
            context = _str_arg(b, args, "context", required=True)
        except e:
            oc.status = "tool_error"
            oc.error_type = "validation"
            return _rpc_result(id, _tool_result(String(e), True))
        oc.event = MISSING_CAPABILITY
        oc.arguments = String()
        oc.intent = cut(context, INTENT_MAX)
        return _rpc_result(id, String('{"content":[{"type":"text","text":', js(MORE_TOOLS_REPLY), '}],"isError":false}'))
    if not c.ready:
        oc.status = "tool_error"
        oc.error_type = "internal"
        return _rpc_result(id, _tool_result("The census is warming up (reading its data for the first time); try again in a minute.", True))
    try:
        var qv = List[Float32]()
        if name == "search_repos" and args.found():
            var qr = field(b, args, "query")
            if _is_string(b, qr):
                qv = _query_vector(model, c, String(text(b, qr).strip()))
        var got = call_tool(c, name, b, args, qv)
        oc.results = got.results
        return _rpc_result(id, _tool_result(got.json, False))
    except e:
        oc.status = "tool_error"
        oc.error_type = "validation"
        return _rpc_result(id, _tool_result(String(e), True))


def mcp_event(req: Request, oc: Outcome, resp: Response, mut st: McpState, started_ns: Int) -> McpEvent:
    var t = Int64(0)
    try:
        t = now()
    except:
        pass
    var ms = (Int(perf_counter_ns()) - started_ns) // 1_000_000
    var at_us = t * 1_000_000 - Int64(ms) * 1000
    return McpEvent(
        oc.event, st.ids.id_of(client_ip(req), t // 86400), session_id(at_us), at_us, census_version(), oc.tool,
        oc.arguments, listed_tool_names() if oc.event == "$mcp_tools_list" else List[String](), oc.client_name,
        oc.client_version, cut(String(req.headers.get("User-Agent").strip()), HEADER_MAX),
        cut(String(req.headers.get("X-Anthropic-Client").strip()), HEADER_MAX), oc.protocol_version, oc.status,
        oc.error_type, oc.results, ms, len(resp.body), oc.intent,
    )


@fieldwise_init
struct McpSite(Copyable, Handler):
    """`POST /mcp`, with the addresses of the `Swap[Cache]`, the
    `Swap[QueryModel]` and the `McpState`, which live as long as the
    process."""

    var cache: Int
    var model: Int
    var state: Int

    def serve(self, req: Request) raises -> Response:
        var started = Int(perf_counter_ns())
        ref sw = Pointer[Swap[Cache], MutUntrackedOrigin](unsafe_from_address=self.cache)[]
        ref st = Pointer[McpState, MutUntrackedOrigin](unsafe_from_address=self.state)[]
        var held = sw.get()
        var oc = Outcome()
        var resp: Response
        try:
            resp = handle_mcp(req, held[], st, oc, self.model)
        except e:
            print("console: MCP:", e)
            resp = _rpc_error(oc, 200, "null", INTERNAL_ERROR, "Internal error.")
        if st.events.on() and oc.event.byte_length() > 0:
            st.events.push(event_json(mcp_event(req, oc, resp, st, started)))
        return resp^
