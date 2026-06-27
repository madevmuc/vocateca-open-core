"""Failed queue tab."""

from __future__ import annotations

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QHBoxLayout,
    QMenu,
    QMessageBox,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from core.state import EpisodeStatus

_REASON_MAP = {
    "SSRFGuardError": "ssrf-guard: private IP",
    "FileTooLargeError": "mp3 > 2GB cap",
    "HashMismatch": "model hash mismatch",
    "TranscriptionError": None,  # None = keep underlying message
    "TimeoutError": "whisper timed out",
}


def _humanise_reason(err: str) -> str:
    if not err:
        return ""
    for key, replacement in _REASON_MAP.items():
        if key in err:
            return replacement or err.split("\n", 1)[0][:120]
    return err.split("\n", 1)[0][:120]


class FailedTab(QWidget):
    def __init__(self, ctx):
        super().__init__()
        self.ctx = ctx
        v = QVBoxLayout(self)

        # Toolbar above the table — preserves the existing bulk actions.
        # Zero contentsMargins so the first button's x-position lines
        # up with the equivalent toolbar in Queue + Shows.
        h = QHBoxLayout()
        h.setContentsMargins(0, 0, 0, 0)
        retry_all = QPushButton("Retry all")
        retry_all.clicked.connect(self._retry_all)
        add_q = QPushButton("Add failed to queue")
        add_q.clicked.connect(self._add_all_to_queue)
        push_top = QPushButton("Push failed on top of queue")
        push_top.clicked.connect(self._push_on_top)
        play = QPushButton("Play MP3")
        play.clicked.connect(self._play_selected)
        play.setToolTip(
            "Open the partial MP3 of the selected row in the default audio app for a spot-check."
        )
        clean = QPushButton("Clear older than 30 days")
        clean.clicked.connect(self._clear_old)
        refresh = QPushButton("Refresh")
        refresh.clicked.connect(self.refresh)
        for b in (retry_all, add_q, push_top, play, clean, refresh):
            h.addWidget(b)
        h.addStretch()
        v.addLayout(h)

        self.table = QTableWidget(0, 6)
        self.table.setHorizontalHeaderLabels(
            ["Show", "Episode", "Reason", "Tries", "Last attempt", ""]
        )
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        # Right-click context menu (mirrors the per-row ⋯ button; acts on every
        # selected row for the bulk-friendly actions).
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._on_context_menu)

        from ui.widgets.resizable_header import make_resizable

        # Columns: 0 Show, 1 Episode (stretch — varies most), 2 Reason
        # (was a second Stretch — only one column can effectively absorb
        # spare space, so this drops to Interactive with a generous
        # default), 3 Tries, 4 Last attempt, 5 ⋯ menu button (fixed).
        make_resizable(
            self.table,
            settings_key="failed/columns",
            stretch_col=1,
            fixed_cols={5: 40},
            defaults={0: 140, 2: 280, 3: 60, 4: 150},
        )
        # Click-to-sort on column headers. Disabled during refresh()
        # population (Qt re-sorts on every setItem) and re-enabled after.
        self.table.setSortingEnabled(True)
        self.table.horizontalHeader().setSortIndicatorShown(True)
        v.addWidget(self.table)

        from ui.widgets.empty_state import EmptyState

        self.empty_state = EmptyState(
            title="Nothing failed 🎉",
            hint="Episodes that fail to download or transcribe will show up here.",
        )
        v.addWidget(self.empty_state)
        self.empty_state.setVisible(False)

        # guid → raw error text, for Copy-error / Show-log handlers.
        self._errors: dict[str, str] = {}

        self.refresh()

    def refresh(self):
        with self.ctx.state._conn() as c:
            rows = c.execute(
                "SELECT show_slug, guid, title, attempted_at, error_text, "
                "error_category, attempts "
                "FROM episodes WHERE status='failed' ORDER BY attempted_at DESC"
            ).fetchall()
        # Sorting must be off during repopulation — Qt re-sorts on every
        # setItem when enabled, scrambling row indices and leaving cells
        # past column 0 empty. Restore at the end.
        was_sorting = self.table.isSortingEnabled()
        self.table.setSortingEnabled(False)
        self.table.setRowCount(0)
        self._errors.clear()
        for r in rows:
            guid = r["guid"]
            row_error = r["error_text"] or ""
            self._errors[guid] = row_error
            row = self.table.rowCount()
            self.table.insertRow(row)
            self.table.setItem(row, 0, QTableWidgetItem(r["show_slug"] or ""))
            self.table.setItem(row, 1, QTableWidgetItem(r["title"] or ""))
            category = (r["error_category"] or "").strip()
            reason = _humanise_reason(row_error)
            if category:
                reason = f"[{category}] {reason}"
            self.table.setItem(row, 2, QTableWidgetItem(reason))
            attempts = r["attempts"] if r["attempts"] is not None else 0
            self.table.setItem(row, 3, QTableWidgetItem(str(attempts) if attempts else "—"))
            self.table.setItem(row, 4, QTableWidgetItem(r["attempted_at"] or ""))
            # Stash guid on the row (column 0) for selection-based helpers.
            self.table.item(row, 0).setData(0x0100, guid)  # Qt.ItemDataRole.UserRole

            btn = QPushButton("⋯")
            btn.setFlat(True)
            btn.setFixedWidth(28)
            menu = QMenu(btn)
            a_retry = menu.addAction("Retry")
            a_retry.triggered.connect(lambda _=False, g=guid: self._retry_guid(g))
            a_resolve = menu.addAction("Mark resolved")
            a_resolve.triggered.connect(lambda _=False, g=guid: self._mark_resolved(g))
            a_log = menu.addAction("Show log")
            a_log.triggered.connect(lambda _=False, g=guid: self._show_log(g))
            a_copy = menu.addAction("Copy error")
            a_copy.triggered.connect(lambda _=False, g=guid: self._copy_error(g))
            menu.addSeparator()
            a_skip = menu.addAction("Skip forever")
            a_skip.triggered.connect(lambda _=False, g=guid: self._skip_forever(g))
            btn.setMenu(menu)
            self.table.setCellWidget(row, 5, btn)
        # Restore click-to-sort after the bulk insertion completes.
        self.table.setSortingEnabled(was_sorting)
        # Empty-state: show the friendly placeholder when nothing failed.
        empty = self.table.rowCount() == 0
        self.empty_state.setVisible(empty)
        self.table.setVisible(not empty)

    # --- Right-click context menu ----------------------------------------

    def _selected_guids(self) -> list[str]:
        guids: list[str] = []
        seen: set[str] = set()
        for idx in self.table.selectionModel().selectedRows():
            it = self.table.item(idx.row(), 0)
            g = it.data(Qt.ItemDataRole.UserRole) if it is not None else None
            if g and g not in seen:
                seen.add(g)
                guids.append(g)
        return guids

    def _on_context_menu(self, pos) -> None:
        index = self.table.indexAt(pos)
        if not index.isValid():
            return
        item = self.table.item(index.row(), 0)
        guid = item.data(Qt.ItemDataRole.UserRole) if item is not None else None
        if not guid:
            return
        # Act on the whole selection when the right-clicked row is part of it.
        selected = self._selected_guids()
        guids = selected if guid in selected else [guid]
        sfx = f" ({len(guids)})" if len(guids) > 1 else ""
        menu = QMenu(self)
        menu.addAction(f"Retry{sfx}", lambda gs=guids: self._retry_guids(gs))
        menu.addAction(f"Mark resolved{sfx}", lambda gs=guids: self._mark_resolved_many(gs))
        menu.addSeparator()
        # Per-episode error views act on the row under the cursor only.
        menu.addAction("Show log", lambda g=guid: self._show_log(g))
        menu.addAction("Copy error", lambda g=guid: self._copy_error(g))
        menu.addSeparator()
        menu.addAction(f"Skip forever{sfx}", lambda gs=guids: self._skip_forever_many(gs))
        menu.exec(self.table.viewport().mapToGlobal(pos))

    def _retry_guids(self, guids: list[str]) -> None:
        for g in guids:
            self.ctx.state.set_status(g, EpisodeStatus.PENDING)
        self.refresh()

    def _mark_resolved_many(self, guids: list[str]) -> None:
        for g in guids:
            self.ctx.state.set_status(g, "skipped")  # type: ignore[arg-type]
        self.refresh()

    def _skip_forever_many(self, guids: list[str]) -> None:
        for g in guids:
            self.ctx.state.set_meta(f"skip_forever:{g}", "1")
            self.ctx.state.set_status(g, "skipped")  # type: ignore[arg-type]
        self.refresh()

    # --- Per-row handlers -------------------------------------------------

    def _retry_guid(self, guid: str) -> None:
        self.ctx.state.set_status(guid, EpisodeStatus.PENDING)
        self.refresh()

    def _mark_resolved(self, guid: str) -> None:
        # No SKIPPED value in the enum; write the raw string. set_status's
        # fallback branch handles any status value.
        self.ctx.state.set_status(guid, "skipped")  # type: ignore[arg-type]
        self.refresh()

    def _show_log(self, guid: str) -> None:
        # No per-guid log file exists; surface the captured error text.
        err = self._errors.get(guid) or "(no error text captured)"
        dlg = QMessageBox(self)
        dlg.setWindowTitle("Error log")
        dlg.setIcon(QMessageBox.Icon.Information)
        dlg.setText(f"Episode {guid}")
        dlg.setDetailedText(err)
        dlg.exec()

    def _copy_error(self, guid: str) -> None:
        QApplication.clipboard().setText(self._errors.get(guid, ""))

    def _skip_forever(self, guid: str) -> None:
        # Permanent-skip flag in meta, then mark skipped. Retry-all paths
        # can consult skip_forever:<guid> if they want to honour it.
        self.ctx.state.set_meta(f"skip_forever:{guid}", "1")
        self.ctx.state.set_status(guid, "skipped")  # type: ignore[arg-type]
        self.refresh()

    # --- Existing bulk handlers (preserved) -------------------------------

    def _play_selected(self):
        import subprocess
        from pathlib import Path

        rows = {idx.row() for idx in self.table.selectedIndexes()}
        if not rows:
            return
        row = next(iter(rows))
        item = self.table.item(row, 0)
        if item is None:
            return
        guid = item.data(0x0100)
        if not guid:
            return
        with self.ctx.state._conn() as c:
            ep = c.execute(
                "SELECT show_slug, mp3_path FROM episodes WHERE guid=?", (guid,)
            ).fetchone()
        if ep is None:
            return
        mp3 = Path(ep["mp3_path"]) if ep["mp3_path"] else None
        if mp3 and mp3.exists():
            subprocess.run(["open", str(mp3)])

    def _retry_all(self):
        with self.ctx.state._conn() as c:
            c.execute("UPDATE episodes SET status='pending' WHERE status='failed'")
        self.refresh()

    def _clear_old(self):
        with self.ctx.state._conn() as c:
            c.execute(
                "DELETE FROM episodes WHERE status='failed' "
                "AND attempted_at < datetime('now', '-30 days')"
            )
        self.refresh()

    def _add_all_to_queue(self):
        """Mark all failed as pending (priority 0) and kick off a check if idle."""
        with self.ctx.state._conn() as c:
            c.execute("UPDATE episodes SET status='pending', priority=0 WHERE status='failed'")
        self.refresh()
        self._trigger_start()

    def _push_on_top(self):
        """Mark all failed as pending with priority=10 → processed first."""
        with self.ctx.state._conn() as c:
            c.execute("UPDATE episodes SET status='pending', priority=10 WHERE status='failed'")
        self.refresh()
        self._trigger_start()

    def _trigger_start(self):
        # MainWindow exposes .shows_tab, go through it so Stop button wires up.
        win = self.window()
        if hasattr(win, "shows_tab") and not self.ctx.queue.running:
            win.shows_tab.start_check(force=True)
