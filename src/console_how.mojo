"""The console's How it works pages: `/how`, the pipelines, machines and
tables with a Mermaid diagram, `/how/optimizations`, how the pipelines got
faster, and `/how/changelog`, CHANGELOG.md."""

from std.os import getenv

from flare.http import Request, Response, html_escape
from changelog import changelog_html
from howimage import HETZNER_SERVER_WEBP, LINEAGE_DARK_WEBP, LINEAGE_LIGHT_WEBP

from console_layout import _nav, _page
from console_pages import page_line


comptime MORCA_DOCS = "https://mlake.dev/s/orca/docs"
comptime MORCA_UI = "https://orca.mojourney.dev"
comptime GH = "https://github.com/magmalake"
comptime GH_CENSUS = "https://github.com/morca-dev/census"
comptime GH_MORCA = "https://github.com/morca-dev/morca"

comptime HOW_LEAD = (
    "<div class=prose><p class=lead>Mojourney, the Mojo ecosystem census, is a"
    " handful of pipelines and this site, all Mojo. The pipelines run on <a href='"
    + MORCA_DOCS
    + "' rel=noopener>morca</a>, magmalake's pipeline orchestrator, and write"
    " Apache Iceberg tables to Hetzner Object Storage (S3-compatible) with <a"
    " href='"
    + GH
    + "/iceberg.mojo' rel=noopener>iceberg.mojo</a> and <a href='"
    + GH
    + "/parquet.mojo' rel=noopener>parquet.mojo</a>; this site reads the"
    " tables. The story behind it is in <a"
    " href='https://mlake.dev/blog/introducing-mojourney'"
    " rel=noopener>Introducing Mojourney</a>.</p></div>"
)

comptime DIAGRAM = """flowchart TB
  gha([GH Archive])
  api([GitHub API])
  git([git repositories])
  subgraph server [Hetzner CAX21]
    sched[morca scheduler and UI, Postgres]
    local[gharchive, mojo_repos, mojo_stats]
    sched -. starts .-> local
  end
  subgraph mac [Mac: morca remote worker]
    remote[mojo_history, mojo_versions, mojo_activity]
  end
  lake[(Iceberg tables in Hetzner Object Storage)]
  site([mojourney.dev])
  gha & api --> local
  git --> remote
  remote -. claims runs over HTTPS .-> sched
  local & remote --> lake
  lake -- read by --> site
  class local,remote pipe
  class lake ice
  class gha,api,git,site ext
"""
"""The machines, the pipelines on them and where the data goes, as Mermaid. The page has it in
a `<pre class=mermaid>` (escaped), which `MERMAID_JS` draws; without
JavaScript it reads as text."""

comptime MERMAID_JS = (
    "<script type=module>"
    "import mermaid from"
    " 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs';"
    "const css=getComputedStyle(document.documentElement),v=(n)=>css.getPropertyValue(n).trim();"
    "const dark=matchMedia('(prefers-color-scheme: dark)').matches;"
    "mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'base',"
    "darkMode:dark,fontFamily:'ui-sans-serif,system-ui,sans-serif',"
    "flowchart:{useMaxWidth:false,htmlLabels:true,curve:'basis',"
    "nodeSpacing:24,rankSpacing:36},"
    "themeVariables:{background:v('--surface'),primaryColor:v('--surface'),"
    "primaryTextColor:v('--text'),primaryBorderColor:v('--border-strong'),"
    "lineColor:v('--faint'),textColor:v('--muted'),clusterBkg:v('--surface-2'),"
    "clusterBorder:v('--border'),edgeLabelBackground:v('--surface'),"
    "fontSize:'13px'}});"
    "await mermaid.run({querySelector:'pre.mermaid'});"
    "</script>"
)

comptime HOW_PIPELINES = (
    "<div class=prose>"
    "<p class='mute note'>Rounded boxes are the sources and this site,"
    " rectangles the pipelines and morca, cylinders storage; dotted arrows are"
    " morca starting runs, on the server itself and on the Mac, which claims"
    " them over HTTPS. Each pipeline and table is under <a href='#tables'>The"
    " tables</a>. On a narrow screen, scroll it sideways.</p>"
    "<h2>The pipelines</h2><ul><li><a href='"
    + MORCA_UI
    + "/pipelines/gharchive' rel=noopener>gharchive</a> loads <a"
    " href='https://www.gharchive.org' rel=noopener>GH Archive</a>, every public"
    " GitHub event an hour at a time, daily at 03:00 UTC for the day before. Each"
    " hour is a <a href='https://mlake.dev/s/dista/docs' rel=noopener>dista</a>"
    " task that downloads, gunzips and parses the hour as it streams in, and"
    " builds the hour's rows of <code>gharchive.candidates</code> (events that"
    " hint at Mojo), <code>gharchive.repo_hour</code> (event counts per"
    " repository, person and hour) and <code>gharchive.releases</code> from"
    " each hour as it is parsed; the step commits those three tables once a"
    " day. The raw events are kept, as Parquet files of"
    " <code>gharchive.events</code> committed an hour at a time, only when"
    " <code>GHARCHIVE_EVENTS</code> is on. It is filling every day since 2023-01-01, one"
    " day a run, oldest first, in about 1.5 to 3 minutes a day. Each hour's"
    " download has timeouts (for connecting, for a stalled read and for the whole"
    " hour) and up to four retries with backoff.</li>"
    "<li>gharchive_index, a one-off run by hand, builds those three tables from"
    " <code>gharchive.events</code> for the days loaded before gharchive wrote"
    " them (days whose raw events were kept).</li>"
    "<li><a href='"
    + MORCA_UI
    + "/pipelines/mojo_repos' rel=noopener>mojo_repos</a> is a sensor on"
    " <code>gharchive.candidates</code>: for each new day it adds the repos"
    " GitHub's search says are in Mojo (created that day, or pushed lately),"
    " since GH Archive's recent hours lack the push events that named most of"
    " them, asks the GitHub API"
    " about the candidates it hasn't checked before and keeps the Mojo ones in"
    " <code>mojo.repos</code>, and every answer in"
    " <code>mojo.checked</code>.</li>"
    "<li><a href='"
    + MORCA_UI
    + "/pipelines/mojo_history' rel=noopener>mojo_history</a> is keyed by"
    " repository, 50 a run, and starts when <code>mojo.repos</code> gains some:"
    " each is cloned and its full first-parent history read, the Mojo files and"
    " lines at each commit into <code>mojo.commits</code>, each change of Mojo"
    " version in its lock file into <code>mojo.migrations</code>, and its git"
    " tags into <code>mojo.tags</code>.</li>"
    "<li><a href='"
    + MORCA_UI
    + "/pipelines/mojo_versions' rel=noopener>mojo_versions</a>, keyed the same"
    " way, reads the manifests at each repository's HEAD (<code>pixi.toml</code>,"
    " <code>mojoproject.toml</code>, <code>pyproject.toml</code>,"
    " <code>requirements.txt</code>, <code>recipe.yaml</code>): the Mojo version"
    " they state into <code>mojo.repo_versions</code>, and the dependencies they"
    " declare into <code>mojo.repo_deps</code>. From those the site shows what each"
    " repo <em>depends on</em> and which census repos it is <em>used by</em>.</li>"
    "<li><a href='"
    + MORCA_UI
    + "/pipelines/mojo_activity' rel=noopener>mojo_activity</a> counts each"
    " repo's events per day from <code>gharchive.repo_hour</code>, with no API"
    " calls: stars, forks, releases, issues and pull requests opened, pushes and"
    " people, into <code>mojo.activity</code> and <code>mojo.releases</code>. A"
    " repo found today is read back over every day already loaded, so its history"
    " is complete.</li>"
    "<li><a href='"
    + MORCA_UI
    + "/pipelines/mojo_stats' rel=noopener>mojo_stats</a> asks the GitHub API"
    " about every repo each day (one request each) and keeps the stars, forks,"
    " issues and topics day by day in <code>mojo.repo_stats</code>. It also asks"
    " once about each repo a census repo depends on outside the census, and keeps"
    " in <code>mojo.dep_forks</code> which of them are forks, and of what: a repo"
    " that uses a fork of a library counts as one of the library's users. A"
    " republish that isn't a GitHub fork counts the same way when the census's"
    " own short list names it (<code>republishes()</code> in"
    " <code>src/deps.mojo</code>: magmalake/flare_mlake of ehsanmok/flare,"
    " json_mlake of ehsanmok/json, mozz_mlake of ehsanmok/mozz), an entry"
    " added only when the republish's description or README says what it"
    " republishes.</li></ul>"
    "<p>Clones, in mojo_history and mojo_versions, have a time limit, retries"
    " with backoff and a minimum transfer speed; a repository that still fails"
    " is logged and skipped for that run.</p>"
    "<h2>morca and the site</h2>"
    "<p>morca's scheduler starts each run: on a schedule (gharchive daily,"
    " mojo_stats daily too), when a table it watches gains a snapshot (the sensors"
    " and the keyed pipelines), or to fill days not run yet. It keeps the runs,"
    " their steps, attempts and logs in Postgres, and its UI at <a href='"
    + MORCA_UI
    + "/runs' rel=noopener>orca.mojourney.dev</a> shows every run, with its steps,"
    " logs, machines and the tables it wrote.</p>"
    "<p>The site is a Mojo HTTP server, built on <a href='https://github.com/ehsanmok/flare'"
    " rel=noopener>flare</a>, that reads the Iceberg tables itself, with"
    " no database in between. Every 30 minutes it looks at the tables' current"
    " snapshots and rebuilds its pages in memory when one has moved, and at least"
    " once a day, as the 30-day windows slide. The <em>Rising</em> list ranks"
    " repos by what they gained in the last 30 days: stars + 3 &times; forks + 5"
    " &times; the census repos that use it.</p>"
    "<h2>It runs on a tiny machine</h2>"
    "<p>The site, Postgres, the morca scheduler and its UI, and most pipelines'"
    " runs and workers run on one Hetzner CAX21: an ARM server with 4 vCPU,"
    " 8 GB of RAM, an 80 GB disk and a 50 GB volume, for a fixed &euro;12.49 a"
    " month. The warehouse, every table above, is in Hetzner Object Storage. An"
    " hour of GH Archive in flight takes about 450 MB, so the import works on a"
    " few hours at a time.</p>"
    "<p>The git-heavy pipelines, <code>mojo_history</code>,"
    " <code>mojo_versions</code> and <code>mojo_activity</code>, run on a second"
    " machine, an Apple-silicon Mac, as a morca remote worker: it claims their"
    " runs over HTTPS and needs no database access. Everything else stays on the"
    " CAX21.</p>"
    "<figure class=shot><img src='"
    + HETZNER_SERVER_WEBP
    + "' width=1200 height=232 alt='The server in"
    " the Hetzner console: 4 vCPU, 8 GB RAM, 80 GB local disk plus one 50 GB"
    " volume, 0 of 20 TB outgoing traffic used, 12.49 a month.'><figcaption>The"
    " server's summary in the Hetzner console, which shows the price with a $"
    " sign: it is &euro;12.49 a month.</figcaption></figure>"
    "<h2 id=tables>The tables</h2>"
    "<p>Each pipeline and the Iceberg tables it reads and writes, as morca's <a"
    " href='"
    + MORCA_UI
    + "/datasets' rel=noopener>Datasets</a> page draws them from the code.</p>"
    "<figure class='shot lineage'><a href='"
    + MORCA_UI
    + "/datasets' rel=noopener><picture><source media='(prefers-color-scheme:"
    " dark)' srcset='"
    + LINEAGE_DARK_WEBP
    + "'><img src='"
    + LINEAGE_LIGHT_WEBP
    + "' width=436 height=1033 loading=lazy alt='The census lineage: gharchive"
    " writes gharchive.events, gharchive_index the candidates, releases and"
    " repo_hour tables, mojo_repos reads them into mojo.repos and mojo.checked,"
    " and mojo_history, mojo_stats, mojo_versions and mojo_activity write the"
    " other mojo tables.'></picture></a><figcaption>Pipelines in orange, tables"
    " in teal.</figcaption></figure>"
    "<h2>More</h2>"
    "<p>The morca docs cover <a href='"
    + MORCA_DOCS
    + "/build' rel=noopener>writing a pipeline</a>, <a href='"
    + MORCA_DOCS
    + "/run' rel=noopener>running it</a>, <a href='"
    + MORCA_DOCS
    + "/ui' rel=noopener>the web UI</a> and <a href='"
    + MORCA_DOCS
    + "/debug' rel=noopener>debugging a failed run</a>; the census's own code"
    " is <a href='"
    + GH_CENSUS
    + "' rel=noopener>morca-dev/census</a>, and the <a"
    " href='https://mlake.dev/getting-started/' rel=noopener>getting-started"
    " guide</a> builds it from scratch.</p>"
    "<p>How the pipelines got faster, with the measurements, is on the <a"
    " href='/how/optimizations'>Optimizations</a> tab.</p></div>"
)


def _how_head(current: String) -> String:
    """The title and the tabs shared by the two How it works pages."""
    return String(
        "<h1>How it works</h1><nav class=tabs aria-label='How it works'>",
        _nav("/how", "Overview", current == "overview"),
        _nav("/how/optimizations", "Optimizations", current == "optimizations"),
        _nav("/how/changelog", "Changelog", current == "changelog"),
        "</nav>",
    )


def _link(href: String, text: String) -> String:
    return String("<a href='", href, "' rel=noopener>", text, "</a>")


def _change(
    what: String, did: String, measured: String, prs: String
) -> String:
    """A row of the changes table; every cell is HTML."""
    return String(
        "<tr><td class=what>", what, "</td><td class='what'>", did,
        "</td><td class=soft>", measured, "</td><td>", prs, "</td></tr>",
    )


def _stage(name: String, before: String, after: String) -> String:
    return String(
        "<tr><td>", name, "</td><td class=num>", before, "</td><td class=num>", after, "</td></tr>"
    )


def how(req: Request) raises -> Response:
    return _page(
        "How it works",
        String(
            _how_head("overview"),
            HOW_LEAD,
            "<figure class=diagram aria-label='The pipelines and the tables between them'>",
            "<pre class=mermaid>",
            html_escape(DIAGRAM),
            "</pre></figure>",
            HOW_PIPELINES,
            MERMAID_JS,
        ),
        "how",
        description=page_line("/how"),
    )


def changelog(req: Request) raises -> Response:
    """CHANGELOG.md, read on each request from `CENSUS_CHANGELOG` (the image's
    /opt/morca/CHANGELOG.md; CHANGELOG.md in the working directory when unset)."""
    var url = String(GH_CENSUS, "/blob/main/CHANGELOG.md")
    var text = String()
    try:
        with open(getenv("CENSUS_CHANGELOG", "CHANGELOG.md"), "r") as f:
            text = f.read()
    except:
        pass
    var h = _how_head("changelog")
    h.write(
        "<div class=prose><p class=lead>What changed in each release of the census, newest",
        " first, as in ",
        _link(url, "CHANGELOG.md"),
        ". Each entry links its pull request.</p>",
    )
    if text == "":
        h.write("<p>The changelog isn't on this server; it's on ", _link(url, "GitHub"), ".</p>")
    else:
        h.write(changelog_html(text, String(GH_CENSUS, "/pull")))
    h.write("</div>")
    return _page("Changelog", h^, "how", description=page_line("/how/changelog"))


def _census_pr(n: Int) -> String:
    return _link(String(GH_CENSUS, "/pull/", n), String("#", n))


def optimizations(req: Request) raises -> Response:
    var pr_census = String(GH_CENSUS, "/pull/4")
    var pr_parquet = String(GH, "/parquet.mojo/pull/59")
    var pr_ice71 = String(GH, "/iceberg.mojo/pull/71")
    var dash = String("<span class=mute>&ndash;</span>")
    var h = _how_head("optimizations")
    h.write(
        "<p class=lead>The census runs on one Hetzner CAX21 (4 ARM vCPUs, 8 GB, &euro;12.49 a month),",
        " with a Mac as a morca remote worker for the git histories. There gharchive loads a day of",
        " GH Archive in about 1.5&ndash;3 minutes, peaking at 731 MB at the median and 801 MB at most,",
        " with about 2.4 cores busy (",
        _link(String(MORCA_UI, "/pipelines/gharchive"), "its Resources card"),
        ", over the last 20 runs). It keeps only the index tables it derives from each hour, not the",
        " raw events, which were 97% of the bucket at about 1.1 GB a day. The backfill finished all",
        " 1,407 days, 2023-01-01 to 2026-11-07, on 2026-11-08.</p>",
        "<h2>How it got there</h2>",
        "<p class=sub>Since the first runs on AWS, newest last; each row links its pull request,",
        " whose description has the measurements.</p>",
        "<div class=tbl><table><thead><tr><th>Change</th><th>What it did</th>",
        "<th>Measured</th><th>PR</th></tr></thead><tbody>",
        _change(
            "Bounded table history",
            "<code>gharchive.events</code> keeps a week of snapshots and every table its last 100"
            " metadata files; <code>morca_maintain</code> expires the rest every day.",
            dash,
            _census_pr(20),
        ),
        _change(
            "Index events while parsing",
            "Each hour task writes <code>candidates</code>, <code>repo_hour</code> and"
            " <code>releases</code> from the events it parses, instead of a later pass over"
            " <code>gharchive.events</code>.",
            "Same rows as the old path for all 143,015 repos of 2023-01-10",
            _census_pr(21),
        ),
        _change(
            "Index tables committed once a day",
            "The three index tables get one commit each at the end of the day, with all the hours'"
            " files; only <code>gharchive.events</code> still committed every hour.",
            "Removes three of four hourly commits, which took about 1.7 s an hour (41 s of an 81 s day on AWS)",
            _census_pr(24),
        ),
        _change(
            "Smaller Parquet",
            "Events sorted by (repo, type) and compressed with zstd 9; <code>repo_hour</code> merged"
            " into one sorted file a day.",
            "Events 311 to 227 bytes a row (&minus;27%), <code>repo_hour</code> &minus;24% over 3 merged"
            " hours; the hour task 2.35 to 2.80 s",
            _census_pr(29),
        ),
        _change(
            "An hour in about 450 MB",
            "A file's rows in fixed 4 MB string pieces, a sort of row numbers only, 16 MB row groups,"
            " and the download memory-mapped and released as it is decoded.",
            "A busy 2023 hour alone 965 to 525 MB; a day 1,969 MB and 52.9 s with 2 hours in flight,"
            " 1,826 MB and 38.9 s with 4 (Linux, 4 vCPU, 8 GB)",
            String(_census_pr(44), " (", _link(String(GH_CENSUS, "/issues/37"), "#37"), ")"),
        ),
        _change(
            "4 hours in flight",
            "gharchive runs 4 hours at a time on the CAX21 instead of 2.",
            "1.8 GB at peak on a busy 2023 day, 26% faster than 2 (from #44)",
            _census_pr(59),
        ),
        _change(
            "Index only (<code>GHARCHIVE_EVENTS=off</code>)",
            "Stops writing <code>gharchive.events</code>, 97% of the bucket at about 1.1 GB a day; the"
            " index tables are unchanged.",
            "An hour in flight about 200 MB instead of 450 MB; the backfill went from about 22 to"
            " 58&ndash;65 days an hour on the CAX21 with two fill runs",
            _census_pr(70),
        ),
        _change(
            "Days with missing hours",
            "A day loads without the hours GH Archive never published (a 404 more than 48 hours old),"
            " so the backfill could finish.",
            dash,
            _census_pr(78),
        ),
        "</tbody></table></div>",
        "<h2>The first runs, on AWS</h2>",
        "<p>Each hour's task was bound to one of the worker's four cores, with the Parquet write its",
        " largest stage. These changes spread the work over the cores and",
        " stopped copying it.</p>",
        "<h3>One gharchive hour on AWS</h3>",
        "<p class=sub>c7g.xlarge workers, about 85,000 events an hour, median of 24 hours.</p>",
        "<div class=tbl><table><thead><tr><th>Stage</th><th class=num>Before (",
        _link(String(MORCA_UI, "/runs/36"), "run 36"), ")</th><th class=num>After (",
        _link(String(MORCA_UI, "/runs/48"), "run 48"), ")</th></tr></thead><tbody>",
        _stage("task", "1,094 ms", "680 ms"),
        _stage("download", "172 ms", "130 ms"),
        _stage("gunzip", "210 ms", "154 ms"),
        _stage("parse", "160 ms", "134 ms"),
        _stage("write", "570 ms", "256 ms"),
        _stage("commit", "486 ms", "683 ms"),
        "</tbody></table></div>",
        "<p class='mute note'>Commit time grew with the table's snapshot count: ",
        _link(String(MORCA_UI, "/runs/133"), "run 133"),
        " measured 1,207 ms for the commit, at about 889 snapshots, with the other stages unchanged.",
        " Bounded history (", _census_pr(20), ") stopped the growth, the index tables now commit once a",
        " day (", _census_pr(24), "), and with the events off (", _census_pr(70), ") a day makes just",
        " those three commits.</p>",
        "<h3>The changes</h3><div class=tbl><table><thead><tr><th>Change</th><th>What it did</th>",
        "<th>Measured (Apple M4)</th><th>PR</th></tr></thead><tbody>",
        _change(
            "mojo-census #4",
            "Streams each hour through gunzip and parsing as it downloads, and writes Parquet on the workers.",
            _link(pr_census + "#six-hours-local-server", "Six hours locally, 10.3 s to 4.5 s with 4 tasks"),
            _link(pr_census, "#4"),
        ),
        _change(
            "parquet #59",
            "Streams row groups, splits string pages by size, encodes pages on threads.",
            _link(
                pr_parquet + "#measurements-apple-m4-mojo-120",
                "50,000-row batch encode 198 to 81 ms (4 threads), peak 828 to 463 MB",
            ),
            _link(pr_parquet, "#59"),
        ),
        _change(
            "iceberg #71",
            "Writes a batch without copying it.",
            _link(
                pr_ice71 + "#measurements-apple-m4-mojo-120",
                "One hour 838&ndash;855 to 783&ndash;804 ms, peak 1.30&ndash;1.51 to 0.96&ndash;0.97 GB",
            ),
            _link(pr_ice71, "#71"),
        ),
        _change(
            "iceberg #72",
            "Writes through the streaming writer on every core.",
            "One hour to 375 ms, peak about 0.5 GB (with #59, 4 threads)",
            _link(String(GH, "/iceberg.mojo/pull/72"), "#72"),
        ),
        _change(
            "deflate #10, #12",
            "Streaming inflate, and a faster decode loop.",
            _link(
                String(GH, "/deflate.mojo/pull/12#numbers-apple-m4"),
                "Gunzip of an hour 553 to 336 ms (1.46 GB/s)",
            ),
            String(
                _link(String(GH, "/deflate.mojo/pull/10"), "#10"), ", ",
                _link(String(GH, "/deflate.mojo/pull/12"), "#12"),
            ),
        ),
        _change(
            "iceberg #70 + morca #114",
            "Workers hand their data files to the step to commit (<code>append_files</code>), which removes the census's own DataFile codec.",
            "<span class=mute>&ndash;</span>",
            String(
                _link(String(GH, "/iceberg.mojo/pull/70"), "iceberg #70"), ", ",
                _link(String(GH_MORCA, "/pull/114"), "morca #114"),
            ),
        ),
        "</tbody></table></div>",
    )
    return _page("Optimizations", h^, "how", description=page_line("/how/optimizations"))
