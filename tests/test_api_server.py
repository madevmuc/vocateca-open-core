"""Localhost JSON API (10.2)."""

from __future__ import annotations

from core.api_server import handle_request
from core.models import Settings, Show, Watchlist
from core.state import EpisodeStatus, StateStore


class _Ctx:
    def __init__(self, tmp_path):
        self.watchlist = Watchlist(shows=[Show(slug="sh", title="Show", rss="r")])
        self.state = StateStore(tmp_path / "s.sqlite")
        self.state.init_schema()
        self.state.upsert_episode(
            show_slug="sh", guid="g1", title="Ep", pub_date="2026-01-01", mp3_url="u"
        )
        self.settings = Settings()


_TOKEN = "secret-token"


def test_auth_rejects_bad_token(tmp_path):
    status, _ = handle_request("GET", "/shows", _TOKEN, "wrong", _Ctx(tmp_path))
    assert status == 401


def test_shows_endpoint(tmp_path):
    status, body = handle_request("GET", "/shows", _TOKEN, _TOKEN, _Ctx(tmp_path))
    assert status == 200
    assert body["shows"][0]["slug"] == "sh"


def test_status_endpoint(tmp_path):
    ctx = _Ctx(tmp_path)
    ctx.state.upsert_episode(
        show_slug="sh", guid="p1", title="P", pub_date="2026-01-01", mp3_url="u"
    )
    ctx.state.set_status("p1", EpisodeStatus.PAUSED)
    status, body = handle_request("GET", "/status", _TOKEN, _TOKEN, ctx)
    assert status == 200
    assert "pending" in body
    # The PAUSED episode count and the queue-paused boolean must not collide.
    assert body["paused"] == 1
    assert body["queue_paused"] is False


def test_queue_endpoint(tmp_path):
    status, body = handle_request("GET", "/queue", _TOKEN, _TOKEN, _Ctx(tmp_path))
    assert status == 200
    assert any(e["guid"] == "g1" for e in body["queue"])


def test_pause_resume_queue(tmp_path):
    ctx = _Ctx(tmp_path)
    status, _ = handle_request("POST", "/queue/pause", _TOKEN, _TOKEN, ctx)
    assert status == 200
    assert ctx.state.get_meta("queue_paused") == "1"
    handle_request("POST", "/queue/resume", _TOKEN, _TOKEN, ctx)
    assert ctx.state.get_meta("queue_paused") == "0"


def test_unknown_route_404(tmp_path):
    status, _ = handle_request("GET", "/nope", _TOKEN, _TOKEN, _Ctx(tmp_path))
    assert status == 404
