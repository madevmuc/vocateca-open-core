"""Queue context-menu actions: deactivate (pause) and remove-from-queue.

- "Deactivate" flips an episode pending↔paused; a paused row stays VISIBLE in
  the queue table but the worker never claims it (claim query is pending-only).
- "Remove from queue" soft-deletes by marking the episode ``skipped`` (leaves
  the active queue; the feed poll won't re-queue it).
"""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QApplication

from core.state import EpisodeStatus

_app = QApplication.instance() or QApplication([])
_keep: list = []


def _make_queue(tmp_path):
    from ui.app_context import AppContext
    from ui.queue_tab import QueueTab

    ctx = AppContext.load(tmp_path)
    qt = QueueTab(ctx)
    _keep.append(qt)
    return qt, ctx


def _seed(ctx, guid, status: EpisodeStatus | None = None):
    ctx.state.upsert_episode(
        show_slug="s",
        guid=guid,
        title=guid,
        pub_date="2026-06-01",
        mp3_url=f"https://www.youtube.com/watch?v={guid}",
    )
    if status is not None:
        ctx.state.set_status(guid, status)


def _queue_guids(qt) -> set:
    qt._last_table_refresh = 0.0
    qt._refresh_table()
    out = set()
    for row in range(qt.table.rowCount()):
        it = qt.table.item(row, 0)
        if it is not None:
            out.add(it.data(Qt.ItemDataRole.UserRole))
    return out


def test_remove_from_queue_marks_skipped(tmp_path):
    qt, ctx = _make_queue(tmp_path)
    _seed(ctx, "g1")
    qt._remove_from_queue("g1")
    assert ctx.state.get_episode("g1")["status"] == "skipped"
    # And it has left the queue view.
    assert "g1" not in _queue_guids(qt)


def test_deactivate_pauses_then_reactivate(tmp_path):
    qt, ctx = _make_queue(tmp_path)
    _seed(ctx, "g2")
    qt._set_episode_status("g2", EpisodeStatus.PAUSED)
    assert ctx.state.get_episode("g2")["status"] == "paused"
    qt._set_episode_status("g2", EpisodeStatus.PENDING)
    assert ctx.state.get_episode("g2")["status"] == "pending"


def test_paused_visible_in_queue_but_not_claimable(tmp_path):
    qt, ctx = _make_queue(tmp_path)
    _seed(ctx, "p1", EpisodeStatus.PAUSED)
    _seed(ctx, "p2")  # pending
    # The "not touched" guarantee: paused is out of the pending pool the worker
    # claims from, while pending stays in it.
    pending = [e["guid"] for e in ctx.state.list_by_status("s", EpisodeStatus.PENDING)]
    assert "p1" not in pending and "p2" in pending
    # But the paused row is still VISIBLE in the queue table.
    guids = _queue_guids(qt)
    assert "p1" in guids and "p2" in guids
