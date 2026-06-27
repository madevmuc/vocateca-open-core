"""Show Details → paced background back-catalogue streaming (Task 4.7).

A YouTube channel usually has far more uploads than were seeded (only the
backfill depth got into the DB). On open the dialog shows the DB rows
instantly, then enumerates the channel's full history off-thread and appends
the not-yet-seeded videos as synthetic ``"available"`` rows — paced (batched
via a QTimer) and capped (a "Load more" button reveals the rest). Triggering
an available row seeds + queues that single video; closing the dialog cancels
the stream.

These tests drive the SEAMS directly (``_on_history_loaded`` /
``_append_next_batch`` / ``_trigger_available`` / ``_cancel_history_stream``)
so they never depend on the real QThread or the QTimer actually firing. The
real ``_YoutubeHistoryThread`` is patched with a no-op stub so constructing a
YouTube dialog doesn't shell out to yt-dlp.
"""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QApplication

from core.models import Settings, Show, Watchlist
from core.state import StateStore
from ui.app_context import AppContext

_app_ref = QApplication.instance() or QApplication([])
_keepalive: list = []

# A YouTube channel-feed URL whose channel_id param is what
# `channel_id_from_feed_url` extracts; non-empty so the stream proceeds.
_YT_RSS = "https://www.youtube.com/feeds/videos.xml?channel_id=UCtest123"


@pytest.fixture
def qapp():
    return _app_ref


# ── no-op QThread stub: construction must not spawn a real worker ─────────


class _SignalStub:
    def connect(self, *a, **k):
        pass

    def disconnect(self, *a, **k):
        pass


class _StubHistoryThread:
    """Drop-in for ``_YoutubeHistoryThread`` that never runs anything."""

    def __init__(self, *args, **kwargs):
        self.loaded = _SignalStub()
        self.failed = _SignalStub()
        self.finished = _SignalStub()

    def start(self):
        pass

    def deleteLater(self):
        pass

    def isRunning(self):
        return False


# ── harness ──────────────────────────────────────────────────────────────


def _make_ctx(tmp_path, show: Show) -> AppContext:
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    settings = Settings()
    settings.output_root = str(tmp_path / "out")
    watchlist = Watchlist(shows=[show])
    watchlist.save(data_dir / "watchlist.yaml")
    state = StateStore(data_dir / "state.sqlite")
    state.init_schema()
    return AppContext(
        data_dir=data_dir,
        settings=settings,
        watchlist=watchlist,
        state=state,
        library=None,  # type: ignore[arg-type]
    )


def _seed_one(ctx, slug, guid, day):
    ctx.state.upsert_episode(
        show_slug=slug,
        guid=guid,
        title=guid,
        pub_date=f"2026-06-{day:02d}T00:00:00+00:00",
        mp3_url=f"https://example.com/{guid}.mp3",
    )


def _dialog(ctx, slug):
    from ui.show_details_dialog import ShowDetailsDialog

    dlg = ShowDetailsDialog(ctx, slug)
    _keepalive.append(dlg)
    return dlg


def _patch_youtube(monkeypatch):
    """yt-dlp 'installed' + a no-op stream thread, so building a YouTube
    dialog exercises `_start_history_stream` without shelling out."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr("ui.show_details_dialog._YoutubeHistoryThread", _StubHistoryThread)


def _video(vid, ts):
    return {"id": vid, "title": vid.upper(), "timestamp": ts}


def _statuses_by_guid(tbl) -> dict:
    out = {}
    for i in range(tbl.rowCount()):
        it = tbl.item(i, 0)
        out[it.data(Qt.ItemDataRole.UserRole)] = it.data(Qt.ItemDataRole.UserRole + 1)
    return out


def _select_rows_by_guid(tbl, *guids):
    """Select the rows whose stashed guid is in ``guids`` (any row order)."""
    from PyQt6.QtWidgets import QTableWidget

    by_guid = {}
    for i in range(tbl.rowCount()):
        by_guid[tbl.item(i, 0).data(Qt.ItemDataRole.UserRole)] = i
    tbl.clearSelection()
    tbl.setSelectionMode(QTableWidget.SelectionMode.MultiSelection)
    for g in guids:
        tbl.selectRow(by_guid[g])
    tbl.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)


# ── tests ────────────────────────────────────────────────────────────────


def test_history_appends_available_rows(qapp, tmp_path, monkeypatch):
    """Two seeded DB rows (s1/s2) plus three back-catalogue videos
    (a1/a2/a3) → after draining the buffer the table has 5 rows; a1-a3 carry
    the synthetic ``available`` status; s1/s2 keep their real DB status."""
    _patch_youtube(monkeypatch)
    show = Show(slug="yt", title="YT", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "yt", "s1", 1)
    _seed_one(ctx, "yt", "s2", 2)
    dlg = _dialog(ctx, "yt")

    videos = [
        _video("s1", 1700000000),
        _video("s2", 1700000100),
        _video("a1", 1700000200),
        _video("a2", 1700000300),
        _video("a3", 1700000400),
    ]
    dlg._on_history_loaded(videos)
    # Drain the paced buffer by hand (one call already suffices since the
    # default batch >> 3, but loop for robustness).
    while dlg._available_buffer:
        dlg._append_next_batch()

    assert dlg._episodes_tbl.rowCount() == 5
    statuses = _statuses_by_guid(dlg._episodes_tbl)
    assert statuses["a1"] == "available"
    assert statuses["a2"] == "available"
    assert statuses["a3"] == "available"
    # Seeded rows keep their real DB status (pending), not "available".
    assert statuses["s1"] == "pending"
    assert statuses["s2"] == "pending"


def test_available_rows_capped_then_load_more(qapp, tmp_path, monkeypatch):
    """30 new videos with a per-instance cap of 20 → the first pass appends
    exactly the cap and reveals 'Load more'; clicking it appends the rest and
    hides the button."""
    _patch_youtube(monkeypatch)
    show = Show(slug="cap", title="Cap", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "cap")
    dlg._history_cap = 20  # lower the per-session cap for the test

    videos = [_video(f"v{i:02d}", 1700000000 + i) for i in range(30)]
    dlg._on_history_loaded(videos)
    while dlg._history_timer.isActive():
        dlg._append_next_batch()

    assert dlg._episodes_tbl.rowCount() == 20
    assert not dlg._load_more_btn.isHidden()

    dlg._load_more()
    while dlg._history_timer.isActive():
        dlg._append_next_batch()

    assert dlg._episodes_tbl.rowCount() == 30
    assert dlg._load_more_btn.isHidden()


def test_trigger_available_seeds_and_queues(qapp, tmp_path, monkeypatch):
    """Triggering an available row upserts it as a real ``pending`` row at
    PRIORITY_RUN_NEXT; after the reload that row is no longer ``available``."""
    from ui.prioritize import PRIORITY_RUN_NEXT

    _patch_youtube(monkeypatch)
    show = Show(slug="trg", title="Trg", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "trg")

    dlg._on_history_loaded([_video("aX", 1700000200), _video("aY", 1700000300)])
    while dlg._available_buffer:
        dlg._append_next_batch()

    assert ctx.state.get_episode("aX") is None  # not yet seeded
    dlg._trigger_available("aX")

    ep = ctx.state.get_episode("aX")
    assert ep is not None
    assert ep["status"] == "pending"
    assert ep["priority"] == PRIORITY_RUN_NEXT
    # After reload aX is a real DB row, no longer the synthetic available one.
    assert _statuses_by_guid(dlg._episodes_tbl)["aX"] != "available"


def test_cancel_history_stream_stops(qapp, tmp_path, monkeypatch):
    """Cancel stops the timer + clears the buffer; a later append is a no-op."""
    _patch_youtube(monkeypatch)
    show = Show(slug="cn", title="Cn", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "cn")

    videos = [_video(f"c{i:02d}", 1700000000 + i) for i in range(50)]
    dlg._on_history_loaded(videos)
    # Default cap (300) > 50 so the timer is still active with a partial buffer.
    assert dlg._history_timer.isActive()

    dlg._cancel_history_stream()
    assert not dlg._history_timer.isActive()
    assert dlg._available_buffer == []

    before = dlg._episodes_tbl.rowCount()
    dlg._append_next_batch()  # nothing left to append
    assert dlg._episodes_tbl.rowCount() == before


def test_non_youtube_show_no_stream(qapp, tmp_path, monkeypatch):
    """A podcast show never starts a stream — no `_history_thread` created."""
    _patch_youtube(monkeypatch)  # even with yt-dlp 'installed'…
    show = Show(slug="pod", title="Pod", rss="https://feed", source="podcast")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "pod")
    assert getattr(dlg, "_history_thread", None) is None


# ── follow-up hardening (review fixes) ───────────────────────────────────


def test_status_filter_hides_and_restores_available_rows(qapp, tmp_path, monkeypatch):
    """A status filter never shows synthetic ``available`` rows and pauses the
    stream; clearing the filter re-materializes the parked entries. Appending
    while filtered is a no-op that leaves the buffer intact."""
    from core.state import EpisodeStatus

    _patch_youtube(monkeypatch)
    show = Show(slug="fa", title="Fa", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "fa", "f1", 1)
    ctx.state.set_status("f1", EpisodeStatus.FAILED)
    dlg = _dialog(ctx, "fa")

    dlg._on_history_loaded([_video("a1", 1700000200), _video("a2", 1700000300)])
    while dlg._available_buffer:
        dlg._append_next_batch()
    assert dlg._episodes_tbl.rowCount() == 3  # f1 + a1 + a2
    assert _statuses_by_guid(dlg._episodes_tbl)["a1"] == "available"

    # Filter to "failed": only the real failed row, no synthetic rows; the
    # timer is stopped and the available entries are parked in the buffer.
    dlg._status_filter_combo.setCurrentText("failed")
    assert dlg._episodes_tbl.rowCount() == 1
    assert dlg._episodes_tbl.item(0, 0).data(Qt.ItemDataRole.UserRole) == "f1"
    assert not dlg._history_timer.isActive()
    assert set(m["guid"] for m in dlg._available_buffer) == {"a1", "a2"}

    # Appending while filtered adds nothing and keeps the buffer intact.
    before_rows = dlg._episodes_tbl.rowCount()
    before_buf = len(dlg._available_buffer)
    dlg._append_next_batch()
    assert dlg._episodes_tbl.rowCount() == before_rows
    assert len(dlg._available_buffer) == before_buf

    # Back to All → the available rows re-materialize.
    dlg._status_filter_combo.setCurrentText("All")
    while dlg._available_buffer:
        dlg._append_next_batch()
    statuses = _statuses_by_guid(dlg._episodes_tbl)
    assert dlg._episodes_tbl.rowCount() == 3
    assert statuses["a1"] == "available"
    assert statuses["a2"] == "available"


def test_queue_selected_seeds_available_rows(qapp, tmp_path, monkeypatch):
    """Bulk-queueing a selection that mixes a real failed row with a synthetic
    available row seeds + queues BOTH: both end up pending @ PRIORITY_RUN_NEXT,
    and the available one becomes a real DB row (no longer 'available')."""
    from core.state import EpisodeStatus
    from ui.prioritize import PRIORITY_RUN_NEXT

    _patch_youtube(monkeypatch)
    show = Show(slug="qa", title="Qa", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "qa", "f1", 1)
    ctx.state.set_status("f1", EpisodeStatus.FAILED)
    dlg = _dialog(ctx, "qa")

    dlg._on_history_loaded([_video("a1", 1700000200)])
    while dlg._available_buffer:
        dlg._append_next_batch()
    assert ctx.state.get_episode("a1") is None  # not yet a real row

    _select_rows_by_guid(dlg._episodes_tbl, "f1", "a1")
    dlg._queue_selected()

    f1 = ctx.state.get_episode("f1")
    a1 = ctx.state.get_episode("a1")
    assert f1["status"] == "pending"
    assert f1["priority"] == PRIORITY_RUN_NEXT
    assert a1 is not None  # the available row was seeded
    assert a1["status"] == "pending"
    assert a1["priority"] == PRIORITY_RUN_NEXT
    assert _statuses_by_guid(dlg._episodes_tbl)["a1"] != "available"


def test_cancelled_stream_ignores_late_load(qapp, tmp_path, monkeypatch):
    """Once cancelled, a late `loaded` signal must not re-arm the stream — no
    timer starts and no rows are appended."""
    _patch_youtube(monkeypatch)
    show = Show(slug="lc", title="Lc", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "lc")

    dlg._cancel_history_stream()
    before = dlg._episodes_tbl.rowCount()

    dlg._on_history_loaded([_video("z1", 1700000000), _video("z2", 1700000100)])
    assert dlg._episodes_tbl.rowCount() == before
    assert dlg._available_buffer == []
    timer = getattr(dlg, "_history_timer", None)
    assert timer is None or not timer.isActive()


def test_loading_spinner_tracks_stream(qapp, tmp_path, monkeypatch):
    """The bottom progress strip is shown while the back-catalogue streams and
    hidden once the buffer is fully drained."""
    _patch_youtube(monkeypatch)
    show = Show(slug="sp", title="Sp", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "sp")
    # Stream kicked off on open → spinner visible.
    assert not dlg._history_spinner.isHidden()
    dlg._on_history_loaded([_video("a1", 1700000200)])
    while dlg._available_buffer:
        dlg._append_next_batch()
    # Buffer drained → spinner hidden.
    assert dlg._history_spinner.isHidden()


def test_undated_available_rows_show_dash(qapp, tmp_path, monkeypatch):
    """yt-dlp's flat listing carries no date; an undated back-catalogue row
    shows an em dash, not a blank cell."""
    _patch_youtube(monkeypatch)
    show = Show(slug="ds", title="Ds", rss=_YT_RSS, source="youtube")
    ctx = _make_ctx(tmp_path, show)
    dlg = _dialog(ctx, "ds")
    dlg._on_history_loaded([{"id": "a1", "title": "No Date Vid"}])  # no timestamp
    while dlg._available_buffer:
        dlg._append_next_batch()
    tbl = dlg._episodes_tbl
    row = next(
        i for i in range(tbl.rowCount()) if tbl.item(i, 0).data(Qt.ItemDataRole.UserRole) == "a1"
    )
    assert tbl.item(row, 0).text() == "—"
