"""The console's Migrations page (`/migrations`), from the body the cache
built (console_migrations_body)."""

from flare.http import Request, Response, internal_error

from console_cache import Cache
from console_layout import _empty, _page
from console_migrations_body import _migrations_head
from console_pages import page_json, page_line


def migrations_page(req: Request, c: Cache) raises -> Response:
    try:
        var h = String(
            _migrations_head(),
        )
        if len(c.version_rows) == 0:
            h.write(
                _empty(
                    "No migrations yet",
                    "A migration shows up here once a repo's lock file has been read at"
                    " more than one commit and the Mojo version changed between them."
                    " The lake is still filling.",
                )
            )
            return _page("Migrations", h^, "migrations", description=page_line("/migrations"), alternate=page_json("/migrations"))
        return _page(
            "Migrations", c.migrations_body.copy(), "migrations", description=page_line("/migrations"),
            alternate=page_json("/migrations"),
        )
    except e:
        return internal_error(String(e))
