"""Tests for ui.worker_thread._pctx_for — YouTube wiring."""

from __future__ import annotations

import os
from types import SimpleNamespace

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.models import Settings, Show
from ui.worker_thread import CheckAllThread

_app_ref = QApplication.instance() or QApplication([])


def _make_thread(tmp_path, settings: Settings | None = None) -> CheckAllThread:
    settings = settings or Settings()
    ctx = SimpleNamespace(
        state=object(),
        library=object(),
        data_dir=tmp_path,
        watchlist=SimpleNamespace(shows=[]),
    )
    return CheckAllThread(ctx, settings)


def _make_thread_with_state(tmp_path, settings: Settings | None = None):
    from core.state import StateStore

    settings = settings or Settings()
    state = StateStore(tmp_path / "state.sqlite")
    state.init_schema()
    ctx = SimpleNamespace(
        state=state,
        library=object(),
        data_dir=tmp_path,
        watchlist=SimpleNamespace(shows=[]),
    )
    return CheckAllThread(ctx, settings), state


def _seed_deferred(state, slug="ch", guid="d1"):
    state.upsert_episode(
        show_slug=slug,
        guid=guid,
        title="Premiere",
        pub_date="2026-06-20",
        mp3_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    )
    from core.state import EpisodeStatus

    state.set_status(guid, EpisodeStatus.DEFERRED)


def _yt_show():
    return Show(
        slug="ch",
        source="youtube",
        rss="https://www.youtube.com/feeds/videos.xml?channel_id=UCabc1234567890123456789",
        title="Ch",
    )


def test_reprobe_promotes_finished_premiere(tmp_path, monkeypatch):
    th, state = _make_thread_with_state(tmp_path)
    _seed_deferred(state)
    monkeypatch.setattr(
        "core.youtube_audio.probe_video_meta",
        lambda *a, **k: {
            "live_status": "was_live",
            "duration": 600,
            "webpage_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        },
    )
    assert th._reprobe_deferred(_yt_show()) == 1
    assert state.get_episode("d1")["status"] == "pending"


def test_reprobe_keeps_still_live(tmp_path, monkeypatch):
    th, state = _make_thread_with_state(tmp_path)
    _seed_deferred(state)
    monkeypatch.setattr(
        "core.youtube_audio.probe_video_meta",
        lambda *a, **k: {"live_status": "is_live"},
    )
    assert th._reprobe_deferred(_yt_show()) == 0
    assert state.get_episode("d1")["status"] == "deferred"


def test_reprobe_skips_non_youtube_show(tmp_path, monkeypatch):
    th, state = _make_thread_with_state(tmp_path)
    _seed_deferred(state)

    # Count calls instead of raising: a raised AssertionError would be
    # swallowed by the method's `except Exception`, so the test would pass
    # even if the youtube-only guard were removed. A call counter proves the
    # probe is genuinely never reached for a podcast show.
    calls = {"n": 0}

    def _count(*a, **k):
        calls["n"] += 1
        return {}

    monkeypatch.setattr("core.youtube_audio.probe_video_meta", _count)
    show = Show(slug="ch", title="P", rss="https://example.com/feed.rss")
    assert th._reprobe_deferred(show) == 0
    assert calls["n"] == 0


def test_reprobe_probe_error_leaves_deferred(tmp_path, monkeypatch):
    th, state = _make_thread_with_state(tmp_path)
    _seed_deferred(state)

    def _boom(*a, **k):
        raise RuntimeError("yt-dlp blew up")

    monkeypatch.setattr("core.youtube_audio.probe_video_meta", _boom)
    assert th._reprobe_deferred(_yt_show()) == 0
    assert state.get_episode("d1")["status"] == "deferred"


def test_pctx_for_youtube_show_populates_channel_id(tmp_path):
    cid = "UCabc1234567890123456789"
    settings = Settings(sources_youtube=True, youtube_default_transcript_source="captions")
    th = _make_thread(tmp_path, settings)
    show = Show(
        slug="mr-beast",
        title="Mr Beast",
        rss=f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}",
        source="youtube",
        youtube_transcript_pref="whisper",
    )
    pctx = th._pctx_for(show)
    assert pctx.source == "youtube"
    assert pctx.youtube_channel_id == cid
    assert pctx.youtube_transcript_pref == "whisper"
    assert pctx.youtube_default_transcript_source == "captions"


def test_pctx_for_youtube_show_inherits_default_transcript_source(tmp_path):
    cid = "UCxyz9876543210987654321"
    settings = Settings(youtube_default_transcript_source="whisper")
    th = _make_thread(tmp_path, settings)
    show = Show(
        slug="x",
        title="X",
        rss=f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}",
        source="youtube",
    )
    pctx = th._pctx_for(show)
    assert pctx.youtube_channel_id == cid
    assert pctx.youtube_transcript_pref == ""
    assert pctx.youtube_default_transcript_source == "whisper"


def test_pctx_for_podcast_show_omits_youtube_fields(tmp_path):
    th = _make_thread(tmp_path)
    show = Show(slug="p", title="P", rss="https://example.com/feed.rss")
    pctx = th._pctx_for(show)
    assert pctx.source == "podcast"
    assert pctx.youtube_channel_id == ""
