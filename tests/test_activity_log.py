"""App-wide activity log: user actions surface via the GUI sink + the logger."""

from __future__ import annotations

import logging
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.state import EpisodeStatus
from ui import activity_log

_app = QApplication.instance() or QApplication([])
_keep: list = []


def _make_queue(tmp_path):
    from ui.app_context import AppContext
    from ui.queue_tab import QueueTab

    ctx = AppContext.load(tmp_path)
    qt = QueueTab(ctx)
    _keep.append(qt)
    return qt, ctx


def _seed(ctx, guid):
    ctx.state.upsert_episode(
        show_slug="s",
        guid=guid,
        title=guid,
        pub_date="2026-06-01",
        mp3_url=f"https://www.youtube.com/watch?v={guid}",
    )


def test_log_routes_to_sink_and_logger(caplog):
    captured: list[str] = []
    activity_log.set_sink(captured.append)
    try:
        with caplog.at_level(logging.INFO, logger="paragraphos.activity"):
            activity_log.log("hello world")
        assert "hello world" in captured  # GUI dock sink
        assert any("hello world" in r.message for r in caplog.records)  # log file
    finally:
        activity_log.set_sink(None)


def test_sink_failure_never_raises():
    def boom(_msg):
        raise RuntimeError("dock exploded")

    activity_log.set_sink(boom)
    try:
        activity_log.log("still fine")  # must not raise
    finally:
        activity_log.set_sink(None)


def test_queue_actions_emit_activity(tmp_path):
    captured: list[str] = []
    activity_log.set_sink(captured.append)
    try:
        qt, ctx = _make_queue(tmp_path)
        _seed(ctx, "g1")
        qt._set_episode_status(["g1"], EpisodeStatus.PAUSED)
        qt._remove_from_queue(["g1"])
        assert any("Deactivated" in m for m in captured)
        assert any("Removed 1 episode" in m for m in captured)
    finally:
        activity_log.set_sink(None)
