"""The console's JSON under `/api/`: the overview, the repos, a search, the
migrations per month and one repo with its commits, migrations, activity,
releases and similar repos."""

from flare.http import Request, Response, internal_error, not_found, ok_json, redirect

from days import day_text
from jscan import micros_to_iso
from committype import typed_commits
from contributors import RepoContributors
from model import Library, stored_total
from overview import ARCHIVE_START, RISING_FORK_WEIGHT, RISING_USED_BY_WEIGHT, archive_days_due
from search import url_decode, version_bucket, version_family

from console_cache import Cache
from console_list import _matches, meaning_hits
from similar import Neighbor
from issues import IssueRow
from categories import CATEGORIES_VERSION


def _q(s: String) -> String:
    """A JSON string."""
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
        elif cp == "\r":
            out += "\\r"
        else:
            out += cp
    out += '"'
    return out^


def overview_json(req: Request, c: Cache) raises -> Response:
    ref ov = c.ov
    var out = String(
        '{"as_of":', _q(micros_to_iso(c.sources.as_of_ms * 1000)),
        ',"days_loaded":', c.sources.days, ',"first_day":', _q(c.sources.first_day),
        ',"last_day":', _q(c.sources.last_day), ',"repos":', ov.repos,
        ',"repos_with_history":', ov.with_history, ',"repos_30d_ago":', ov.repos_30_ago,
        ',"coverage":{"repos":', ov.repos, ',"repos_with_history":', ov.with_history,
        ',"gharchive_days_loaded":', min(c.sources.archive_days, archive_days_due(c.built_day)),
        ',"gharchive_days_due":', archive_days_due(c.built_day),
        ',"gharchive_since":', _q(day_text(Int64(ARCHIVE_START))),
        ',"gharchive_until":', _q(day_text(Int64(c.built_day - 1))), "}",
        ',"commits":', ov.commits, ',"commits_30d":', ov.commits_30,
        ',"commits_prev_30d":', ov.commits_prev_30, ',"mojo_lines":', ov.lines,
        ',"mojo_lines_30d_ago":', ov.lines_30_ago, ',"new_repos_this_month":', ov.new_this_month,
        ',"new_repos_last_month":', ov.new_last_month, ',"active_repos":', ov.active,
        ',"input":{',
    )
    # What the lake holds, by the tables' current snapshots (`read_stored`).
    var all = stored_total(c.sources.stored)
    out.write(
        '"records":', all.records, ',"bytes":', all.bytes, ',"gharchive_days":', c.sources.days,
        ',"gharchive_event_days":', c.sources.event_days, ',"tables":[',
    )
    for i in range(len(c.sources.stored)):
        ref st = c.sources.stored[i]
        out.write(
            "," if i > 0 else "", '{"table":', _q(st.table), ',"records":', st.records,
            ',"bytes":', st.bytes, "}",
        )
    out += ']},"buckets":['
    for i in range(len(ov.buckets)):
        if i > 0:
            out += ","
        out.write(
            '{"bucket":', _q(ov.buckets[i]), ',"repos":', ov.bucket_repos[i],
            ',"active_repos":', ov.bucket_active[i],
            String(',"unread":', ov.unread) if ov.buckets[i] == "unknown" else String(), "}",
        )
    out += '],"estimated_buckets":['
    for i in range(len(ov.est_buckets)):
        if i > 0:
            out += ","
        out.write(
            '{"bucket":', _q(ov.est_buckets[i]), ',"repos":', ov.est_bucket_repos[i],
            ',"active_repos":', ov.est_bucket_active[i],
            String(',"unread":', ov.est_unread) if ov.est_buckets[i] == "unknown" else String(), "}",
        )
    out += '],"families":['
    for i in range(len(ov.families)):
        if i > 0:
            out += ","
        out.write(
            '{"family":', _q(ov.families[i]), ',"repos":', ov.family_repos[i],
            ',"active_repos":', ov.family_active[i],
            String(',"unread":', ov.unread) if ov.families[i] == "unknown" else String(), "}",
        )
    out.write(
        '],"months":[',
    )
    for k in range(len(ov.months)):
        if k > 0:
            out += ","
        out.write(
            '{"month":', _q(ov.months[k]), ',"mojo_lines":', ov.lines_series[k],
            ',"repos":', ov.repos_series[k], ',"commits":', ov.commits_series[k],
            ',"tooling":{"none":', ov.tool_none[k], ',"magic":', ov.tool_magic[k],
            ',"pixi":', ov.tool_pixi[k],
            ',"bazel":', ov.tool_bazel[k], ',"python":', ov.tool_python[k], "}",
        )
        if k < len(ov.issues_opened):
            out.write(
                ',"issues":{"opened":', ov.issues_opened[k], ',"closed":', ov.issues_closed[k],
                ',"prs_opened":', ov.prs_opened[k], ',"prs_merged":', ov.prs_merged[k], "}",
            )
        out += "}"
    out += '],"rising":['
    for i in range(len(c.rising)):
        if i > 0:
            out += ","
        out.write(
            '{"repo":', _q(c.rising[i]), ',"stars_30d":', c.rising_gain[i],
            ',"forks_30d":', c.rising_forks[i], ',"used_by":', c.rising_used_by[i],
            ',"score":', c.rising_score[i], ',"stars":', c.rising_stars[i], "}",
        )
    out.write(
        '],"rising_weights":{"forks":', RISING_FORK_WEIGHT, ',"used_by":', RISING_USED_BY_WEIGHT,
        '},"most_depended_on":[',
    )
    for k in range(len(c.depended)):
        if k > 0:
            out += ","
        ref d = c.depended[k]
        out.write(
            '{"repo":', _q(d.name), ',"used_by":', d.used_by, ',"stars":', d.stars,
            ',"forks":', d.forks, ',"internal":', d.internal,
            ',"owner_group":', "true" if d.group else "false",
        )
        if d.group:
            var rs = List[String]()
            for m in d.members:
                rs.append(c.libs[m].repo)
            out.write(',"owner":', _q(d.owner), ',"repos":', _strs_json(rs))
        out += "}"
    out += '],"most_active":['
    for i in range(len(c.active_repos)):
        if i > 0:
            out += ","
        out.write(
            '{"repo":', _q(c.active_repos[i]), ',"commits_30d":', c.active_commits[i],
            ',"mojo_lines_30d":', c.active_lines[i], "}",
        )
    out += "]}"
    return ok_json(out)


def search_json(req: Request, c: Cache, qv: List[Float32] = List[Float32]()) raises -> Response:
    """The text matches, then the repos related by meaning; each with
    `match` (`text` or `meaning`) and, for meaning, `score` (the cosine)."""
    try:
        var q = String(url_decode(req.query_param("q")).strip())
        var out = String("[")
        if q.byte_length() > 0:
            var first = True
            var hits = _matches(q, c)
            for i in hits:
                if not first:
                    out += ","
                first = False
                var j = _lib_json(c.libs[i], c.categories[i] if i < len(c.categories) else String())
                out.write(String(j[byte = : j.byte_length() - 1]), ',"match":"text"}')
            for ref r in meaning_hits(c, qv, hits):
                if not first:
                    out += ","
                first = False
                var j = _lib_json(c.libs[r.index], c.categories[r.index] if r.index < len(c.categories) else String())
                out.write(String(j[byte = : j.byte_length() - 1]), ',"match":"meaning","score":', r.score, "}")
        out += "]"
        return ok_json(out)
    except e:
        return internal_error(String(e))


def _strs_json(items: List[String]) -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += _q(items[i])
    out += "]"
    return out^


def _source_name(source: String) -> String:
    """The source as the JSON names it: `lock`, `manifest`, `ci`, `docker`,
    `readme`, `file`, `repo`; mojo.commits keeps the file's name."""
    if source.endswith(".lock"):
        return String("lock")
    if source.endswith(".toml"):
        return String("manifest")
    return source


def _lib_json(l: Library, category: String = String()) -> String:
    return String(
        '{"repo":', _q(l.repo), ',"description":', _q(l.description),
        ',"created_at":', _q(micros_to_iso(l.created_at) if l.created_at else ""),
        ',"first_seen":', _q(micros_to_iso(l.first_seen)),
        ',"found_by":', _q(l.found_by), ',"stars":', l.stars,
        ',"forks":', l.forks, ',"license":', _q(l.license),
        ',"size_kb":', l.size_kb, ',"commits":', l.commits,
        ',"mojo_lines":', l.mojo_lines, ',"mojo_files":', l.mojo_files,
        ',"tooling":', _q(l.tooling), ',"packaging":', _q(l.packaging),
        ',"mojo_version":', _q(l.mojo_version),
        ',"version_source":', _q(_source_name(l.version_source)), ',"version_file":', _q(l.version_file),
        ',"version_estimate":', _q(l.version_estimate),
        ',"version_estimate_source":', _q("date" if l.version_estimate.byte_length() > 0 else ""),
        ',"topics":', _strs_json(l.topics),
        ',"stats_as_of":', _q(day_text(l.stats_as_of) if l.stats_as_of > 0 else ""),
        ',"open_issues":', l.open_issues, ',"watchers":', l.watchers,
        ',"archived":', "true" if l.archived else "false",
        ',"state":', _q(l.state), ',"renamed_to":', _q(l.renamed_to),
        ',"aliases":', _strs_json(l.aliases),
        ',"declared_deps":', "null" if l.declared_deps < 0 else String(l.declared_deps),
        ',"depends_on":', _strs_json(l.depends_on), ',"used_by":', _strs_json(l.used_by),
        ',"used_by_forks":', _strs_json(l.used_by_forks), ',"second_degree":', _strs_json(l.second_degree),
        ',"dependencies":', _strs_json(l.declared),
        ',"category":', _q(category) if category.byte_length() > 0 else "null", "}",
    )


def index_json(req: Request, c: Cache, qv: List[Float32] = List[Float32]()) raises -> Response:
    """Every repo; with `?q=`, only the ones `/api/search` finds (`search_json`)."""
    if String(url_decode(req.query_param("q")).strip()).byte_length() > 0:
        return search_json(req, c, qv)
    var out = String("[")
    var first = True
    for i in range(len(c.libs)):
        if not first:
            out += ","
        first = False
        out += _lib_json(c.libs[i], c.categories[i] if i < len(c.categories) else String())
    out += "]"
    return ok_json(out)


def versions_json(req: Request, c: Cache) raises -> Response:
    var out = String("[")
    var first = True
    for ref r in c.version_rows:
        if not first:
            out += ","
        first = False
        out.write(
            '{"month":', _q(r.month), ',"version":', _q(r.version), ',"bucket":',
            _q(version_bucket(r.version)), ',"family":', _q(version_family(r.version)),
            ',"libraries":', r.repos, "}",
        )
    out += "]"
    return ok_json(out)


def _issue_json(r: IssueRow) -> String:
    return String(
        '{"number":', r.number, ',"title":', _q(r.title), ',"state":', _q(r.state),
        ',"labels":', _strs_json(r.labels), ',"author":', _q(r.author),
        ',"comments":', r.comments, ',"created_at":', _q(micros_to_iso(r.created_at)),
        ',"updated_at":', _q(micros_to_iso(r.updated_at)),
        ',"closed_at":', _q(micros_to_iso(r.closed_at)) if r.closed_at > 0 else "null",
        ',"merged_at":', _q(micros_to_iso(r.merged_at)) if r.merged_at > 0 else "null", "}",
    )


def _contributors_json(x: RepoContributors) -> String:
    """`{"total":n,"months":[{"month":"2026-01","active":n,"new":n}]}`, the
    months with a commit only, oldest first."""
    var out = String('{"total":', x.total, ',"months":[')
    for i in range(len(x.months)):
        ref m = x.months[i]
        out.write("," if i > 0 else "", '{"month":', _q(m.month), ',"active":', m.active, ',"new":', m.new, "}")
    out += "]}"
    return out^


def repo_json(req: Request, c: Cache) raises -> Response:
    try:
        var repo = String(req.param("owner"), "/", req.param("name"))
        var found = c.find(repo)
        if not found:
            var moved = c.moved_to(repo)
            if moved.byte_length() > 0:
                return redirect(String("/api/repos/", moved), 301)
            return not_found(req.url)
        var data = c.data(repo)
        var out = String('{"library":', _lib_json(found.value(), c.category_of(repo)), ',"migrations":[')
        var first = True
        for ref m in data.ms:
            if not first:
                out += ","
            first = False
            out.write(
                '{"at":', _q(micros_to_iso(m.at)), ',"sha":', _q(m.sha), ',"kind":',
                _q(m.kind), ',"from":', _q(m.from_value), ',"to":', _q(m.to_value), "}",
            )
        out += '],"commits":['
        first = True
        var types = typed_commits(data.pts, data.ms)
        for i in range(len(data.pts)):
            ref p = data.pts[i]
            if not first:
                out += ","
            first = False
            out.write(
                '{"at":', _q(micros_to_iso(p.at)), ',"sha":', _q(p.sha),
                ',"mojo_lines":', p.lines, ',"tooling":', _q(p.tooling),
                ',"mojo_version":', _q(p.version), ',"subject":', _q(p.subject),
                ',"type":', _q(types[i].main), ',"secondary":[',
            )
            for k in range(len(types[i].secondary)):
                out.write("," if k > 0 else "", _q(types[i].secondary[k]))
            out.write(
                '],"typed_by":', _q(types[i].by), "}",
            )
        out += '],"activity":['
        first = True
        for ref a in data.acts:
            if not first:
                out += ","
            first = False
            out.write(
                '{"month":', _q(a.month), ',"stars":', a.stars, ',"forks":', a.forks,
                ',"releases":', a.releases, ',"issues_opened":', a.issues_opened,
                ',"prs_opened":', a.prs_opened, ',"pushes":', a.pushes,
                ',"days_active":', a.days_active, "}",
            )
        out += '],"releases":['
        first = True
        for ref x in data.rels:
            if not first:
                out += ","
            first = False
            out.write(
                '{"tag":', _q(x.tag), ',"name":', _q(x.name), ',"at":',
                _q(micros_to_iso(x.at) if x.at else ""), ',"prerelease":',
                "true" if x.prerelease else "false", ',"source":', _q(x.source),
                ',"commit":', _q(x.commit), ',"mojo_version":', _q(x.mojo_version), "}",
            )
        ref x = data.issues
        out.write(
            '],"issues":{"open_issues":', x.open_issues, ',"closed_issues":', x.closed_issues,
            ',"open_prs":', x.open_prs, ',"merged_prs":', x.merged_prs, ',"closed_prs":', x.closed_prs,
            ',"recent_open_issues":[',
        )
        first = True
        for ref r in x.issues:
            if not first:
                out += ","
            first = False
            out.write(_issue_json(r))
        out += '],"recent_prs":['
        first = True
        for ref r in x.prs:
            if not first:
                out += ","
            first = False
            out.write(_issue_json(r))
        out.write(']},"contributors":', _contributors_json(data.contributors), ',"similar":[')
        first = True
        for ref n in c.similar.get(repo, List[Neighbor]()):
            if not first:
                out += ","
            first = False
            out.write('{"repo":', _q(n.repo), ',"score":', n.score, "}")
        out.write(
            '],"similar_from":{"model":', _q(c.embed_model), ',"model_rev":', _q(c.embed_rev),
            ',"snapshot":', c.embed_snapshot, ',"categories_version":', CATEGORIES_VERSION, "}}",
        )
        return ok_json(out)
    except e:
        return internal_error(String(e))
