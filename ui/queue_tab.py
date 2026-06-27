"""Queue tab — live view of pending/in-flight episodes + progress summary."""

from __future__ import annotations

from datetime import datetime, timedelta

from PyQt6.QtCore import QItemSelection, QItemSelectionModel, Qt, QTimer
from PyQt6.QtWidgets import (
    QComboBox,
    QHBoxLayout,
    QLabel,
    QMenu,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from core.state import EpisodeStatus
from ui.activity_log import log as log_activity
from ui.prioritize import (
    PRIORITY_RUN_NEXT,
    PRIORITY_RUN_NOW,
    bump_priority,
    can_bump,
)
from ui.retranscribe import retranscribe_episode
from ui.widgets.queue_hero import QueueHero


class _SortKeyItem(QTableWidgetItem):
    """Table cell that sorts by an underlying numeric key, not its text.

    Used for the queue's temporal columns — Pub Date, Audio, Whisper,
    Finish ≈ — whose human-friendly display strings (``Mon 14:30``,
    ``10:00``, ISO dates) order wrongly under Qt's text sort: ``Fri``
    before ``Mon`` chronologically, ``"10:00" < "9:00"`` for durations.
    Each cell carries a numeric key (seconds / epoch) so the column
    orders by real time. Rows with no value (``—`` / unparseable) carry
    ``inf`` and sink to the bottom of an ascending sort.
    """

    def __init__(self, text: str, sort_key: float) -> None:
        super().__init__(text)
        self._sort_key = sort_key

    def __lt__(self, other: QTableWidgetItem) -> bool:
        other_key = getattr(other, "_sort_key", None)
        if other_key is None:
            return super().__lt__(other)
        return self._sort_key < other_key


class QueueTab(QWidget):
    """Shows current queue + progress header with started/elapsed/ETA.

    The worker thread only lives while a check runs. When no thread is active,
    the queue table shows all `pending` episodes; status header shows totals
    from the state DB.
    """

    def __init__(self, ctx):
        super().__init__()
        self.ctx = ctx
        self._total = 0
        self._done = 0
        self._started_at: datetime | None = None
        self._episode_durations: list[float] = []
        self._last_ep_start: datetime | None = None

        v = QVBoxLayout(self)

        # Single toolbar at the top — Start / Pause / Stop / Refresh /
        # Remove all. Pre-2026-04-23 these lived at the bottom of the
        # page AND duplicated Pause+Stop on the hero card; consolidated
        # here so the hero only renders state, never actions.
        # Margins explicitly zeroed so the first button's x-position
        # exactly matches the same toolbar in Shows + Failed (Qt's
        # implicit defaults aren't always identical across QHBoxLayout
        # instances built in different files / construction orders).
        h = QHBoxLayout()
        h.setContentsMargins(0, 0, 0, 0)
        self.start_btn = QPushButton("Start")
        self.start_btn.clicked.connect(self._start)
        self.pause_btn = QPushButton("Pause")
        self.pause_btn.clicked.connect(self._pause)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(self._stop)
        refresh = QPushButton("Refresh")
        refresh.clicked.connect(self.refresh)
        # Empties the queue — marks every pending/in-flight episode as
        # done so the worker stops picking them up. Confirm dialog
        # because there's no undo.
        self.clear_btn = QPushButton("Remove all items from queue")
        self.clear_btn.clicked.connect(self._clear_queue)
        # Two-stage Stop bookkeeping. First click → graceful (current
        # transcription finishes, worker exits between episodes). Second
        # click → force-stop, kills running whisper-cli + yt-dlp + the
        # worker QThread.
        self._stop_pressed_once = False
        for b in (self.start_btn, self.pause_btn, self.stop_btn, refresh, self.clear_btn):
            h.addWidget(b)
        h.addStretch()
        # Queue order — takes effect on the next claim (worker reads the
        # setting per claim). Whitelisted values map to claim ORDER BY.
        h.addWidget(QLabel("Order:"))
        self.order_combo = QComboBox()
        for label, value in (
            ("Oldest first", "oldest_first"),
            ("Newest first", "newest_first"),
            ("Shortest first", "shortest_first"),
        ):
            self.order_combo.addItem(label, value)
        cur = getattr(self.ctx.settings, "queue_order", "oldest_first")
        idx = self.order_combo.findData(cur)
        self.order_combo.setCurrentIndex(idx if idx >= 0 else 0)
        self.order_combo.currentIndexChanged.connect(self._on_order_changed)
        h.addWidget(self.order_combo)
        v.addLayout(h)

        # Big-visible hero dashboard — always-visible state card (idle =
        # grey ring + dashes; active = colored ring + live stats).
        self.hero = QueueHero(ctx, parent=self)
        v.addWidget(self.hero)

        # Header — status summary
        self.header = QLabel()
        self.header.setStyleSheet(
            "padding:8px 12px; background:palette(alternate-base); border-radius:4px;"
        )
        self.header.setTextFormat(Qt.TextFormat.RichText)
        v.addWidget(self.header)

        # Table of pending episodes
        self.table = QTableWidget(0, 8)
        self.table.setHorizontalHeaderLabels(
            [
                "Show",
                "Pub Date",
                "Ep#",
                "Title",
                "Status",
                "Audio",
                "Whisper",
                "Finish ≈",
            ]
        )
        # Select whole rows (not single cells) and allow multi-select, so the
        # context-menu actions can act on every selected episode at once.
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)
        from ui.widgets.resizable_header import make_resizable

        # Columns: 0 Show, 1 Pub Date, 2 Ep#, 3 Title (stretch),
        # 4 Status (fixed — live "transcribing · NN%" would jitter
        # under any content-fit policy), 5 Audio, 6 Whisper, 7 Finish ≈.
        make_resizable(
            self.table,
            settings_key="queue/columns",
            stretch_col=3,
            fixed_cols={4: 150},
            defaults={0: 120, 1: 100, 2: 50, 5: 70, 6: 80, 7: 90},
        )
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._on_context_menu)
        # Click-to-sort on column headers. The Queue's natural order is
        # priority+date so users get the worker order by default; turning
        # sorting on lets them re-sort by Show / Status / etc. ad-hoc.
        self.table.setSortingEnabled(True)
        self.table.horizontalHeader().setSortIndicatorShown(True)
        # Status column (col 4) gets a custom 3-way cycle on click:
        #   priority (default) → ascending → descending → priority …
        # Qt's natural toggle would only flip asc↔desc; users asked for
        # the third state to restore the pipeline-stage default order
        # (transcribing → downloading → downloaded → pending) without
        # having to click another column to "unsort" Status.
        self._status_sort_mode = "priority"
        self.table.horizontalHeader().sectionClicked.connect(self._on_header_clicked)
        v.addWidget(self.table)

        from ui.widgets.empty_state import EmptyState

        self.empty_state = EmptyState(
            title="Nothing in the queue",
            hint="Run a check (Start) or queue episodes from a show to see them here.",
        )
        v.addWidget(self.empty_state)
        self.empty_state.setVisible(False)

        # (Buttons already created above as the top toolbar — _update_btns
        # syncs their enabled/text state from the queue's current run-state.)
        self._update_btns()

        self._tick_timer = QTimer(self)
        self._tick_timer.timeout.connect(self._tick)
        self._tick_timer.start(1000)

        # Table rebuild throttle: coalesce refresh requests so we rebuild
        # at most once per 3 s even when episodes finish in bursts.
        self._last_table_refresh = 0.0
        self._refresh_pending = False

        self.refresh()

    def _tick(self):
        # Header + buttons are cheap (no SQL). Table refresh moved to a
        # slower 3 s tick to stop the 1 Hz full-rebuild-of-400+-rows from
        # dominating the event loop.
        self._tick_header()
        self._update_btns()
        import time as _t

        now = _t.monotonic()
        # Table refresh: only if 3 s have passed since the last one. The
        # previous code fired refresh() every second and relied on the
        # internal coalesce; that still queried + rebuilt 400+ rows
        # whenever it landed. Skipping the call entirely when within the
        # window is the actual win.
        if now - getattr(self, "_last_table_refresh", 0.0) > 3.0:
            self.refresh()

    # ── public hooks wired from ShowsTab/worker ───────────────

    def on_queue_sized(self, total: int) -> None:
        self._total = total
        self._done = 0
        self._started_at = datetime.now()
        self._episode_durations = []
        self._last_ep_start = datetime.now()
        self.refresh()

    def on_episode_done(
        self,
        slug: str,
        guid: str,
        action: str,
        done_idx: int,
        total: int,
        show_title: str,
        ep_title: str,
    ) -> None:
        self._done = done_idx
        self._total = total
        now = datetime.now()
        if self._last_ep_start is not None:
            self._episode_durations.append((now - self._last_ep_start).total_seconds())
            self._episode_durations = self._episode_durations[-10:]
        self._last_ep_start = now
        self.refresh()

    def on_finished_all(self) -> None:
        self._last_ep_start = None
        self.refresh()
        self._update_btns()

    def _shows_tab(self):
        return self.window().shows_tab  # MainWindow exposes shows_tab

    def _start(self):
        # If paused, resume (clears paused flag); else just start a check.
        paused = self.ctx.state.get_meta("queue_paused") == "1"
        if paused:
            self.ctx.state.set_meta("queue_paused", "0")
        log_activity("Resumed the queue" if paused else "Started the queue")
        # Queue tab Start is always user-initiated → bypass feed backoff.
        self._shows_tab().start_check(force=True)
        self._update_btns()

    def _pause(self):
        log_activity("Paused the queue")
        self._shows_tab()._pause()
        self._update_btns()

    def _stop(self):
        # Dual-stage: graceful first, force on the second click.
        if not self._stop_pressed_once:
            self._stop_pressed_once = True
            log_activity("Stopping the queue (graceful — finishing the current episode)")
            self._shows_tab()._stop()
            self.stop_btn.setText("Stop now (force)")
            self.stop_btn.setEnabled(True)  # keep clickable for the force step
            return
        # Force-stop: kill any running whisper-cli + yt-dlp subprocesses
        # so the in-flight transcription / download dies immediately.
        # Then terminate the worker QThread as a last resort.
        self._stop_pressed_once = False
        self.stop_btn.setText("Stop")
        log_activity("Force-stopped the queue (killed running whisper-cli / yt-dlp)")
        try:
            import subprocess

            subprocess.run(["pkill", "-9", "-f", "whisper-cli"], capture_output=True, check=False)
            subprocess.run(["pkill", "-9", "-f", "yt-dlp"], capture_output=True, check=False)
        except Exception:
            pass
        try:
            t = self._shows_tab()._thread
            if t is not None and t.isRunning():
                t.terminate()
                t.wait(2000)
        except Exception:
            pass
        # Reset stranded in-flight rows so the user can re-trigger cleanly.
        try:
            self.ctx.state.recover_in_flight()
        except Exception:
            pass
        self.ctx.queue.running = False
        self._update_btns()
        self.refresh()

    def _clear_queue(self):
        from PyQt6.QtWidgets import QMessageBox

        # SQL counts up the rows that will be touched so the dialog is honest.
        with self.ctx.state._conn() as c:
            row = c.execute(
                "SELECT COUNT(*) AS n FROM episodes "
                "WHERE status IN ('pending','downloading','downloaded','transcribing')"
            ).fetchone()
        n = int(row["n"] or 0) if row else 0
        if n == 0:
            QMessageBox.information(self, "Queue is already empty", "Nothing to remove.")
            return
        reply = QMessageBox.question(
            self,
            "Remove all items from queue",
            f"Mark all {n} pending / in-flight episode(s) as done? "
            "They won't be picked up again. Existing transcripts are kept.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return
        # Snapshot before clearing so the action is undoable (9.5).
        snapshot = self.ctx.state.snapshot_statuses(
            ["pending", "downloading", "downloaded", "transcribing"]
        )
        moved = self.ctx.state.clear_pending()

        def _undo() -> None:
            self.ctx.state.restore_statuses(snapshot)
            self._last_table_refresh = 0.0
            self.refresh()

        from ui.undo import manager as undo_manager

        undo_manager.push(f"Cleared the queue ({moved} episode(s))", _undo)
        log_activity(f"Cleared the queue ({moved} episode(s) marked done) — Undo available (⌘Z)")
        self._last_table_refresh = 0.0
        self.refresh()
        QMessageBox.information(
            self, "Queue cleared", f"{moved} episode(s) removed from the queue."
        )

    def _on_order_changed(self, _idx: int) -> None:
        """Persist the chosen queue order; the worker reads it on the next claim."""
        value = self.order_combo.currentData() or "oldest_first"
        if getattr(self.ctx.settings, "queue_order", "oldest_first") == value:
            return
        self.ctx.settings.queue_order = value
        try:
            self.ctx.settings.save(self.ctx.data_dir / "settings.yaml")
        except Exception:
            pass
        log_activity(f"Queue order set to {value}")

    def _update_btns(self):
        from core.queue_status import queue_ui_state

        running = self.ctx.queue.running
        paused = self.ctx.state.get_meta("queue_paused") == "1"
        state = queue_ui_state(queue_paused=paused, running=running)

        # idle: Start | running: Pause/Stop | pausing: drain in progress |
        # paused: Resume (drained, halted).
        self.start_btn.setEnabled(state in ("idle", "paused"))
        self.start_btn.setText("Resume" if state == "paused" else "Start")
        if state == "pausing":
            self.pause_btn.setText("Pausing…")
            self.pause_btn.setEnabled(False)
        else:
            self.pause_btn.setText("Pause")
            self.pause_btn.setEnabled(state == "running")
        # Stop stays available while the worker runs (incl. pausing) so
        # the user can still force-abort the in-flight episode.
        self.stop_btn.setEnabled(state in ("running", "pausing"))
        if not running and self._stop_pressed_once:
            self._stop_pressed_once = False
            self.stop_btn.setText("Stop")

    # ── rendering ─────────────────────────────────────────────

    def refresh(self) -> None:
        import time

        now = time.monotonic()
        self._tick_header()
        if now - self._last_table_refresh < 3.0:
            if not self._refresh_pending:
                self._refresh_pending = True
                delay_ms = int((3.0 - (now - self._last_table_refresh)) * 1000)
                QTimer.singleShot(max(delay_ms, 0), self._deferred_refresh)
            return
        self._last_table_refresh = now
        self._refresh_table()

    def _deferred_refresh(self) -> None:
        import time

        self._refresh_pending = False
        self._last_table_refresh = time.monotonic()
        self._refresh_table()
        self._tick_header()

    def _tick_header(self) -> None:
        self.header.setText(self._format_header())

    def _format_header(self) -> str:
        with self.ctx.state._conn() as c:
            status_counts = {}
            for row in c.execute("SELECT status, COUNT(*) FROM episodes GROUP BY status"):
                status_counts[row[0]] = row[1]
        pending_total = status_counts.get("pending", 0)
        done_total = status_counts.get("done", 0)
        failed = status_counts.get("failed", 0)

        if self._started_at is None or self._total == 0:
            return (
                f"<b>Queue</b> — pending: {pending_total} · "
                f"done: {done_total} · failed: {failed} · "
                "<i>idle (click Start on any tab to run)</i>"
            )

        elapsed = datetime.now() - self._started_at
        live_avg = (
            sum(self._episode_durations) / len(self._episode_durations)
            if self._episode_durations
            else 0
        )
        # Fall back to shared state — its historical DB estimate is populated
        # at start_check so "finish ≈" is shown from t=0.
        avg = live_avg or self.ctx.queue.effective_avg_sec
        remaining = self._total - self._done
        # Prefer duration-based ETA (pending audio × realtime factor)
        # when available — the per-episode average is a last resort.
        duration_eta = self.ctx.queue.duration_based_eta_sec
        if duration_eta > 0:
            eta_sec = duration_eta
        else:
            eta_sec = avg * remaining if avg else 0
        finish_at = datetime.now() + timedelta(seconds=eta_sec) if eta_sec else None

        from core.stats import has_realtime_history
        from ui.main_window import _fmt_dt_locale

        parts = [
            f"<b>Running</b>: {self._done}/{self._total}",
            f"started: {_fmt_dt_locale(self._started_at)}",
            f"elapsed: {_fmt_duration(elapsed.total_seconds())}",
        ]
        if avg:
            per_ep_tag = "avg/ep" if live_avg else "est/ep"
            eta_tag = "ETA" if live_avg else "ETA (est.)"
            parts.append(f"{per_ep_tag}: {avg:.0f}s")
            parts.append(f"{eta_tag}: {_fmt_duration(eta_sec)}")
            if finish_at:
                parts.append(f"finish ≈ {_fmt_dt_locale(finish_at)}")
        elif not has_realtime_history(self.ctx.state):
            parts.append("<i>ETA available once the first episode completes</i>")
        return " · ".join(parts)

    def _refresh_table(self) -> None:
        from datetime import datetime, timedelta

        from core.stats import realtime_factor

        rtf = realtime_factor(self.ctx.state)
        cumulative_wall = 0.0  # seconds already committed above this row
        now = datetime.now()

        with self.ctx.state._conn() as c:
            rows = c.execute(
                "SELECT show_slug, pub_date, title, status, guid, duration_sec "
                "FROM episodes "
                # 'paused' rows stay visible in the queue but the worker never
                # claims them (its claim query is status='pending').
                "WHERE status IN "
                "('pending','downloading','downloaded','transcribing','paused') "
                # Default sort = pipeline-stage order so the user sees
                # whatever's actively burning CPU at the top:
                #   transcribing → downloading → downloaded → pending.
                # Within pending, follow the worker's DB-claim order
                # (priority DESC, pub_date ASC) so the table reflects
                # exactly what runs next. The user can override this by
                # clicking the Status column header (cycles
                # priority→asc→desc); when they do, _on_status_header_clicked
                # delegates to Qt's QTableWidget.sortItems and we keep
                # this SQL order as the "priority" reset.
                "ORDER BY "
                "  CASE status "
                "    WHEN 'transcribing' THEN 0 "
                "    WHEN 'downloading'  THEN 1 "
                "    WHEN 'downloaded'   THEN 2 "
                "    WHEN 'paused'       THEN 4 "  # deactivated → sink below active
                "    ELSE 3 "
                "  END, "
                "  priority DESC, pub_date ASC"
            ).fetchall()
        # Preserve the user's row selection across this periodic rebuild — the
        # table is wiped + repopulated, which would otherwise silently drop it
        # after a few seconds even though the user hasn't clicked away.
        selected_guids = set(self._selected_guids())
        # Sorting must be off during repopulation — Qt re-sorts on every
        # setItem when enabled, scrambling row indices and leaving cells
        # past column 0 empty. Restore at the end.
        was_sorting = self.table.isSortingEnabled()
        self.table.setSortingEnabled(False)
        self.table.setRowCount(0)
        for r in rows:
            row = self.table.rowCount()
            self.table.insertRow(row)
            show_item = QTableWidgetItem(r["show_slug"])
            # Stash the guid on the first-column item so the context menu
            # can retrieve it via UserRole data.
            show_item.setData(Qt.ItemDataRole.UserRole, r["guid"])
            self.table.setItem(row, 0, show_item)
            self.table.setItem(
                row, 1, _SortKeyItem(r["pub_date"], _pub_date_sort_key(r["pub_date"]))
            )
            self.table.setItem(row, 2, QTableWidgetItem(""))  # episode_number not in state
            self.table.setItem(row, 3, QTableWidgetItem(r["title"]))
            # Status column — for transcribing rows, read the live
            # percent meta written by core.pipeline.transcribe_phase.
            status_text = r["status"]
            if status_text == "transcribing":
                pct = self.ctx.state.get_meta(f"transcribe_pct:{r['guid']}") or ""
                if pct.isdigit():
                    status_text = f"transcribing · {pct}%"
            status_item = QTableWidgetItem(status_text)
            status_item.setTextAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
            self.table.setItem(row, 4, status_item)

            # Audio length (mm:ss or h:mm:ss) — sort by seconds, not text.
            dur_sec = int(r["duration_sec"] or 0)
            self.table.setItem(
                row,
                5,
                _SortKeyItem(_fmt_hms(dur_sec), dur_sec)
                if dur_sec
                else _SortKeyItem("—", float("inf")),
            )
            # Whisper wall-clock estimate (audio × realtime_factor)
            whisper_sec = int(dur_sec * rtf) if dur_sec else 0
            self.table.setItem(
                row,
                6,
                _SortKeyItem(_fmt_hms(whisper_sec), whisper_sec)
                if whisper_sec
                else _SortKeyItem("—", float("inf")),
            )
            # Finish ≈ — cumulative, so row N reflects "done after all
            # earlier rows in the queue have finished".
            if whisper_sec:
                cumulative_wall += whisper_sec
                finish_at = now + timedelta(seconds=cumulative_wall)
                self.table.setItem(row, 7, _SortKeyItem(_fmt_finish(finish_at), cumulative_wall))
            else:
                self.table.setItem(row, 7, _SortKeyItem("—", float("inf")))
        # Restore click-to-sort after the bulk insertion completes.
        self.table.setSortingEnabled(was_sorting)
        empty = self.table.rowCount() == 0
        self.empty_state.setVisible(empty)
        self.table.setVisible(not empty)
        if selected_guids:
            self._reselect_guids(selected_guids)

    def _reselect_guids(self, guids: set[str]) -> None:
        """Re-apply a row selection (by guid) after the table was rebuilt."""
        model = self.table.model()
        last_col = self.table.columnCount() - 1
        sel = QItemSelection()
        for row in range(self.table.rowCount()):
            it = self.table.item(row, 0)
            g = it.data(Qt.ItemDataRole.UserRole) if it is not None else None
            if g in guids:
                sel.select(model.index(row, 0), model.index(row, last_col))
        if not sel.isEmpty():
            self.table.selectionModel().select(
                sel,
                QItemSelectionModel.SelectionFlag.Select | QItemSelectionModel.SelectionFlag.Rows,
            )

    # ── status column 3-way sort ──────────────────────────────

    _STATUS_COL = 4

    def _on_header_clicked(self, col: int) -> None:
        """Status column cycles priority → asc → desc → priority. Other
        columns fall through to Qt's built-in sort (already triggered by
        the click since ``setSortingEnabled(True)``)."""
        if col != self._STATUS_COL:
            # User clicked a different column — that's a regular Qt
            # sort. Reset our Status state so the next Status click
            # starts fresh from the priority ordering.
            self._status_sort_mode = "priority"
            return
        # Cycle: Qt has already produced asc on the 1st click and desc
        # on the 2nd click via its natural toggle. The 3rd click is
        # where we override — undo Qt's sort by repopulating from SQL
        # and clear the indicator.
        from PyQt6.QtCore import Qt as _Qt

        if self._status_sort_mode == "priority":
            self._status_sort_mode = "asc"
            # Qt already did the asc sort.
        elif self._status_sort_mode == "asc":
            self._status_sort_mode = "desc"
            # Qt already did the desc sort.
        else:
            self._status_sort_mode = "priority"
            self.refresh()
            # -1 hides the sort indicator, signalling "natural order".
            self.table.horizontalHeader().setSortIndicator(-1, _Qt.SortOrder.AscendingOrder)

    # ── context menu ──────────────────────────────────────────

    def _selected_guids(self) -> list[str]:
        """Guids of every selected row (stashed on the col-0 item's UserRole)."""
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
        if item is None:
            return
        guid = item.data(Qt.ItemDataRole.UserRole)
        if not guid:
            return
        # Act on the WHOLE selection when the right-clicked row is part of it;
        # otherwise act on just the row under the cursor.
        selected = self._selected_guids()
        guids = selected if guid in selected else [guid]
        status_item = self.table.item(index.row(), 4)
        status = status_item.text() if status_item is not None else ""
        is_paused = status.lower().startswith("paused")
        sfx = f" ({len(guids)})" if len(guids) > 1 else ""
        menu = QMenu(self)
        menu.addAction(
            f"Re-transcribe{sfx}",
            lambda gs=guids: self._retranscribe(gs),
        )
        if can_bump(status):
            menu.addSeparator()
            menu.addAction(f"Run next{sfx}", lambda gs=guids: self._bump(gs, PRIORITY_RUN_NEXT))
            menu.addAction(f"Run now{sfx}", lambda gs=guids: self._bump(gs, PRIORITY_RUN_NOW))
            menu.addAction(f"Move to top of queue{sfx}", lambda gs=guids: self._move_to_top(gs))
            menu.addAction(
                f"Move to bottom of queue{sfx}", lambda gs=guids: self._move_to_bottom(gs)
            )
        menu.addSeparator()
        if is_paused:
            menu.addAction(
                f"Activate (resume in queue){sfx}",
                lambda gs=guids: self._set_episode_status(gs, EpisodeStatus.PENDING),
            )
        else:
            menu.addAction(
                f"Deactivate (keep in queue, don't process){sfx}",
                lambda gs=guids: self._set_episode_status(gs, EpisodeStatus.PAUSED),
            )
        menu.addSeparator()
        menu.addAction(f"Pause download{sfx}", lambda gs=guids: self._set_download_paused(gs, True))
        menu.addAction(
            f"Resume download{sfx}", lambda gs=guids: self._set_download_paused(gs, False)
        )
        menu.addAction(
            f"Remove from queue{sfx}",
            lambda gs=guids: self._remove_from_queue(gs),
        )
        menu.exec(self.table.viewport().mapToGlobal(pos))

    def _set_download_paused(self, guids: list[str], paused: bool) -> None:
        """Set/clear the per-download pause flag (2.4). A paused in-flight
        download halts (leaving a .part) and parks the episode as PAUSED; resume
        clears the flag and re-queues it (PENDING) so it continues from the .part."""
        for g in guids:
            self.ctx.state.set_meta(f"download_paused:{g}", "1" if paused else "0")
            if not paused:
                # Only un-park episodes parked by a pause; never disturb others.
                ep = self.ctx.state.get_episode(g)
                if ep and ep.get("status") == EpisodeStatus.PAUSED.value:
                    self.ctx.state.set_status(g, EpisodeStatus.PENDING)
        verb = "Paused" if paused else "Resumed"
        log_activity(f"{verb} download for {len(guids)} episode(s)")
        self._last_table_refresh = 0.0
        self.refresh()

    def _move_to_top(self, guids: list[str]) -> None:
        """Persist a stable manual order for the selected episodes at the top of
        the queue (2.1) via priority, then refresh."""
        self.ctx.state.set_priorities(list(guids))
        log_activity(f"Moved {len(guids)} episode(s) to the top of the queue")
        self._last_table_refresh = 0.0
        self.refresh()

    def _move_to_bottom(self, guids: list[str]) -> None:
        """Sink the selected episodes below everything else in the queue (2.1)."""
        self.ctx.state.move_to_bottom(list(guids))
        log_activity(f"Moved {len(guids)} episode(s) to the bottom of the queue")
        self._last_table_refresh = 0.0
        self.refresh()

    def _set_episode_status(self, guids: list[str], status: EpisodeStatus) -> None:
        """Flip status (e.g. pending↔paused) on every given episode; refresh once."""
        for g in guids:
            self.ctx.state.set_status(g, status)
        if status == EpisodeStatus.PAUSED:
            verb = "Deactivated"
        elif status == EpisodeStatus.PENDING:
            verb = "Reactivated"
        else:
            verb = f"Set to {status.value}:"
        log_activity(f"{verb} {len(guids)} episode(s) in the queue")
        self._last_table_refresh = 0.0
        self.refresh()

    def _remove_from_queue(self, guids: list[str]) -> None:
        """Soft-delete from the queue: mark each episode ``skipped`` so it leaves
        the active queue and the daily feed-poll won't re-queue it (upsert
        preserves status). They stay in the per-show episode browser as
        ``skipped`` and can be re-queued from there."""
        for g in guids:
            self.ctx.state.set_status(g, EpisodeStatus.SKIPPED)
        log_activity(f"Removed {len(guids)} episode(s) from the queue")
        self._last_table_refresh = 0.0
        self.refresh()

    def _retranscribe(self, guids: list[str]) -> None:
        for g in guids:
            retranscribe_episode(self.ctx, g)
        log_activity(f"Re-queued {len(guids)} episode(s) for transcription")
        # Kick the worker so the bumped re-transcribes run next instead of
        # waiting for the next scheduled pass.
        try:
            self._shows_tab().start_check(force=True)
        except Exception:
            pass
        self._last_table_refresh = 0.0
        self.refresh()

    def _bump(self, guids: list[str], priority: int) -> None:
        for g in guids:
            bump_priority(self.ctx, g, priority)
        # Kick the worker so the bump takes effect immediately. Without
        # this, the priority is set in SQL but the worker only re-queries
        # on its next scheduled pass.
        try:
            self._shows_tab().start_check(force=True)
        except Exception:
            pass
        # Force a full rebuild so the new sort order is reflected immediately,
        # bypassing the 3-second refresh coalescing.
        import time

        self._last_table_refresh = time.monotonic()
        self._refresh_table()


def _fmt_duration(sec: float) -> str:
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m {sec % 60}s"
    h = sec // 3600
    m = (sec % 3600) // 60
    return f"{h}h {m}m"


def _fmt_hms(sec: int) -> str:
    """Compact mm:ss for <1h, h:mm:ss otherwise."""
    sec = max(0, int(sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def _pub_date_sort_key(s: str) -> float:
    """Chronological sort key for a stored pub_date string.

    Values are normally ISO (``YYYY-MM-DD`` or ``YYYY-MM-DDTHH:MM:SS``),
    which already sort lexically; but feeds can leave a raw non-ISO
    fallback that would sort wrongly. Parse to epoch seconds, retrying on
    the date prefix; anything unparseable returns ``inf`` so it sinks to
    the bottom of an ascending sort.
    """
    if not s:
        return float("inf")
    for candidate in (s, s[:10]):
        try:
            return datetime.fromisoformat(candidate).timestamp()
        except ValueError:
            continue
    return float("inf")


def _fmt_finish(dt) -> str:
    """HH:MM today; 'Mon HH:MM' when future day."""
    from datetime import datetime

    now = datetime.now()
    if dt.date() == now.date():
        return dt.strftime("%H:%M")
    if (dt.date() - now.date()).days < 7:
        return dt.strftime("%a %H:%M")
    return dt.strftime("%b %d %H:%M")
