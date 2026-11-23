"""`/ai`, Use with AI: how to add the MCP server (`console_mcp`) to an
agent, its tools, and the other ways agents read the census. Also
`/.well-known/mcp-registry-auth`, the public key the MCP Registry checks
before it lists the server as `dev.mojourney/census` (server.json)."""

from flare.http import Request, Response, html_escape

from console_layout import EDGE_CACHE, SITE_URL, _page
from console_pages import page_line


comptime MCP_URL = SITE_URL + "/mcp"

comptime REGISTRY_AUTH = "v=MCPv1; k=ed25519; p=TCW6v4WiPRzttOyQl2tPjcQbZ+k3+09Oa+QdGUWI4qk="
"""The public half of the key `mcp-publisher login http` signs with; the
private half is kept outside the repo (README, Publishing the MCP server)."""


def _cmd(text: String) -> String:
    return String("<pre class=cmd><code>", html_escape(text), "</code></pre>")


def _tool(name: String, text: String) -> String:
    return String("<li><code>", name, "</code>: ", text, "</li>")


def ai_page(req: Request) raises -> Response:
    var h = String(
        "<div class=prose><h1>Use with AI</h1>",
        "<p class=lead>Mojourney is also a remote MCP server, so an agent can look up Mojo",
        " repos, versions and growth while it works: which libraries exist before it writes one,",
        " which Mojo version they need, and what is similar. It is read-only, needs no sign-in and",
        " answers from the same data as these pages.</p>",
        _cmd(MCP_URL),
        "<h2>Add it</h2>",
        "<p><b>Claude Code</b></p>",
        _cmd(String("claude mcp add --transport http mojourney ", MCP_URL)),
        "<p><b>Claude (claude.ai and the desktop app)</b>: Settings, Connectors, Add custom",
        " connector, with the URL above.</p>",
        "<p><b>Cursor</b>, in <code>~/.cursor/mcp.json</code></p>",
        _cmd(String('{"mcpServers": {"mojourney": {"url": "', MCP_URL, '"}}}')),
        "<p><b>VS Code</b>, in <code>.vscode/mcp.json</code></p>",
        _cmd(String('{"servers": {"mojourney": {"type": "http", "url": "', MCP_URL, '"}}}')),
        "<p>Other clients take the URL as a Streamable HTTP server. It is also listed in the",
        " <a href='https://registry.modelcontextprotocol.io' rel=noopener>MCP Registry</a> as",
        " <code>dev.mojourney/census</code>.</p>",
        "<h2>Tools</h2><ul>",
        _tool("search_repos", "repos whose name, topics or description match, then those related by meaning."),
        _tool("list_repos", "the Repos table: sorted and filtered by Mojo version, activity or category."),
        _tool("get_repo", "one repo: lines of Mojo, Mojo version, dependencies, migrations and releases."),
        _tool("similar_repos", "the repos most like one repo."),
        _tool("version_adoption", "how many repos are on each Mojo version, month by month."),
        _tool("overview", "the census in numbers: repos, commits and lines of Mojo, and what is rising."),
        "</ul>",
        "<h2>Try asking</h2><ul>",
        "<li>Is there a Mojo library for TOML, and which Mojo version does it need?</li>",
        "<li>Which Mojo repos are most like magmalake/parquet.mojo?</li>",
        "<li>How fast are repos moving to the newest Mojo version?</li>",
        "</ul>",
        "<h2>Other ways in</h2>",
        "<p><a href='/llms.txt'>/llms.txt</a> lists every page and JSON endpoint, and",
        " <a href='/llms-full.txt'>/llms-full.txt</a> has the How it works pages as text.",
        " The JSON under <a href='/api/repos'>/api/</a> is the same data without MCP.</p>",
        "<h2>Limits and what is logged</h2>",
        "<p>Up to 60 tool calls a minute from one client. Each request is counted with its",
        " client's name and the tool's arguments, cut short; no IP address is kept.</p>",
        "</div>",
    )
    return _page("Use with AI", h^, "ai", description=page_line("/ai"))


def registry_auth(req: Request) raises -> Response:
    """`/.well-known/mcp-registry-auth`: the MCP Registry's HTTP proof that
    mojourney.dev publishes `dev.mojourney/census`."""
    var resp = Response(status=200, reason="OK", body=List[UInt8](String(REGISTRY_AUTH, "\n").as_bytes()))
    resp.headers.set("Content-Type", "text/plain; charset=utf-8")
    resp.headers.set("Cache-Control", EDGE_CACHE)
    return resp^
