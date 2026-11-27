"""The MCP server at POST /mcp (#229): its JSON-RPC handling (a bad body,
an unknown method, an unknown tool, missing arguments, notifications), each
tool against a test cache through the console's router, `get_more_tools`,
the tools/call limit, and its PostHog events (built and queued only; nothing is sent)."""

from std.memory.alloc import unsafe_alloc
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from flare.http import Request, Response, Router

from checks import CheckRun
from console_cache import Cache, RepoData
from console_live import LiveData
from console_mcp import MORE_TOOLS_REPLY, McpState, Outcome, handle_mcp, listed_tool_names, tool_names
from console_routes import console_router
from jscan import Range, field, text
from mcp_events import ClientIds, EventQueue, INTENT_MAX, McpEvent, event_json, session_id, trim_arguments
from model import Library, Migration, Point, Release, VersionMonth
from querymodel import QueryModel
from similar import Neighbor
from swap import Swap


def _lib(repo: String, description: String, topics: List[String], stars: Int64, aliases: List[String] = List[String]()) -> Library:
    return Library(
        repo, description, 1_700_000_000_000_000, 1_700_000_000_000_000, "language", stars, 3, "MIT", 100, 4,
        1_700_000_000_000_000, 1_710_000_000_000_000, 2_000, 10, "pixi", "25.1", topics.copy(), 0, 1, 2, False,
        "ok", "", "pixi.lock", "", "", -1, List[String](), List[String](), List[String](), List[String](),
        List[String](), "rattler", aliases[0] if len(aliases) > 0 else repo, aliases.copy(),
    )


def _cache() raises -> Cache:
    """Two repos, acme/tomlkit with commits, a release and a migration, and
    acme/http, once old-owner/mojo-http; each other's similar repo."""
    var c = Cache()
    c.ready = True
    c.built_day = 20_400
    c.libs.append(_lib("acme/tomlkit", "A TOML reader", ["toml", "parser"], 12))
    c.libs.append(_lib("acme/http", "HTTP for Mojo", ["web"], 40, ["old-owner/mojo-http"]))
    c.moved["old-owner/mojo-http"] = "acme/http"
    for ref l in c.libs:
        c.lines.append(l.mojo_lines)
        c.files.append(l.mojo_files)
        c.stars.append(l.stars)
        c.forks.append(l.forks)
        c.used_by.append(0)
        c.buckets.append("pre-1.0")
        c.families.append("25.x")
        c.est_buckets.append("pre-1.0")
        c.est_families.append("25.x")
        c.news.append(0)
        c.active.append(True)
        c.commits30.append(1)
        c.categories.append("")
        c.history.append(Int64(l.commits))
    var d = RepoData()
    for k in range(25):
        d.pts.append(
            Point(Int64(1_700_000_000_000_000 + k * 1_000_000), Int64(100 * k), String("sha", k), "pixi", "25.1", String("commit ", k), "")
        )
    d.rels.append(Release("v0.2", "0.2", 1_705_000_000_000_000, False, "release", "abc", "25.1"))
    d.ms.append(Migration("acme/tomlkit", "abc", 1_705_000_000_000_000, "mojo_version", "24.6", "25.1"))
    c.details["acme/tomlkit"] = d^
    c.similar["acme/tomlkit"] = [Neighbor("acme/http", 0.75)]
    c.version_rows.append(VersionMonth("2025-06", "25.1", 3))
    c.version_rows.append(VersionMonth("2025-07", "1.0", 2))
    c.rising.append("acme/http")
    c.rising_gain.append(5)
    c.rising_forks.append(1)
    c.rising_used_by.append(0)
    c.rising_score.append(5)
    c.rising_stars.append(40)
    c.ov.repos = 2
    c.ov.buckets = ["pre-1.0"]
    c.ov.bucket_repos = [2]
    c.ov.bucket_active = [2]
    c.ov.families = ["25.x"]
    c.ov.family_repos = [2]
    c.ov.family_active = [2]
    return c^


def _state(per_minute: Int = 60, key: String = String()) raises -> Int:
    var p = unsafe_alloc[McpState](1)
    p.unsafe_write(McpState(key, per_minute))
    return Int(p)


def _router(state: Int) raises -> Router:
    var p = unsafe_alloc[Swap[Cache]](1)
    p.unsafe_write(Swap[Cache](_cache()))
    var pc = unsafe_alloc[Swap[CheckRun]](1)
    pc.unsafe_write(Swap[CheckRun](CheckRun()))
    var pm = unsafe_alloc[Swap[QueryModel]](1)
    pm.unsafe_write(Swap[QueryModel](QueryModel()))
    var pl = unsafe_alloc[Swap[LiveData]](1)
    pl.unsafe_write(Swap[LiveData](LiveData()))
    return console_router(Int(p), Int(pc), Int(pm), Int(pl), state)


def _post(r: Router, body: String, ip: String = "203.0.113.7") raises -> Response:
    var req = Request("POST", "/mcp", body=List[UInt8](body.as_bytes()))
    req.headers.set("Content-Type", "application/json")
    req.headers.set("CF-Connecting-IP", ip)
    req.headers.set("User-Agent", "test-agent/1.2 (x)")
    return r.serve(req)


def _body(resp: Response) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body)))


def _call(tool: String, args: String, id: Int = 1) -> String:
    return String(
        '{"jsonrpc":"2.0","id":', id, ',"method":"tools/call","params":{"name":"', tool, '","arguments":', args, "}}"
    )


def _code(resp: Response) -> String:
    """The JSON-RPC error code of `resp`, or ""."""
    var s = _body(resp)
    var b = s.as_bytes()
    var err = field(b, Range(0, len(b)), "error")
    if not err.found():
        return String()
    return text(b, field(b, err, "code"))


def _text_of(resp: Response) -> String:
    """A tool result's `content[0].text`."""
    var s = _body(resp)
    var k = s.find('"text":').or_else(-1)
    return String(s[byte=k:]) if k >= 0 else String()


def test_bad_body() raises:
    var r = _router(_state())
    var bad = _post(r, "{not json")
    assert_equal(bad.status, 400)
    assert_equal(_code(bad), "-32700")
    assert_true('"id":null' in _body(bad))
    assert_equal(_code(_post(r, "")), "-32700")
    assert_equal(_code(_post(r, '{"jsonrpc":"2.0","id":1,"method":"ping"} x')), "-32700")
    assert_equal(_code(_post(r, '[{"jsonrpc":"2.0","id":1,"method":"ping"}]')), "-32600")
    assert_equal(_code(_post(r, '{"id":1,"method":"ping"}')), "-32600")
    assert_equal(_code(_post(r, '{"jsonrpc":"2.0","id":{},"method":"ping"}')), "-32600")
    assert_equal(_code(_post(r, '{"jsonrpc":"2.0","id":1,"method":7}')), "-32600")
    assert_equal(_code(_post(r, '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[]}')), "-32602")
    var big = String('{"jsonrpc":"2.0","id":1,"method":"ping","pad":"')
    for _ in range(70 * 1024):
        big += "x"
    big += '"}'
    var too_big = _post(r, big)
    assert_equal(too_big.status, 413)
    assert_equal(_code(too_big), "-32600")
    # GET isn't part of the transport here.
    assert_equal(r.serve(Request("GET", "/mcp")).status, 405)


def test_unknown_method() raises:
    var r = _router(_state())
    var resp = _post(r, '{"jsonrpc":"2.0","id":"a","method":"resources/list"}')
    assert_equal(resp.status, 200)
    assert_equal(_code(resp), "-32601")
    assert_true('"id":"a"' in _body(resp))


def test_notification_and_ping() raises:
    var r = _router(_state())
    var note = _post(r, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
    assert_equal(note.status, 202)
    assert_equal(len(note.body), 0)
    var ping = _post(r, '{"jsonrpc":"2.0","id":3,"method":"ping"}')
    assert_equal(_body(ping), '{"jsonrpc":"2.0","id":3,"result":{}}')
    assert_equal(ping.headers.get("Content-Type"), "application/json")


def test_initialize() raises:
    var r = _router(_state())
    var s = _body(
        _post(
            r,
            '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26",'
            '"capabilities":{},"clientInfo":{"name":"inspector","version":"0.1"}}}',
        )
    )
    assert_true('"protocolVersion":"2025-03-26"' in s, s)
    assert_true('"capabilities":{"tools":{}}' in s)
    assert_true('"serverInfo":{"name":"mojourney","version":' in s)
    var other = _body(_post(r, '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'))
    assert_true('"protocolVersion":"2025-06-18"' in other)


def test_tools_list() raises:
    var r = _router(_state())
    var s = _body(_post(r, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'))
    for name in tool_names():
        assert_true(String('"name":"', name, '"') in s, name)
    assert_equal(s.count('"inputSchema":{"type":"object"'), 7)
    assert_equal(s.count("GH Archive"), 6)
    # get_more_tools last, as PostHog's SDKs define it.
    assert_equal(listed_tool_names()[len(listed_tool_names()) - 1], "get_more_tools")
    assert_true(
        s.endswith(
            '{"name":"get_more_tools","description":"Report that the user\'s request needs a capability this server'
            " does not have. Records the report for the server's developers; it does not return or add tools.\""
            ',"inputSchema":{"type":"object","properties":{"context":{"type":"string","description":"A description'
            ' of your goal and what kind of tool would help accomplish it."}},"required":["context"]}'
            ',"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,'
            '"openWorldHint":false}}]}}'
        ),
        s,
    )


def test_unknown_tool_and_missing_arguments() raises:
    var r = _router(_state())
    assert_equal(_code(_post(r, _call("delete_repo", "{}"))), "-32602")
    assert_equal(_code(_post(r, '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}')), "-32602")
    var missing = _body(_post(r, _call("get_repo", "{}")))
    assert_true('"isError":true' in missing)
    assert_true("Missing argument `repo`" in missing)
    var empty_query = _body(_post(r, _call("search_repos", '{"query":"  "}')))
    assert_true('"isError":true' in empty_query)
    var bad_limit = _body(_post(r, _call("list_repos", '{"limit":500}')))
    assert_true("must be an integer from 1 to 50" in bad_limit)
    var bad_sort = _body(_post(r, _call("list_repos", '{"sort":"size"}')))
    assert_true('"isError":true' in bad_sort)
    var bad_cat = _body(_post(r, _call("list_repos", '{"category":"robots"}')))
    assert_true("Unknown category" in bad_cat)
    var unknown = _body(_post(r, _call("get_repo", '{"repo":"nobody/nothing"}')))
    assert_true('"isError":true' in unknown)
    assert_true("No repo `nobody/nothing`" in unknown)


def test_search_repos() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("search_repos", '{"query":"toml"}')))
    assert_true('"isError":false' in s)
    assert_true('"structuredContent":{"as_of":' in s)
    assert_true('"repo":"acme/tomlkit","url":"https://mojourney.dev/repos/acme/tomlkit"' in s)
    assert_true('"match":"text"' in s)
    assert_true('"url":"https://mojourney.dev/search?q=toml"' in s)
    assert_false('"repo":"acme/http"' in s)
    # The version filter: no repo is on 1.x.
    var none = _body(_post(r, _call("search_repos", '{"query":"toml","version":"1.x"}')))
    assert_true('"results":[]' in none)


def test_list_repos() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("list_repos", '{"limit":1}')))
    assert_true('"sort":"stars","total":2' in s, s)
    # acme/http has the more stars, and only one is asked for.
    assert_true('"repo":"acme/http"' in s)
    assert_false('"repo":"acme/tomlkit"' in s)
    assert_true('"url":"https://mojourney.dev/repos?sort=stars"' in s)
    var rising = _body(_post(r, _call("list_repos", '{"sort":"rising"}')))
    assert_true('"total":1' in rising)
    var recent = _body(_post(r, _call("list_repos", '{"sort":"recent","active":true}')))
    assert_true('"total":2' in recent)


def test_get_repo() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("get_repo", '{"repo":"acme/tomlkit"}')))
    assert_true('"isError":false' in s)
    assert_true('"license":"MIT"' in s)
    assert_true('"mojo_version":"25.1","version_source":"pixi.lock"' in s)
    assert_true('"releases":[{"tag":"v0.2"' in s)
    assert_true('"migrations":[{"at":' in s)
    # The 20 newest commits of 25, newest first.
    assert_true('"recent_commits":[{"at":' in s)
    assert_true("commit 24" in s)
    assert_true("commit 5" in s)
    assert_false("commit 4\\" in s)
    var moved = _body(_post(r, _call("get_repo", '{"repo":"old-owner/mojo-http"}')))
    assert_true('"repo":"acme/http","renamed_from":"old-owner/mojo-http"' in moved)


def test_similar_repos() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("similar_repos", '{"repo":"acme/tomlkit"}')))
    assert_true('"similar":[{"repo":"acme/http"' in s, s)
    assert_true('"score":0.75' in s)
    var none = _body(_post(r, _call("similar_repos", '{"repo":"acme/http"}')))
    assert_true("no embedding yet" in none)


def test_version_adoption() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("version_adoption", "{}")))
    assert_true('"url":"https://mojourney.dev/migrations"' in s)
    assert_true('"buckets":[{"bucket":"pre-1.0","repos":2,"active_repos":2}]' in s)
    assert_true('{"month":"2025-07","version":"1.0","repos":2}' in s)
    var one = _body(_post(r, _call("version_adoption", '{"family":"1.x"}')))
    assert_true('"family":"1.x"' in one, one)
    assert_true('"version":"1.0"' in one)
    assert_false('"version":"25.1"' in one)
    assert_true('"isError":true' in _body(_post(r, _call("version_adoption", '{"family":"9.x"}'))))


def test_overview() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("overview", "{}")))
    assert_true('"isError":false' in s)
    assert_true('"repos":2' in s)
    assert_true('"rising":[{"repo":"acme/http","stars_30d":5' in s)
    assert_true('"url":"https://mojourney.dev/"' in s)


def test_get_more_tools() raises:
    var r = _router(_state())
    var s = _body(_post(r, _call("get_more_tools", '{"context":"A tool to compare two repos\' benchmarks"}')))
    assert_equal(
        s,
        String(
            '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"', MORE_TOOLS_REPLY,
            '"}],"isError":false}}',
        ),
    )
    # A report needs `context`, a string with something in it.
    for args in ["{}", '{"context":"   "}', '{"context":null}']:
        var bad = _body(_post(r, _call("get_more_tools", args)))
        assert_true('"isError":true' in bad, bad)
        assert_true("Missing argument `context`" in bad, bad)
    assert_true("`context` must be a string" in _body(_post(r, _call("get_more_tools", '{"context":7}'))))
    assert_equal(_code(_post(r, _call("get_more_tools", "[]"))), "-32602")
    # It reads nothing, so it answers while the census warms up.
    var cold = _cache()
    cold.ready = False
    var oc = _outcome(cold^, _call("get_more_tools", '{"context":"x"}'))
    assert_equal(oc.status, "ok")
    assert_equal(oc.event, "$mcp_missing_capability")


def test_get_more_tools_events() raises:
    var ok = _outcome(_cache(), _call("get_more_tools", '{"context":"  Need a tool that lists GPU kernels  "}'))
    assert_equal(ok.event, "$mcp_missing_capability")
    assert_equal(ok.tool, "get_more_tools")
    assert_equal(ok.intent, "Need a tool that lists GPU kernels")
    assert_equal(ok.arguments, "")
    # A refused report is no event, a tool call least of all.
    assert_equal(_outcome(_cache(), _call("get_more_tools", "{}")).event, "")
    assert_equal(_outcome(_cache(), _call("get_more_tools", '{"context":""}')).event, "")
    assert_equal(_outcome(_cache(), _call("get_more_tools", '{"context":"x"}'), per_minute=0).event, "")
    # A long report is cut, not refused.
    var long = String()
    for _ in range(3000):
        long += "é"
    var cut = _outcome(_cache(), _call("get_more_tools", String('{"context":"', long, '"}')))
    assert_equal(cut.event, "$mcp_missing_capability")
    assert_equal(cut.intent.count_codepoints(), INTENT_MAX)
    # Through the router, with a key: one event queued (none sent), the one PostHog's SDK sends.
    var state = _state(key="phc_test")
    var r = _router(state)
    _ = _post(r, _call("get_more_tools", '{"context":"Need a tool for \\"x\\"\\nand y"}'))
    ref st = Pointer[McpState, MutUntrackedOrigin](unsafe_from_address=state)[]
    var got = st.events.take()
    assert_equal(len(got), 1)
    var j = got[0]
    assert_true(j.startswith('{"event":"$mcp_missing_capability","distinct_id":"mcp_'), j)
    assert_true('"$mcp_source":"posthog_mcp_analytics","$mcp_interface":"mcp","$session_id":"ses_' in j, j)
    assert_true('"$mcp_server_name":"mojourney"' in j, j)
    assert_true('"$mcp_resource_name":"get_more_tools"' in j, j)
    assert_true('"$mcp_client_name":"test-agent","$mcp_client_version":"1.2"' in j, j)
    assert_true('"$mcp_client_user_agent":"test-agent/1.2 (x)"' in j, j)
    assert_true(
        '"$mcp_intent":"Need a tool for \\"x\\"\\nand y","$mcp_intent_source":"context_parameter"' in j, j
    )
    assert_true(j.endswith('"$process_person_profile":false,"$ip":null,"$geoip_disable":true}}'), j)
    for absent in ["$mcp_tool_name", "$mcp_is_error", "$mcp_duration_ms", "$mcp_parameters", '"arguments"', '"status"']:
        assert_false(String(absent) in j, absent)
    # tools/list lists it among the tools.
    _ = _post(r, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    assert_true('"overview","get_more_tools"]' in st.events.take()[0])
    # Without a key it answers the same and nothing is kept.
    var off = _state()
    var r_off = _router(off)
    assert_true(MORE_TOOLS_REPLY in _body(_post(r_off, _call("get_more_tools", '{"context":"x"}'))))
    ref st_off = Pointer[McpState, MutUntrackedOrigin](unsafe_from_address=off)[]
    assert_false(st_off.events.on())
    assert_equal(st_off.events.count(), 0)


def test_tools_call_limit() raises:
    var r = _router(_state(2))
    assert_equal(_post(r, _call("overview", "{}")).status, 200)
    assert_equal(_post(r, _call("overview", "{}")).status, 200)
    var third = _post(r, _call("overview", "{}"))
    assert_equal(third.status, 429)
    assert_equal(_code(third), "-32000")
    assert_equal(third.headers.get("Retry-After"), "60")
    # Another client, and the other methods, aren't limited by it.
    assert_equal(_post(r, _call("overview", "{}"), "198.51.100.1").status, 200)
    assert_equal(_post(r, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}').status, 200)


def _outcome(var c: Cache, body: String, per_minute: Int = 60) raises -> Outcome:
    var st = McpState(String(), per_minute)
    var out = Outcome()
    var req = Request("POST", "/mcp", body=List[UInt8](body.as_bytes()))
    req.headers.set("User-Agent", "claude-code/2.0.1 (darwin)")
    _ = handle_mcp(req, c, st, out)
    return out^


def test_event_statuses() raises:
    var ok = _outcome(_cache(), _call("search_repos", '{"query":"toml"}'))
    assert_equal(ok.status, "ok")
    assert_equal(ok.method, "tools/call")
    assert_equal(ok.tool, "search_repos")
    assert_equal(ok.arguments, '{"query":"toml"}')
    assert_equal(ok.results, 1)
    assert_equal(ok.client_name, "claude-code")
    assert_equal(ok.client_version, "2.0.1")
    assert_equal(_outcome(_cache(), _call("get_repo", "{}")).status, "tool_error")
    assert_equal(_outcome(_cache(), "nope").status, "rpc_error")
    assert_equal(_outcome(_cache(), _call("overview", "{}"), 0).status, "rate_limited")
    var init = _outcome(
        _cache(),
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18",'
        '"clientInfo":{"name":"inspector","version":"0.17"}}}',
    )
    assert_equal(init.client_name, "inspector")
    assert_equal(init.client_version, "0.17")
    assert_equal(init.protocol_version, "2025-06-18")


def test_event_json() raises:
    var ids = ClientIds()
    var id = ids.id_of("203.0.113.7", 20_400)
    assert_equal(id, ids.id_of("203.0.113.7", 20_400))
    assert_true(id != ids.id_of("203.0.113.7", 20_401))
    var e = McpEvent(
        "$mcp_tool_call", id, "ses_x", 1_763_800_000_000_000, "1.23.0", "get_repo", '{"repo":"acme/x"}',
        List[String](), "inspector", "0.17", "inspector/0.17 (x)", "", "2025-06-18", "ok", "", 1, 12, 345, "",
    )
    var j = event_json(e)
    assert_true(j.startswith('{"event":"$mcp_tool_call","distinct_id":"mcp_'), j)
    assert_false("203.0.113" in j)
    assert_true('"$mcp_source":"posthog_mcp_analytics"' in j, j)
    assert_true('"$session_id":"ses_x","$mcp_server_name":"mojourney","$mcp_server_version":"1.23.0"' in j, j)
    assert_true('"$mcp_tool_name":"get_repo","$mcp_resource_name":"get_repo"' in j, j)
    assert_true('"arguments":"{\\"repo\\":\\"acme/x\\"}"' in j, j)
    assert_true('"$mcp_client_user_agent":"inspector/0.17 (x)"' in j, j)
    # A JSON boolean and number, and nothing for what there isn't.
    assert_true('"$mcp_is_error":false,"$mcp_duration_ms":12,"status":"ok","results":1' in j, j)
    assert_false("$mcp_vendor_client" in j)
    assert_false("$mcp_error_type" in j)
    assert_true('"$process_person_profile":false,"$ip":null,"$geoip_disable":true' in j)
    e.status = "tool_error"
    e.error_type = "validation"
    assert_true('"$mcp_is_error":true,"$mcp_error_type":"validation"' in event_json(e))
    # No tool, no arguments.
    e.name = "$mcp_tools_list"
    e.tool = ""
    e.listed = ["a", "b"]
    var listed = event_json(e)
    assert_false('"arguments"' in listed)
    assert_false("$mcp_tool_name" in listed)
    assert_true('"$mcp_listed_tool_names":["a","b"]' in listed)
    assert_false("$mcp_intent" in listed)


def test_session_id() raises:
    var s = session_id(1_763_800_000_000_000)
    assert_equal(s.byte_length(), 40)
    assert_true(s.startswith("ses_"), s)
    assert_equal(String(s[byte=18:19]), "7")
    assert_true(s != session_id(1_763_800_000_000_000))
    var r1 = String(s[byte=4:17])
    assert_equal(r1, String(session_id(1_763_800_000_000_000)[byte=4:17]))


def test_event_names() raises:
    assert_equal(_outcome(_cache(), _call("overview", "{}")).event, "$mcp_tool_call")
    assert_equal(_outcome(_cache(), '{"jsonrpc":"2.0","id":1,"method":"tools/list"}').event, "$mcp_tools_list")
    assert_equal(_outcome(_cache(), '{"jsonrpc":"2.0","id":1,"method":"initialize"}').event, "$mcp_initialize")
    # Not sent: a tool there isn't, pings, notifications and bad messages.
    assert_equal(_outcome(_cache(), _call("nope", "{}")).event, "")
    assert_equal(_outcome(_cache(), '{"jsonrpc":"2.0","id":1,"method":"ping"}').event, "")
    assert_equal(_outcome(_cache(), '{"jsonrpc":"2.0","method":"initialize"}').event, "")
    assert_equal(_outcome(_cache(), "{").event, "")
    var limited = _outcome(_cache(), _call("overview", "{}"), per_minute=0)
    assert_equal(limited.event, "$mcp_tool_call")
    assert_equal(limited.error_type, "rate_limited")
    assert_equal(_outcome(_cache(), _call("get_repo", "{}")).error_type, "validation")


def test_trim_arguments() raises:
    var long = String()
    for _ in range(500):
        long += "é"
    var s = String('{"query":"', long, '","limit":5,"nested":{"a":["', long, '"]},"more":"', long, '"}')
    var b = s.as_bytes()
    var t = trim_arguments(b, Range(0, len(b)))
    var cut = String()
    for _ in range(200):
        cut += "é"
    assert_true(String('{"query":"', cut, '","limit":5,"nested":{"a":["', cut, '"]}') in t, t)
    assert_true(t.byte_length() <= 1024)
    # Each string is 400 bytes once cut, so "more" no longer fits in 1 KB.
    assert_false('"more"' in t)
    assert_true(t.endswith(',"_truncated":true}'), t)
    var small = String('{"repo":"a/b"}')
    var sb = small.as_bytes()
    assert_equal(trim_arguments(sb, Range(0, len(sb))), '{"repo":"a/b"}')
    assert_equal(trim_arguments(sb, Range(-1, -1)), "{}")


def test_queue_drops_oldest() raises:
    var q = EventQueue("phc_test", 3)
    assert_true(q.on())
    for k in range(5):
        q.push(String(k))
    assert_equal(q.count(), 3)
    assert_equal(q.dropped, 2)
    var got = q.take(2)
    assert_equal(len(got), 2)
    assert_equal(got[0], "2")
    assert_equal(got[1], "3")
    assert_equal(q.take()[0], "4")
    assert_equal(q.count(), 0)
    # Without a project key, nothing is kept.
    var off = EventQueue("")
    assert_false(off.on())
    off.push("x")
    assert_equal(off.count(), 0)
    assert_false(EventQueue("not-a-key").on())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
