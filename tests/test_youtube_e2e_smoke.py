"""End-to-end smoke: add a YouTube channel through ``AddShowDialog`` with
all yt-dlp / network calls mocked. Confirms the full chain from URL paste
to persisted ``watchlist.yaml`` + pending rows in ``state.sqlite``."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.models import Settings, Watchlist
from core.state import EpisodeStatus

_app_ref = QApplication.instance() or QApplication([])
_keepalive: list = []


def _make_dialog(tmp_path, settings: Settings):
    from ui.add_show_dialog import AddShowDialog
    from ui.app_context import AppContext

    ctx = AppContext.load(tmp_path)
    ctx.settings = settings
    dlg = AddShowDialog(ctx, None)
    _keepalive.append(dlg)
    return dlg, ctx


def test_add_youtube_channel_writes_watchlist_and_enqueues(tmp_path, monkeypatch):
    """Drive the dialog: paste URL → resolve → add. Watchlist on disk
    should contain the YouTube show, and state.sqlite should have
    pending episodes seeded from the mocked enumeration."""
    cid = "UCabc1234567890123456789"

    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda c: {
            "channel_id": c,
            "title": "Channel X",
            "video_count": 50,
            "artwork_url": "https://example.com/x.jpg",
        },
    )
    monkeypatch.setattr(
        "core.youtube_meta.enumerate_channel_videos",
        lambda c, limit=None: [
            {
                "id": f"v{i:02d}",
                "title": f"Ep {i}",
                "upload_date": f"2026010{i % 10}",
            }
            for i in range(20)
        ],
    )

    dlg, ctx = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText(f"https://www.youtube.com/channel/{cid}")
    dlg._on_youtube_url_resolve()

    # Resolve runs on a worker thread. Block until it truly finishes
    # (``wait`` is immune to the just-started ``isRunning()==False`` race),
    # then pump the event loop so the queued ``done`` signal is delivered.
    import time

    from PyQt6.QtWidgets import QApplication

    t = getattr(dlg, "_yt_resolve_thread", None)
    if t is not None:
        t.wait(5000)
    _start = time.monotonic()
    while time.monotonic() - _start < 5.0:
        QApplication.instance().processEvents()
        if dlg._loaded_yt_preview:
            break
        time.sleep(0.01)

    # Pick "Last 20" so all 20 mocked videos stay pending.
    for btn in dlg._yt_backfill_grp.buttons():
        if btn.text() == "Last 20":
            btn.setChecked(True)
            break

    dlg._add_from_youtube()

    # 1. watchlist.yaml on disk has the YouTube show.
    wl_path = ctx.data_dir / "watchlist.yaml"
    assert wl_path.exists()
    reloaded = Watchlist.load(wl_path)
    yt_shows = [s for s in reloaded.shows if s.source == "youtube"]
    assert len(yt_shows) == 1
    show = yt_shows[0]
    assert show.slug == "channel-x"
    assert show.rss == f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
    assert show.artwork_url == "https://example.com/x.jpg"

    # 2. state.sqlite has pending episodes for that show.
    pending = ctx.state.list_by_status(show.slug, EpisodeStatus.PENDING)
    assert len(pending) == 20
    guids = {row["guid"] for row in pending}
    assert "v00" in guids and "v19" in guids
