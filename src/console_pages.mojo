"""The console's pages and JSON endpoints as one list, each with a line on
what it shows: the pages' meta descriptions, `/llms.txt` and `/sitemap.xml`
are all written from it, and a test checks that every entry is routed."""


@fieldwise_init
struct SitePage(Copyable, ImplicitlyCopyable):
    """A page or JSON endpoint of the console."""

    var path: String
    """Its path; `/repos/:owner/:name` and `/api/repos/:owner/:name` stand for
    one repo's."""
    var name: String
    """What `/llms.txt` calls it."""
    var line: String
    """One sentence on what it shows: the page's meta description and its
    line in `/llms.txt`."""
    var json: String
    """The JSON with the same data (a page's `<link rel=alternate>`), or ""."""


comptime REPO_PAGE = "/repos/:owner/:name"
comptime REPO_JSON = "/api/repos/:owner/:name"


def site_pages() -> List[SitePage]:
    """The HTML pages, in the order the nav and `/llms.txt` list them."""
    return [
        SitePage(
            "/",
            "Overview",
            (
                "How many public GitHub repos contain Mojo, which Mojo versions they use,"
                " and how lines of Mojo, commits and repos grew month by month."
            ),
            "/api/overview",
        ),
        SitePage(
            "/repos",
            "Repos",
            (
                "Every Mojo repo the census found, by lines of Mojo, files, stars, forks,"
                " age or dependents, filterable by Mojo version, activity and category."
            ),
            "/api/repos",
        ),
        SitePage(
            REPO_PAGE,
            "A repo",
            (
                "One repo: its lines of Mojo over time, Mojo version, dependencies,"
                " migrations, releases, stars per month, issues and similar repos."
            ),
            REPO_JSON,
        ),
        SitePage(
            "/migrations",
            "Migrations",
            "The migrations from one Mojo version to the next, per month, and how many repos were on each version.",
            "/api/versions",
        ),
        SitePage(
            "/live",
            "Live",
            "Commits to census repos' default branches in the last two days, seen within about 20 minutes of the push.",
            "/api/live",
        ),
        SitePage(
            "/how",
            "How it works",
            "How the census is built: the Mojo pipelines, the Iceberg tables between them and when each runs.",
            "",
        ),
        SitePage(
            "/how/optimizations",
            "Optimizations",
            "How the census pipelines got faster, with the measurements and the pull requests.",
            "",
        ),
        SitePage(
            "/ai",
            "Use with AI",
            "How to add Mojourney's MCP server to Claude, Cursor or VS Code, and the tools it gives an agent.",
            "",
        ),
        SitePage(
            "/how/changelog",
            "Changelog",
            "What changed in each release of the census.",
            "",
        ),
    ]


def api_pages() -> List[SitePage]:
    """The JSON endpoints, the way to read the numbers behind the pages."""
    return [
        SitePage(
            "/api/overview",
            "Overview numbers",
            (
                "The overview's numbers: repos, commits and lines of Mojo now and 30 days"
                " ago, repos per Mojo version, monthly series, rising, most active and most"
                " depended-on repos, and what the lake holds."
            ),
            "",
        ),
        SitePage(
            "/api/repos",
            "All repos",
            (
                "Every repo with its description, topics, stars, forks, license, lines of"
                " Mojo, Mojo version, tooling, dependencies and category; `?q=` keeps the"
                " ones /api/search finds."
            ),
            "",
        ),
        SitePage(
            "/api/search?q=toml",
            "Search",
            (
                "The repos whose name, GitHub topics or description match `q`, then those"
                ' related by meaning; each row as in /api/repos with `match` ("text" or'
                ' "meaning").'
            ),
            "",
        ),
        SitePage(
            REPO_JSON,
            "One repo",
            "One repo with its commits, migrations, monthly activity, releases, issues and similar repos.",
            "",
        ),
        SitePage(
            "/api/versions",
            "Mojo versions per month",
            "How many repos were on each Mojo version, month by month.",
            "",
        ),
        SitePage(
            "/api/live",
            "Live commits",
            "The commits the Live page shows, with when each was seen.",
            "",
        ),
    ]


def page_line(path: String) -> String:
    """The line `site_pages` has for `path`, else ""."""
    for p in site_pages():
        if p.path == path:
            return p.line
    return String()


def page_json(path: String) -> String:
    """The JSON `site_pages` has for `path`, else ""."""
    for p in site_pages():
        if p.path == path:
            return p.json
    return String()
