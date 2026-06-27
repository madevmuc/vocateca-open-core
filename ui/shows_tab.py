"""Shows tab — watchlist management + Check Now."""

from __future__ import annotations

from PyQt6.QtCore import QSettings, Qt
from PyQt6.QtGui import QAction
from PyQt6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QMenu,
    QMessageBox,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from core.watchlist_io import save_watchlist
from ui.app_context import AppContext
from ui.widgets import FilterPopover, Pill

FEED_COL = 6


class ShowsTab(QWidget):
    def __init__(self, ctx: AppContext):
        super().__init__()
        self.ctx = ctx
        self._thread = None
        self.log_sink = None  # set by MainWindow to route progress to LogDock
        self.queue_listener = None  # set by MainWindow — receives queue signals
        self.library_listener = None  # set by MainWindow — Library tab debounced refresh

        layout = QVBoxLayout(self)

        # All toolbars at the top so the action layout matches Queue +
        # Failed (consolidated 2026-04-23). Two rows: always-on actions
        # first, bulk-on-selection second (disabled until rows picked).
        # Zero contentsMargins so the first button's x-position lines
        # up with the equivalent toolbar in Queue + Failed.
        action_row = QHBoxLayout()
        action_row.setContentsMargins(0, 0, 0, 0)
        self.add_btn = QPushButton("Add Podcast / Show…")
        self.add_btn.clicked.connect(self._add)
        self.add_youtube_btn = QPushButton("Add YouTube Channel…")
        self.add_youtube_btn.clicked.connect(self._add_youtube)
        self.curated_btn = QPushButton("Add Episodes…")
        self.curated_btn.clicked.connect(self._curated)
        self.check_btn = QPushButton("Start / Check Now")
        self.check_btn.clicked.connect(self._check)
        self.pause_btn = QPushButton("Pause")
        self.pause_btn.clicked.connect(self._pause)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setEnabled(False)
        self.stop_btn.clicked.connect(self._stop)
        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh)
        self.health_btn = QPushButton("Check feeds")
        self.health_btn.clicked.connect(self._check_feed_health)
        self.retry_failed_feeds_btn = QPushButton("Retry failed feeds")
        self.retry_failed_feeds_btn.setToolTip(
            "Clear backoff and immediately re-fetch every feed currently "
            "marked fail. Useful after fixing a connectivity issue."
        )
        self.retry_failed_feeds_btn.clicked.connect(self._retry_failed_feeds)
        self.rescan_btn = QPushButton("Rescan library")
        self.rescan_btn.clicked.connect(self._rescan_library)
        self.rescan_btn.setToolTip(
            "Count words + durations for all existing transcripts (one-time)"
        )
        for b in (
            self.add_btn,
            self.add_youtube_btn,
            self.curated_btn,
            self.check_btn,
            self.pause_btn,
            self.stop_btn,
            self.refresh_btn,
            self.health_btn,
            self.retry_failed_feeds_btn,
            self.rescan_btn,
        ):
            action_row.addWidget(b)
        action_row.addStretch()
        layout.addLayout(action_row)

        # The dedicated YouTube button only makes sense when YouTube ingestion
        # is enabled — hide it for podcast-only users (matches the Add dialog).
        from core.sources import youtube_enabled

        self.add_youtube_btn.setVisible(youtube_enabled(self.ctx.settings))

        # Bulk-action toolbar — operates on all currently selected rows.
        # Buttons are disabled until the table has a selection.
        bulk_row = QHBoxLayout()
        bulk_row.setContentsMargins(0, 0, 0, 0)
        self._bulk_disable = QPushButton("Disable selected")
        self._bulk_enable = QPushButton("Enable selected")
        self._bulk_stale = QPushButton("Mark stale selected")
        self._bulk_delete = QPushButton("Delete selected")
        self._bulk_delete.setProperty("class", "danger")
        for b, fn in (
            (self._bulk_disable, self._do_bulk_disable),
            (self._bulk_enable, self._do_bulk_enable),
            (self._bulk_stale, self._do_bulk_stale),
            (self._bulk_delete, self._do_bulk_delete),
        ):
            b.setEnabled(False)
            b.clicked.connect(fn)
            bulk_row.addWidget(b)
        bulk_row.addStretch()
        layout.addLayout(bulk_row)

        self.global_stats_label = QLabel()
        self.global_stats_label.setStyleSheet(
            "padding:8px 12px; background:palette(alternate-base); border-radius:4px;"
        )
        self.global_stats_label.setTextFormat(Qt.TextFormat.RichText)
        layout.addWidget(self.global_stats_label)

        # Filter toolbar — summary label on the left, filter button + count
        # pill on the right. The legacy standalone QLineEdit search was
        # folded into FilterPopover's "search" field.
        filter_row = QHBoxLayout()
        self._summary = QLabel()
        self._summary.setProperty("class", "muted")
        filter_row.addWidget(self._summary)
        filter_row.addStretch()
        self._filter_count_pill = Pill("0", kind="ok")
        self._filter_count_pill.hide()
        self._filter_btn = QPushButton("▾ Filter")
        self._filter_btn.clicked.connect(self._open_filter_popover)
        filter_row.addWidget(self._filter_count_pill)
        filter_row.addWidget(self._filter_btn)
        layout.addLayout(filter_row)

        # One-shot migration: earlier versions persisted feed-status filters
        # that would hide every row on a fresh install (no health sweep yet).
        # Clear any pre-v1.0.1 filter state so users don't see an empty table
        # after upgrading.
        _qs = QSettings("m4ma", "Paragraphos")
        if _qs.value("shows/filters_schema", 0, type=int) < 1:
            _qs.remove("shows/filters")
            _qs.setValue("shows/filters_schema", 1)
        self._active_filters = _qs.value("shows/filters", {}, type=dict) or {}
        self._feed_pills: dict[str, Pill] = {}

        self.table = QTableWidget(0, 7)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        # ExtendedSelection for multi-select bulk actions.
        self.table.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)
        self.table.doubleClicked.connect(self._open_details)
        self.table.setHorizontalHeaderLabels(
            ["Slug", "Title", "On", "Total", "Done", "Pending", "Feed"]
        )
        from ui.widgets.resizable_header import make_resizable

        # Columns: 0 Slug, 1 Title (stretch), 2 On, 3 Total, 4 Done,
        # 5 Pending, 6 Feed.
        make_resizable(
            self.table,
            settings_key="shows/columns",
            stretch_col=1,
            defaults={0: 140, 2: 40, 3: 60, 4: 60, 5: 70, 6: 70},
        )
        self.table.horizontalHeader().setSortIndicatorShown(True)
        self.table.setSortingEnabled(True)
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._context_menu)
        self.table.itemSelectionChanged.connect(self._on_selection_changed)
        layout.addWidget(self.table)

        from ui.widgets.empty_state import EmptyState

        self.empty_state = EmptyState(
            title="No shows yet",
            hint="Add a podcast or YouTube channel to start transcribing.",
            action_text="Add show",
            on_action=self._add,
        )
        layout.addWidget(self.empty_state)
        self.empty_state.setVisible(False)

        # (Action + bulk button rows live at the top of the tab — see
        # the consolidation block above. The bottom button row that
        # used to live here was removed 2026-04-23 so Shows / Queue /
        # Failed all keep their toolbars in the same screen position.)
        self.refresh()

    def _open_details(self, index) -> None:
        row = index.row()
        if row < 0:
            return
        slug = self.table.item(row, 0).text()
        from ui.show_details_dialog import ShowDetailsDialog

        dlg = ShowDetailsDialog(self.ctx, slug, self)
        if dlg.exec():
            self.refresh()

    def _update_global_stats(self) -> None:
        from core.stats import compute_global_stats, format_duration

        g = compute_global_stats(self.ctx.state)
        dur_str = format_duration(g.total_seconds)
        self.global_stats_label.setText(
            f"<b>Library</b>  —  {g.transcripts} transcripts · "
            f"{dur_str} of audio · "
            f"{g.total_words:,}".replace(",", ".")
            + f" words · {g.episodes_pending} pending · {g.episodes_failed} failed"
        )

    def refresh(self) -> None:
        self._update_global_stats()
        # Preserve the user's scroll position + selection across the
        # rebuild. setRowCount(0) wipes both by default, so opening
        # Details on row 42 and closing would otherwise jerk the view
        # back to the top.
        sb = self.table.verticalScrollBar()
        scroll_pos = sb.value() if sb is not None else 0
        sel_slug = None
        cur = self.table.currentItem()
        if cur is not None:
            cur_row = cur.row()
            slug_item = self.table.item(cur_row, 0)
            if slug_item is not None:
                sel_slug = slug_item.text()
        # Turn off sorting during insertion — Qt re-sorts between every
        # setItem() call when enabled, which scrambles row indices and
        # leaves all cells past column 0 empty for most shows.
        was_sorting = self.table.isSortingEnabled()
        self.table.setSortingEnabled(False)
        self.table.setRowCount(0)
        self._feed_pills.clear()
        total_shows = len(self.ctx.watchlist.shows)
        visible = 0
        for show in self.ctx.watchlist.shows:
            if not self._show_matches_filters(show):
                continue
            visible += 1
            with self.ctx.state._conn() as c:
                total = c.execute(
                    "SELECT COUNT(*) FROM episodes WHERE show_slug=?", (show.slug,)
                ).fetchone()[0]
                done = c.execute(
                    "SELECT COUNT(*) FROM episodes WHERE show_slug=? AND status='done'",
                    (show.slug,),
                ).fetchone()[0]
                pend = c.execute(
                    "SELECT COUNT(*) FROM episodes WHERE show_slug=? AND status='pending'",
                    (show.slug,),
                ).fetchone()[0]
            row = self.table.rowCount()
            self.table.insertRow(row)
            self.table.setItem(row, 0, QTableWidgetItem(show.slug))
            # Prompt-quality flag: if the last N transcripts ignore most
            # of the prompt terms, add a ⚠ before the title. Cheap read —
            # runs only on done rows, no network.
            from core.stats import show_prompt_coverage

            n, cov = show_prompt_coverage(self.ctx.state, show.slug, show.whisper_prompt)
            title_text = show.title
            if n >= 5 and cov < 0.2:
                title_text = f"⚠ {title_text}"
            title_item = QTableWidgetItem(title_text)
            if n >= 5 and cov < 0.2:
                title_item.setToolTip(
                    f"whisper_prompt coverage is low: only "
                    f"{cov * 100:.0f}% of prompt terms appear in the last "
                    f"{n} transcripts. Consider updating the prompt."
                )
            self.table.setItem(row, 1, title_item)
            self.table.setItem(row, 2, QTableWidgetItem("✓" if show.enabled else ""))
            self.table.setItem(row, 3, QTableWidgetItem(str(total)))
            self.table.setItem(row, 4, QTableWidgetItem(str(done)))
            self.table.setItem(row, 5, QTableWidgetItem(str(pend)))
            # Feed column hosts a Pill widget. Seed its state from the
            # last recorded feed_health meta (written by backoff.on_success
            # / on_failure during any check run); falls back to "?" if no
            # check has run yet for this show.
            pill_container = QWidget()
            h = QHBoxLayout(pill_container)
            h.setContentsMargins(2, 2, 2, 2)
            stored = self.ctx.state.get_meta(f"feed_health:{show.slug}") or ""
            if stored == "ok":
                pill = Pill("ok", kind="ok")
                pill.setToolTip("Last feed fetch succeeded.")
            elif stored == "fail":
                # Categorised failure detail (written by core.backoff.on_failure
                # via the worker, or by cli.py's manual retry helpers). Falls
                # back to plain "fail" if the failure happened before the
                # categorisation feature shipped.
                from core.feed_errors import label as _label
                from core.feed_errors import recommendation as _rec

                cat = self.ctx.state.get_meta(f"feed_fail_category:{show.slug}") or ""
                msg = self.ctx.state.get_meta(f"feed_fail_message:{show.slug}") or ""
                at = self.ctx.state.get_meta(f"feed_fail_at:{show.slug}") or ""
                until = self.ctx.state.get_meta(f"feed_backoff_until:{show.slug}") or ""
                text = f"fail · {_label(cat)}" if cat else "fail"
                pill = Pill(text, kind="fail")
                tip_lines = []
                if cat:
                    tip_lines.append(f"Category: {_label(cat)}")
                if at:
                    tip_lines.append(f"When: {at}")
                if msg:
                    tip_lines.append(f"Message: {msg[:300]}")
                if until:
                    tip_lines.append(f"Backoff: parked until {until}")
                if cat:
                    tip_lines.append("")
                    tip_lines.append(_rec(cat))
                tip_lines.append("")
                tip_lines.append("Open Show details → Feed health to retry now.")
                pill.setToolTip("\n".join(tip_lines))
            else:
                pill = Pill("?", kind="idle")
                pill.setToolTip("No feed check has run yet for this show.")
            h.addWidget(pill)
            self.table.setCellWidget(row, FEED_COL, pill_container)
            self._feed_pills[show.slug] = pill

        self._summary.setText(
            f"Showing {visible} of {total_shows}"
            + (" · filtered" if visible != total_shows else "")
        )
        n_active = sum(1 for v in self._active_filters.values() if v)
        self._filter_count_pill.setText(str(n_active))
        self._filter_count_pill.setVisible(n_active > 0)
        # Re-enable sorting once all cells are filled — this applies any
        # pending sort order to the new rows atomically.
        self.table.setSortingEnabled(was_sorting)
        # Restore scroll + selection to where the user was. We re-find
        # the previously selected slug because sorting + filters may
        # have changed its row index.
        if sel_slug is not None:
            for r in range(self.table.rowCount()):
                it = self.table.item(r, 0)
                if it is not None and it.text() == sel_slug:
                    self.table.setCurrentItem(it)
                    break
        if sb is not None:
            # Clamp in case the row count shrank below the old offset.
            sb.setValue(min(scroll_pos, sb.maximum()))
        # Empty-state when there are no shows at all (not merely filtered-empty).
        no_shows = len(self.ctx.watchlist.shows) == 0
        self.empty_state.setVisible(no_shows)
        self.table.setVisible(not no_shows)

    def _show_matches_filters(self, show) -> bool:
        f = self._active_filters
        if f.get("enabled_only") and not show.enabled:
            return False
        needle = (f.get("search", "") or "").lower()
        if needle and needle not in show.slug.lower() and needle not in show.title.lower():
            return False
        if f.get("has_pending") and not self._row_count(show.slug, "pending"):
            return False
        if f.get("has_failed") and not self._row_count(show.slug, "failed"):
            return False
        feed_flags = [k for k in ("feed_ok", "feed_stale", "feed_unreachable") if f.get(k)]
        if feed_flags:
            pill = self._feed_pills.get(show.slug)
            # Pill stores its state via QLabel.property("kind"); fall back to
            # None when the pill hasn't been created yet.
            kind = pill.property("kind") if pill is not None else None
            # Pill only emits "ok" | "fail" | "idle" today — there is no
            # distinct "stale" kind. Conflate feed_stale with feed_unreachable
            # (both match "fail") until a real stale-detection path lands.
            matches = (
                ("feed_ok" in feed_flags and kind == "ok")
                or ("feed_stale" in feed_flags and kind == "fail")
                or ("feed_unreachable" in feed_flags and kind == "fail")
            )
            if not matches:
                return False
        return True

    def _row_count(self, slug: str, status: str) -> int:
        with self.ctx.state._conn() as c:
            return c.execute(
                "SELECT COUNT(*) FROM episodes WHERE show_slug=? AND status=?", (slug, status)
            ).fetchone()[0]

    def _open_filter_popover(self) -> None:
        pop = FilterPopover(initial=self._active_filters, parent=self)
        pop.applied.connect(self._on_filters_applied)
        pop.show_at_button(self._filter_btn)

    def _on_filters_applied(self, state: dict) -> None:
        self._active_filters = state
        QSettings("m4ma", "Paragraphos").setValue("shows/filters", state)
        self.refresh()

    def _context_menu(self, pos):
        row = self.table.rowAt(pos.y())
        if row < 0:
            return
        slug = self.table.item(row, 0).text()
        menu = QMenu(self)
        details = QAction("Details…", self)
        details.triggered.connect(lambda: self._open_details_by_slug(slug))
        check_only = QAction(f"Check '{slug}' now", self)
        check_only.triggered.connect(lambda: self._check(only_slug=slug))
        stale_all = QAction(f"Mark all '{slug}' episodes stale", self)
        stale_all.triggered.connect(lambda: self._mark_stale(slug))
        toggle = QAction("Toggle enabled", self)
        toggle.triggered.connect(lambda: self._toggle(slug))
        paused = self.ctx.state.get_meta(f"show_paused:{slug}") == "1"
        pause_label = f"Resume '{slug}'" if paused else f"Pause '{slug}'"
        pause_act = QAction(pause_label, self)
        pause_act.triggered.connect(lambda: self._toggle_show_pause(slug))
        # Show-level priority bumps — same semantics as the per-episode
        # menu in Show Details, but apply to every pending episode of
        # the show in one go.
        run_next_all = QAction(f"Run all pending of '{slug}' next", self)
        run_next_all.triggered.connect(lambda: self._bump_all_pending(slug, 5))
        run_now_all = QAction(f"Run all pending of '{slug}' now", self)
        run_now_all.triggered.connect(lambda: self._bump_all_pending(slug, 10))

        menu.addAction(details)
        menu.addSeparator()
        menu.addAction(check_only)
        menu.addAction(run_next_all)
        menu.addAction(run_now_all)
        menu.addAction(stale_all)
        menu.addAction(toggle)
        menu.addSeparator()
        menu.addAction(pause_act)
        menu.exec(self.table.viewport().mapToGlobal(pos))

    def _bump_all_pending(self, slug: str, priority: int) -> None:
        """Set priority on every pending/downloading episode of `slug`,
        then kick the worker so the bumps take effect immediately."""
        with self.ctx.state._conn() as c:
            rows = c.execute(
                "UPDATE episodes SET priority=? "
                "WHERE show_slug=? AND status IN ('pending','downloading') "
                "RETURNING guid",
                (priority, slug),
            ).fetchall()
        n = len(rows)
        self._log(f"bumped {n} pending episode(s) of {slug} to priority {priority}")
        # Kick the worker so the new sort order takes effect on the next
        # claim. With the DB-claim worker (no pre-priming) the bump shows
        # up immediately if a pass is already running.
        try:
            self.start_check(force=True)
        except Exception:
            pass

    def _open_details_by_slug(self, slug: str) -> None:
        from ui.show_details_dialog import ShowDetailsDialog

        dlg = ShowDetailsDialog(self.ctx, slug, self)
        if dlg.exec():
            self.refresh()

    def _toggle_show_pause(self, slug: str) -> None:
        key = f"show_paused:{slug}"
        paused = self.ctx.state.get_meta(key) == "1"
        self.ctx.state.set_meta(key, "0" if paused else "1")
        self._log(f"{'resumed' if paused else 'paused'} {slug}")
        self.refresh()

    def _add(self):
        from ui.add_show_dialog import AddShowDialog

        dlg = AddShowDialog(self.ctx, self)
        if dlg.exec():
            self.ctx.watchlist = dlg.updated_watchlist
            self.refresh()

    def _add_youtube(self):
        """Open the Add dialog focused on the YouTube-channel flow — a single
        link field, no podcast tabs (the dedicated 'Add YouTube Channel…'
        entry point)."""
        from ui.add_show_dialog import AddShowDialog

        dlg = AddShowDialog(self.ctx, self, initial_mode="youtube")
        if dlg.exec():
            self.ctx.watchlist = dlg.updated_watchlist
            self.refresh()

    def _curated(self):
        from ui.add_episodes_dialog import AddEpisodesDialog

        dlg = AddEpisodesDialog(self.ctx, self)
        dlg.exec()
        self.refresh()

    def _check(self, only_slug: str | None = None):
        # Any call routed through _check comes from a user-visible control
        # (toolbar "Check" button, per-row action, keyboard shortcut) —
        # treat those as "I said retry now" and bypass feed backoff.
        self.start_check(only_slug=only_slug or None, force=True)

    def start_check(self, *, only_slug: str | None = None, force: bool = False) -> bool:
        """Public entry: start a check and update button state.

        ``force=True`` bypasses per-feed backoff — pass it for user-initiated
        starts (toolbar button, tray "Check now", keyboard shortcut). The
        scheduler path leaves it False so parked feeds stay parked until
        their backoff window expires.

        Returns False if another check is already running."""
        from ui.worker_thread import CheckAllThread

        if self._thread and self._thread.isRunning():
            return False
        if force:
            # User-initiated check (toolbar, tray, shortcut, Queue Start). The
            # scheduler path (force=False) stays silent so it doesn't spam.
            from ui.activity_log import log as log_activity

            log_activity(f"Started a check{f' for {only_slug}' if only_slug else ''}")
        self._thread = CheckAllThread(self.ctx, self.ctx.settings, only_slug=only_slug, force=force)
        self._thread.progress.connect(self._log)
        self._thread.queue_sized.connect(self._on_queue_sized)
        self._thread.episode_done.connect(self._on_ep_done)
        self._thread.finished_all.connect(self._check_done)
        if self.queue_listener is not None:
            self._thread.queue_sized.connect(self.queue_listener.on_queue_sized)
            self._thread.episode_done.connect(self.queue_listener.on_episode_done)
            self._thread.finished_all.connect(self.queue_listener.on_finished_all)
        # Library tab listens too — debounced refresh on every
        # episode_done so newly-completed transcripts surface in the
        # tree without restarting the app. Wired in MainWindow via
        # `library_listener`. Kept optional so unit tests that build
        # ShowsTab in isolation don't trip on a missing attribute.
        lib = getattr(self, "library_listener", None)
        if lib is not None and hasattr(lib, "on_episode_done"):
            self._thread.episode_done.connect(lib.on_episode_done)
        self.stop_btn.setEnabled(True)
        self.check_btn.setEnabled(False)
        from datetime import datetime

        from core.stats import (
            historical_avg_transcribe_sec,
            pending_duration_sum,
            realtime_factor,
        )

        self.ctx.queue.running = True
        self.ctx.queue.started_at = datetime.now()
        self.ctx.queue.total = 0
        self.ctx.queue.done = 0
        self.ctx.queue.avg_sec_per_episode = 0.0
        # Historical DB-derived average lets us show an ETA and 'finish ≈'
        # time immediately — long before the first live episode finishes
        # (whisper takes ~5 min, and the user wants feedback now).
        self.ctx.queue.historical_avg_sec = historical_avg_transcribe_sec(self.ctx.state)
        # Duration-based ETA: pending audio × realtime factor. Far more
        # accurate than episode-count × avg-per-episode when shows have
        # varying episode lengths.
        self.ctx.queue.remaining_audio_sec = pending_duration_sum(
            self.ctx.state, show_slug=only_slug
        )
        self.ctx.queue.realtime_factor = realtime_factor(self.ctx.state)
        self._ep_durations: list[float] = []
        self._last_ep_start = datetime.now()
        self._thread.start()
        return True

    def _on_queue_sized(self, total: int) -> None:
        self.ctx.queue.total = total

    def _on_ep_done(self, slug, guid, action, done_idx, total, show_title, ep_title):
        from datetime import datetime

        from core.stats import pending_duration_sum

        self.ctx.queue.done = done_idx
        self.ctx.queue.total = total
        self.ctx.queue.last_episode_show = show_title
        self.ctx.queue.last_episode_title = ep_title
        # Refresh remaining audio after each episode so the ETA winds
        # down with actual progress instead of a fixed at-start estimate.
        self.ctx.queue.remaining_audio_sec = pending_duration_sum(self.ctx.state)
        now = datetime.now()
        if self._last_ep_start:
            self._ep_durations.append((now - self._last_ep_start).total_seconds())
            self._ep_durations = self._ep_durations[-10:]
            self.ctx.queue.avg_sec_per_episode = sum(self._ep_durations) / len(self._ep_durations)
        self._last_ep_start = now

    def attach_external_thread(self, thread) -> None:
        """Called when someone (e.g. the tray-app) started a CheckAllThread
        before the window existed — wire up the buttons so Stop works."""
        self._thread = thread
        if thread.isRunning():
            self.stop_btn.setEnabled(True)
            self.check_btn.setEnabled(False)
            thread.progress.connect(self._log)
            thread.finished_all.connect(self._check_done)
            if self.queue_listener is not None:
                thread.queue_sized.connect(self.queue_listener.on_queue_sized)
                thread.episode_done.connect(self.queue_listener.on_episode_done)
                thread.finished_all.connect(self.queue_listener.on_finished_all)

    def _stop(self):
        if self._thread:
            self._thread.request_stop()
            self._log("stop requested — current episode will finish, then queue halts.")
        self.stop_btn.setEnabled(False)

    def _pause(self):
        self.ctx.state.set_meta("queue_paused", "1")
        if self._thread and self._thread.isRunning():
            self._thread.request_stop()
            self._thread.pause_state_changed.emit()
        self._log(
            "pausing — current episode will finish, then the queue halts "
            "(Resume to continue; survives restart)."
        )

    def _resume(self):
        self.ctx.state.set_meta("queue_paused", "0")
        self._log("queue resumed — starting check…")
        self.start_check(force=True)

    def _check_done(self):
        self.stop_btn.setEnabled(False)
        self.check_btn.setEnabled(True)
        self.ctx.queue.running = False
        self.refresh()
        from datetime import datetime, timezone

        self.ctx.state.set_meta("last_successful_check", datetime.now(timezone.utc).isoformat())

    def _log(self, msg: str) -> None:
        if self.log_sink is not None:
            self.log_sink(msg)
        else:
            print(msg)

    def _mark_stale(self, slug: str) -> None:
        with self.ctx.state._conn() as c:
            c.execute("UPDATE episodes SET status='pending' WHERE show_slug=?", (slug,))
        self.refresh()

    def _rescan_library(self) -> None:
        from pathlib import Path

        from core.stats import rescan_library_counts

        count = rescan_library_counts(
            self.ctx.state,
            Path(self.ctx.settings.output_root).expanduser(),
        )
        self._log(f"rescan complete — {count} transcript(s) re-counted")
        self.refresh()

    def _check_feed_health(self) -> None:
        """Synchronous feed-health sweep. Slow for 16 feeds (~5–10 s) but
        runs on-demand and blocks only the button click."""
        from core.rss import FeedHealth

        for row in range(self.table.rowCount()):
            slug = self.table.item(row, 0).text()
            show = next((s for s in self.ctx.watchlist.shows if s.slug == slug), None)
            if not show:
                continue
            health = FeedHealth.check(show.rss, timeout=8)
            pill = self._feed_pills.get(slug)
            if pill is None:
                continue
            pill.set_kind("ok" if health.ok else "fail")
            pill.setText("✅" if health.ok else f"⚠ {health.reason}")

    def _retry_failed_feeds(self) -> None:
        """Clear backoff + immediately re-fetch every feed marked fail.
        Synchronous — blocks for ~1 s per failed feed. Replaces the
        sqlite-poke an LLM agent would otherwise have to script."""
        from datetime import datetime as _dt
        from datetime import timezone as _tz

        from core.feed_errors import categorize
        from core.rss import build_manifest

        state = self.ctx.state
        failed = [
            s
            for s in self.ctx.watchlist.shows
            if (state.get_meta(f"feed_health:{s.slug}") or "") == "fail"
        ]
        if not failed:
            self._log("no failed feeds to retry")
            return
        self._log(f"retrying {len(failed)} failed feed(s)…")
        ok = 0
        for show in failed:
            # Clear backoff state per slug.
            for k in (
                "feed_fail_count",
                "feed_backoff_until",
                "feed_fail_category",
                "feed_fail_message",
                "feed_fail_at",
            ):
                state.set_meta(f"{k}:{show.slug}", "0" if k.endswith("count") else "")
            try:
                build_manifest(show.rss, timeout=30)
            except Exception as e:  # noqa: BLE001
                state.set_meta(f"feed_health:{show.slug}", "fail")
                state.set_meta(f"feed_fail_category:{show.slug}", categorize(e))
                state.set_meta(f"feed_fail_message:{show.slug}", str(e)[:500])
                state.set_meta(f"feed_fail_at:{show.slug}", _dt.now(_tz.utc).isoformat())
                self._log(f"  ✗ {show.slug}: {e}")
                continue
            state.set_meta(f"feed_health:{show.slug}", "ok")
            self._log(f"  ✓ {show.slug}")
            ok += 1
        self._log(f"retry complete — {ok}/{len(failed)} ok")
        self.refresh()

    def _toggle(self, slug: str) -> None:
        for show in self.ctx.watchlist.shows:
            if show.slug == slug:
                show.enabled = not show.enabled
        save_watchlist(self.ctx)
        self.refresh()

    # ----- bulk actions on multi-selected rows --------------------------

    def _selected_slugs(self) -> list[str]:
        rows = {idx.row() for idx in self.table.selectedIndexes()}
        slugs: list[str] = []
        for row in rows:
            item = self.table.item(row, 0)
            if item:
                slugs.append(item.text())
        return slugs

    def _find_show(self, slug: str):
        return next((s for s in self.ctx.watchlist.shows if s.slug == slug), None)

    def _on_selection_changed(self) -> None:
        has = bool(self._selected_slugs())
        for b in (self._bulk_disable, self._bulk_enable, self._bulk_stale, self._bulk_delete):
            b.setEnabled(has)

    def _do_bulk_disable(self) -> None:
        for slug in self._selected_slugs():
            s = self._find_show(slug)
            if s:
                s.enabled = False
        save_watchlist(self.ctx)
        self.refresh()

    def _do_bulk_enable(self) -> None:
        for slug in self._selected_slugs():
            s = self._find_show(slug)
            if s:
                s.enabled = True
        save_watchlist(self.ctx)
        self.refresh()

    def _do_bulk_stale(self) -> None:
        # Same blanket-reset semantics as the single-row _mark_stale helper
        # — flips every episode back to 'pending'. Inlined (rather than
        # looping _mark_stale) to avoid N refreshes clearing the selection
        # mid-loop.
        with self.ctx.state._conn() as c:
            for slug in self._selected_slugs():
                c.execute("UPDATE episodes SET status='pending' WHERE show_slug=?", (slug,))
        self.refresh()

    def _do_bulk_delete(self) -> None:
        slugs = self._selected_slugs()
        if not slugs:
            return
        reply = QMessageBox.question(
            self,
            "Delete shows",
            f"Remove {len(slugs)} show(s) from the watchlist?\n"
            "Their episode history is cleared (re-adding starts fresh); "
            "on-disk transcripts are kept.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return
        self.ctx.watchlist.shows = [s for s in self.ctx.watchlist.shows if s.slug not in slugs]
        save_watchlist(self.ctx)
        # Purge each removed show's episode rows so re-adding re-queues cleanly.
        for slug in slugs:
            self.ctx.state.delete_episodes_for_show(slug)
        from ui.activity_log import log as log_activity

        log_activity(f"Removed {len(slugs)} show(s): {', '.join(slugs)}")
        self.refresh()
