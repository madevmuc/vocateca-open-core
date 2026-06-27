"""Local HTTP/JSON API (roadmap 10.2).

A minimal **localhost-only**, token-guarded control surface built on the stdlib
``http.server`` — no extra dependency. Read endpoints (shows / status / queue)
plus queue pause/resume. The routing is a pure function (``handle_request``) so
it's unit-testable without binding a socket; ``serve`` wraps it in an
``HTTPServer`` bound to 127.0.0.1.

Security: bound to loopback only, every request must present the shared token
(``Authorization: Bearer <token>`` or ``?token=``). It exposes the same surface
as the CLI — no new capability beyond what a local user already has.
"""

from __future__ import annotations

import json
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer

logger = logging.getLogger("paragraphos.api")


def handle_request(
    method: str, path: str, token: str, provided_token: str, ctx
) -> tuple[int, dict]:
    """Pure router → ``(status_code, body_dict)``. No I/O beyond ctx/state."""
    if not token or provided_token != token:
        return 401, {"error": "unauthorized"}

    path = path.split("?", 1)[0].rstrip("/") or "/"

    if method == "GET" and path == "/shows":
        return 200, {
            "shows": [
                {"slug": s.slug, "title": s.title, "source": getattr(s, "source", "podcast")}
                for s in ctx.watchlist.shows
            ]
        }
    if method == "GET" and path == "/status":
        from core.state import EpisodeStatus

        counts = {}
        for st in EpisodeStatus:
            with ctx.state._conn() as c:
                row = c.execute(
                    "SELECT COUNT(*) AS n FROM episodes WHERE status=?", (st.value,)
                ).fetchone()
            counts[st.value] = row["n"] if row else 0
        # Distinct key — `paused` already holds the count of PAUSED episodes.
        counts["queue_paused"] = ctx.state.get_meta("queue_paused") == "1"
        return 200, counts
    if method == "GET" and path == "/queue":
        with ctx.state._conn() as c:
            rows = c.execute(
                "SELECT guid, show_slug, title, status FROM episodes "
                "WHERE status='pending' ORDER BY priority DESC, pub_date LIMIT 500"
            ).fetchall()
        return 200, {"queue": [dict(r) for r in rows]}
    if method == "POST" and path == "/queue/pause":
        ctx.state.set_meta("queue_paused", "1")
        return 200, {"ok": True, "paused": True}
    if method == "POST" and path == "/queue/resume":
        ctx.state.set_meta("queue_paused", "0")
        return 200, {"ok": True, "paused": False}

    return 404, {"error": "not found", "path": path}


def _make_handler(ctx, token):
    class _Handler(BaseHTTPRequestHandler):
        def _token(self) -> str:
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Bearer "):
                return auth[len("Bearer ") :].strip()
            from urllib.parse import parse_qs, urlparse

            return (parse_qs(urlparse(self.path).query).get("token") or [""])[0]

        def _dispatch(self, method: str) -> None:
            try:
                status, body = handle_request(method, self.path, token, self._token(), ctx)
            except Exception:  # noqa: BLE001
                logger.exception("api handler error")
                status, body = 500, {"error": "internal error"}
            payload = json.dumps(body, default=str).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):  # noqa: N802
            self._dispatch("GET")

        def do_POST(self):  # noqa: N802
            self._dispatch("POST")

        def log_message(self, *args):  # silence default stderr logging
            return

    return _Handler


def serve(ctx, *, token: str, host: str = "127.0.0.1", port: int = 8723) -> HTTPServer:
    """Start the localhost API server (blocking ``serve_forever`` by the caller).

    Bound to loopback only. Returns the HTTPServer so the caller can run/stop it.
    """
    server = HTTPServer((host, port), _make_handler(ctx, token))
    return server
