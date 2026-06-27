"""Show Details → full episode browser (Tasks 4.1 + 4.2).

4.1 — the recent-episodes table grows into a full browser: every episode
     for the show renders (the old ``LIMIT 10`` is gone) and the window is
     resizable/maximizable.
4.2 — the table supports row multi-select while keeping the per-row guid
     stash + context-menu resolution intact; ``_selected_guids`` returns the
     guids of all selected rows.
"""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtCore import QDate, Qt
from PyQt6.QtWidgets import QApplication, QTableWidget

from core.models import Settings, Show, Watchlist
from core.state import StateStore
from ui.app_context import AppContext

_app_ref = QApplication.instance() or QApplication([])
_keepalive: list = []


@pytest.fixture
def qapp():
    return _app_ref


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


def _seed_episodes(ctx: AppContext, slug: str, n: int) -> list[str]:
    """Seed ``n`` episodes with descending pub_dates; return guids in
    pub_date-DESC order (newest first) so they match the table's row order."""
    guids: list[str] = []
    for i in range(n):
        guid = f"{slug}-ep{i:02d}"
        # pub_dates ascending with i so DESC order reverses the seed order.
        ctx.state.upsert_episode(
            show_slug=slug,
            guid=guid,
            title=f"Episode {i}",
            pub_date=f"2026-06-{i + 1:02d}T00:00:00+00:00",
            mp3_url=f"https://example.com/{guid}.mp3",
        )
        guids.append(guid)
    # Newest first == highest pub_date first == reversed seed order.
    return list(reversed(guids))


def _make_dialog(show: Show, tmp_path):
    from ui.show_details_dialog import ShowDetailsDialog

    ctx = _make_ctx(tmp_path, show)
    dlg = ShowDetailsDialog(ctx, show.slug)
    _keepalive.append(dlg)
    return dlg


# ── Task 4.1 ─────────────────────────────────────────────────────────────


def test_all_episodes_render_no_limit(qapp, tmp_path):
    """15 seeded episodes → all 15 rows render (the LIMIT 10 is gone)."""
    show = Show(slug="full", title="Full", rss="https://feed", source="podcast")
    from ui.show_details_dialog import ShowDetailsDialog

    ctx = _make_ctx(tmp_path, show)
    _seed_episodes(ctx, "full", 15)
    dlg = ShowDetailsDialog(ctx, "full")
    _keepalive.append(dlg)
    assert dlg._episodes_tbl.rowCount() == 15


def test_title_search_hides_nonmatching_rows(qapp, tmp_path):
    """The search box above the list filters episodes by title — non-matching
    rows are hidden, and clearing the box un-hides everything."""
    show = Show(slug="srch", title="Srch", rss="https://feed", source="podcast")
    from ui.show_details_dialog import ShowDetailsDialog

    ctx = _make_ctx(tmp_path, show)
    _seed_episodes(ctx, "srch", 5)  # titles "Episode 0".."Episode 4"
    dlg = ShowDetailsDialog(ctx, "srch")
    _keepalive.append(dlg)
    tbl = dlg._episodes_tbl
    assert tbl.rowCount() == 5

    dlg._ep_search.setText("Episode 2")
    visible = [i for i in range(tbl.rowCount()) if not tbl.isRowHidden(i)]
    assert [tbl.item(i, 1).text() for i in visible] == ["Episode 2"]

    dlg._ep_search.clear()
    assert all(not tbl.isRowHidden(i) for i in range(tbl.rowCount()))


def test_window_is_resizable_maximizable(qapp, tmp_path):
    """The dialog keeps a minimum size but is not fixed, and the maximize
    button hint is enabled so the browser can grow to fill the screen."""
    show = Show(slug="rz", title="Rz", rss="https://feed", source="podcast")
    dlg = _make_dialog(show, tmp_path)
    # Not fixed: max size is the Qt 'unbounded' sentinel, not the min.
    assert dlg.maximumWidth() > dlg.minimumWidth()
    assert bool(dlg.windowFlags() & Qt.WindowType.WindowMaximizeButtonHint)


# ── Task 4.2 ─────────────────────────────────────────────────────────────


def test_table_is_row_multiselect(qapp, tmp_path):
    show = Show(slug="ms", title="Ms", rss="https://feed", source="podcast")
    dlg = _make_dialog(show, tmp_path)
    tbl = dlg._episodes_tbl
    assert tbl.selectionMode() == QTableWidget.SelectionMode.ExtendedSelection
    assert tbl.selectionBehavior() == QTableWidget.SelectionBehavior.SelectRows


def test_selected_guids_returns_selected_rows(qapp, tmp_path):
    show = Show(slug="sel", title="Sel", rss="https://feed", source="podcast")
    from ui.show_details_dialog import ShowDetailsDialog

    ctx = _make_ctx(tmp_path, show)
    guids = _seed_episodes(ctx, "sel", 5)
    dlg = ShowDetailsDialog(ctx, "sel")
    _keepalive.append(dlg)

    tbl = dlg._episodes_tbl
    tbl.clearSelection()
    tbl.selectRow(0)
    # Extend the selection to row 2 without clearing row 0.
    tbl.setSelectionMode(QTableWidget.SelectionMode.MultiSelection)
    tbl.selectRow(2)
    tbl.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)

    assert set(dlg._selected_guids()) == {guids[0], guids[2]}


def test_per_row_guid_stash_survives_refactor(qapp, tmp_path):
    """The Date cell still carries its guid at UserRole after the
    multi-select refactor (the context menu relies on it)."""
    show = Show(slug="stash", title="Stash", rss="https://feed", source="podcast")
    from ui.show_details_dialog import ShowDetailsDialog

    ctx = _make_ctx(tmp_path, show)
    guids = _seed_episodes(ctx, "stash", 5)
    dlg = ShowDetailsDialog(ctx, "stash")
    _keepalive.append(dlg)

    item = dlg._episodes_tbl.item(0, 0)
    assert item.data(Qt.ItemDataRole.UserRole) == guids[0]


# ── shared seed helper for mixed-status tests ────────────────────────────


def _seed_one(ctx, slug, guid, day, status=None):
    """Seed a single episode on 2026-06-<day>; optionally set its status."""
    from core.state import EpisodeStatus  # noqa: F401  (type hint clarity)

    ctx.state.upsert_episode(
        show_slug=slug,
        guid=guid,
        title=guid,
        pub_date=f"2026-06-{day:02d}T00:00:00+00:00",
        mp3_url=f"https://example.com/{guid}.mp3",
    )
    if status is not None:
        ctx.state.set_status(guid, status)


def _select_rows_by_guid(tbl, *guids):
    """Select the rows whose stashed guid is in ``guids`` (any row order)."""
    by_guid = {}
    for i in range(tbl.rowCount()):
        by_guid[tbl.item(i, 0).data(Qt.ItemDataRole.UserRole)] = i
    tbl.clearSelection()
    tbl.setSelectionMode(QTableWidget.SelectionMode.MultiSelection)
    for g in guids:
        tbl.selectRow(by_guid[g])
    tbl.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)


# ── Task 4.3 ─────────────────────────────────────────────────────────────


def test_queue_selected_sets_pending_and_priority(qapp, tmp_path):
    """Selecting a failed + skipped row and queueing them sets both to
    pending @ PRIORITY_RUN_NEXT; an unselected done episode is untouched."""
    from core.state import EpisodeStatus
    from ui.prioritize import PRIORITY_RUN_NEXT
    from ui.show_details_dialog import ShowDetailsDialog

    show = Show(slug="qs", title="Qs", rss="https://feed", source="podcast")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "qs", "f1", 1, EpisodeStatus.FAILED)
    _seed_one(ctx, "qs", "s1", 2, EpisodeStatus.SKIPPED)
    _seed_one(ctx, "qs", "d1", 3, EpisodeStatus.DONE)
    dlg = ShowDetailsDialog(ctx, "qs")
    _keepalive.append(dlg)

    _select_rows_by_guid(dlg._episodes_tbl, "f1", "s1")
    dlg._queue_selected()

    f1 = ctx.state.get_episode("f1")
    s1 = ctx.state.get_episode("s1")
    d1 = ctx.state.get_episode("d1")
    assert f1["status"] == "pending"
    assert f1["priority"] == PRIORITY_RUN_NEXT
    assert s1["status"] == "pending"
    assert s1["priority"] == PRIORITY_RUN_NEXT
    assert d1["status"] == "done"


def test_queue_selected_empty_is_noop(qapp, tmp_path):
    """No selection → _queue_guids is a no-op (no crash, status unchanged)."""
    from core.state import EpisodeStatus
    from ui.show_details_dialog import ShowDetailsDialog

    show = Show(slug="qe", title="Qe", rss="https://feed", source="podcast")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "qe", "d1", 1, EpisodeStatus.DONE)
    dlg = ShowDetailsDialog(ctx, "qe")
    _keepalive.append(dlg)

    dlg._episodes_tbl.clearSelection()
    dlg._queue_selected()  # must not raise

    assert ctx.state.get_episode("d1")["status"] == "done"


# ── Task 4.4 ─────────────────────────────────────────────────────────────


def test_queue_since_queues_on_or_after_cutoff_skipping_done(qapp, tmp_path):
    """A date sweep queues every not-done episode on/after the cutoff,
    leaves pre-cutoff episodes untouched, and never re-queues a done one."""
    from core.state import EpisodeStatus
    from ui.prioritize import PRIORITY_RUN_NEXT
    from ui.show_details_dialog import ShowDetailsDialog

    show = Show(slug="qd", title="Qd", rss="https://feed", source="podcast")
    ctx = _make_ctx(tmp_path, show)
    # 2026-06-01..05; cutoff will be 2026-06-03.
    _seed_one(ctx, "qd", "e1", 1, EpisodeStatus.FAILED)  # pre-cutoff
    _seed_one(ctx, "qd", "e2", 2, EpisodeStatus.SKIPPED)  # pre-cutoff
    _seed_one(ctx, "qd", "e3", 3, EpisodeStatus.DONE)  # on cutoff but done
    _seed_one(ctx, "qd", "e3b", 3, EpisodeStatus.FAILED)  # on cutoff, not done
    _seed_one(ctx, "qd", "e4", 4, EpisodeStatus.FAILED)  # after cutoff
    _seed_one(ctx, "qd", "e5", 5, EpisodeStatus.SKIPPED)  # after cutoff
    dlg = ShowDetailsDialog(ctx, "qd")
    _keepalive.append(dlg)

    dlg._since_date_edit.setDate(QDate(2026, 6, 3))
    dlg._queue_since()

    # On/after cutoff and not done → queued. `e3b` (exactly on the cutoff)
    # pins the inclusive `>=` boundary — a `>` regression would skip it.
    for g in ("e3b", "e4", "e5"):
        ep = ctx.state.get_episode(g)
        assert ep["status"] == "pending"
        assert ep["priority"] == PRIORITY_RUN_NEXT
    # On cutoff but already done → never re-queued.
    assert ctx.state.get_episode("e3")["status"] == "done"
    # Pre-cutoff → untouched.
    assert ctx.state.get_episode("e1")["status"] == "failed"
    assert ctx.state.get_episode("e2")["status"] == "skipped"


# ── Task 4.5 ─────────────────────────────────────────────────────────────


def test_status_filter_limits_rows_to_one_status(qapp, tmp_path):
    """Setting the status filter restricts the table to matching rows;
    clearing it (All / None) shows every episode again."""
    from core.state import EpisodeStatus
    from ui.show_details_dialog import ShowDetailsDialog

    show = Show(slug="flt", title="Flt", rss="https://feed", source="podcast")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "flt", "p1", 1, EpisodeStatus.PENDING)
    _seed_one(ctx, "flt", "p2", 2, EpisodeStatus.PENDING)
    _seed_one(ctx, "flt", "fail1", 3, EpisodeStatus.FAILED)
    _seed_one(ctx, "flt", "done1", 4, EpisodeStatus.DONE)
    _seed_one(ctx, "flt", "skip1", 5, EpisodeStatus.SKIPPED)
    _seed_one(ctx, "flt", "def1", 6, EpisodeStatus.DEFERRED)
    dlg = ShowDetailsDialog(ctx, "flt")
    _keepalive.append(dlg)

    # Unfiltered: all six render.
    assert dlg._episodes_tbl.rowCount() == 6

    # Filter to failed → exactly the one failed row.
    dlg._status_filter = "failed"
    dlg._reload_episodes()
    assert dlg._episodes_tbl.rowCount() == 1
    assert dlg._episodes_tbl.item(0, 0).data(Qt.ItemDataRole.UserRole) == "fail1"

    # Back to All (None) → every row again.
    dlg._status_filter = None
    dlg._reload_episodes()
    assert dlg._episodes_tbl.rowCount() == 6


def test_status_filter_combo_drives_reload(qapp, tmp_path):
    """Driving the combo's text updates `_status_filter` and the table."""
    from core.state import EpisodeStatus
    from ui.show_details_dialog import ShowDetailsDialog

    show = Show(slug="cmb", title="Cmb", rss="https://feed", source="podcast")
    ctx = _make_ctx(tmp_path, show)
    _seed_one(ctx, "cmb", "p1", 1, EpisodeStatus.PENDING)
    _seed_one(ctx, "cmb", "fail1", 2, EpisodeStatus.FAILED)
    dlg = ShowDetailsDialog(ctx, "cmb")
    _keepalive.append(dlg)

    assert dlg._status_filter is None
    dlg._status_filter_combo.setCurrentText("failed")
    assert dlg._status_filter == "failed"
    assert dlg._episodes_tbl.rowCount() == 1
    assert dlg._episodes_tbl.item(0, 0).data(Qt.ItemDataRole.UserRole) == "fail1"

    dlg._status_filter_combo.setCurrentText("All")
    assert dlg._status_filter is None
    assert dlg._episodes_tbl.rowCount() == 2
