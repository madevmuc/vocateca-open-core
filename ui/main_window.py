"""Main window: sidebar nav + stacked pages + log dock + wiki-compile banner."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from PyQt6.QtCore import QDateTime, QLocale, QSettings, Qt, QTimer, QUrl
from PyQt6.QtGui import QDesktopServices, QKeySequence, QShortcut
from PyQt6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QStackedWidget,
    QStatusBar,
    QVBoxLayout,
    QWidget,
)

from core import ytdlp
from core.paths import user_data_dir  # noqa: E402
from core.sources import youtube_enabled
from ui.about_dialog import AboutPane
from ui.app_context import AppContext
from ui.failed_tab import FailedTab
from ui.library_tab import LibraryTab
from ui.local_transcript_tab import LocalTranscriptTab
from ui.log_dock import LogDock, LogsPane
from ui.menu_bar import build_menu_bar
from ui.queue_tab import QueueTab
from ui.settings_pane import SettingsPane
from ui.shows_tab import ShowsTab
from ui.widgets import Sidebar

DATA_DIR = user_data_dir()


def _fmt_elapsed(sec: float) -> str:
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m"
    return f"{sec // 3600}h {(sec % 3600) // 60}m"


def _fmt_dt_locale(dt) -> str:
    """Format datetime as 'ddd, <locale-short-date> HH:MM'.

    Respects the macOS system locale — DE users see '21.04.2026', US users
    see '4/21/26'. 'ddd' is localized too (Mo/Mon/etc.).
    """
    qdt = QDateTime.fromSecsSinceEpoch(int(dt.timestamp()))
    loc = QLocale.system()
    date_fmt = loc.dateFormat(QLocale.FormatType.ShortFormat)
    # Prefer 4-digit year for readability; Qt short-format on macOS DE already
    # uses 'dd.MM.yyyy' so this is usually a no-op.
    if "yyyy" not in date_fmt:
        date_fmt = date_fmt.replace("yy", "yyyy")
    return loc.toString(qdt, f"ddd, {date_fmt} HH:mm")


def maybe_self_update_ytdlp(settings, save) -> None:
    """Run `yt-dlp -U` once on launch if YouTube is enabled, yt-dlp is
    installed, and the last update was more than 7 days ago. Failures
    are silent — they will resurface the next time a YouTube action is
    attempted, where the user gets actionable UI feedback.
    """
    if not youtube_enabled(settings):
        return
    if not ytdlp.is_installed():
        return
    last = settings.ytdlp_last_self_update_at
    if last:
        try:
            last_dt = datetime.fromisoformat(last)
            if datetime.now(timezone.utc) - last_dt < timedelta(days=7):
                return
        except ValueError:
            pass
    try:
        ytdlp.self_update()
        settings.ytdlp_last_self_update_at = datetime.now(timezone.utc).isoformat()
        save()
    except Exception:
        pass


def _last_compiled_path(ctx) -> Path:
    """Path to the knowledge-hub's compile marker, driven by settings so the
    banner works after Paragraphos is extracted into its own repo."""
    root = Path(ctx.settings.knowledge_hub_root).expanduser()
    return root / "raw" / ".last_compiled"


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Paragraphos")
        self.setAcceptDrops(True)
        self.ctx = AppContext.load(DATA_DIR)

        central = QWidget()
        outer = QVBoxLayout(central)
        outer.setContentsMargins(0, 0, 0, 0)
        # Banner is a QWidget (not a bare QLabel) so it can host an action
        # button (Download) and a dismiss button alongside the message.
        # Four logical states:
        #   "compile" — transcripts newer than last wiki compile
        #   "update"  — new Paragraphos release available
        #   "offline" — network is down, queue paused, will auto-resume
        #   "newshow" — externally-added shows awaiting a backlog decision
        self.banner = QWidget()
        self._banner_state: str = ""  # "", "compile", "update", "offline", or "newshow"
        self._update_tag: str = ""
        self._update_url: str = ""
        bl = QHBoxLayout(self.banner)
        bl.setContentsMargins(12, 8, 12, 8)
        bl.setSpacing(10)
        self.banner_label = QLabel()
        self.banner_label.setWordWrap(True)
        bl.addWidget(self.banner_label, stretch=1)
        self.banner_action_btn = QPushButton()
        self.banner_action_btn.setVisible(False)
        self.banner_action_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.banner_action_btn.clicked.connect(self._on_banner_action)
        bl.addWidget(self.banner_action_btn)
        self.banner_dismiss_btn = QPushButton("✕")
        self.banner_dismiss_btn.setFlat(True)
        self.banner_dismiss_btn.setFixedWidth(24)
        self.banner_dismiss_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.banner_dismiss_btn.setToolTip("Dismiss")
        self.banner_dismiss_btn.clicked.connect(self._dismiss_banner)
        bl.addWidget(self.banner_dismiss_btn)
        self._apply_banner_style()
        self.banner.setVisible(False)
        outer.addWidget(self.banner)

        # Re-paint the banner when the system appearance flips. The banner
        # paints itself via inline QSS (outside the global stylesheet) so it
        # would otherwise stick on whichever mode was active at construction.
        try:
            from ui.themes import manager as _theme_mgr

            _tm = _theme_mgr()
            if _tm is not None:
                _tm.themeChanged.connect(lambda _mode: self._apply_banner_style())
        except Exception:
            # Manager not installed (tests) — no live updates, but the
            # banner still paints correctly at startup.
            pass

        body = QWidget()
        root = QHBoxLayout(body)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Sidebar
        self.sidebar = Sidebar()
        self.sidebar.add_group("Workspace")
        for key, label in (
            ("shows", "Shows"),
            ("local", "Local Transcript"),
            ("queue", "Queue"),
            ("failed", "Failed"),
        ):
            self.sidebar.add_item(key, label)
        # Standalone leaf — sits between Workspace and System without
        # its own group header. Sidebar.add_item is group-agnostic so
        # this just appends another row at the same indent level.
        self.sidebar.add_item("library", "Library")
        self.sidebar.add_group("System")
        for key, label in (("settings", "Settings"), ("logs", "Logs"), ("about", "About")):
            self.sidebar.add_item(key, label)
        self.sidebar.finish()
        # Default landing tab: Queue if there's work pending (so the
        # user sees progress immediately), otherwise Shows. Computed
        # below in _initial_tab — this early call is safe because it
        # only reads the state DB, not any widget.
        self._initial_tab_key = self._initial_tab()
        self.sidebar.set_active(self._initial_tab_key)
        self.sidebar.navigate.connect(self._on_nav)
        root.addWidget(self.sidebar)

        # Stacked pages on the right
        self.stack = QStackedWidget()
        self.shows_tab = ShowsTab(self.ctx)
        self.queue_tab = QueueTab(self.ctx)
        self.failed_tab = FailedTab(self.ctx)
        self.library_tab = LibraryTab(self.ctx)
        self.settings_pane = SettingsPane(self.ctx)
        self.logs_pane = LogsPane(self)
        self.about_pane = AboutPane(self)
        # Let ShowsTab forward queue signals to the queue tab.
        self.shows_tab.queue_listener = self.queue_tab  # type: ignore[attr-defined]
        # LibraryTab debounces episode_done into a single refresh so a
        # check-pass burst doesn't rebuild the tree N times. Without
        # this, the Library shows a snapshot frozen at app launch.
        self.shows_tab.library_listener = self.library_tab  # type: ignore[attr-defined]

        # Local Transcript tab — top-level sibling of Shows/Queue. Hosts
        # the universal-ingest surface (drop, folder, URL) that used to
        # live as a card on the Shows page.
        self.local_transcript_tab = LocalTranscriptTab(self.ctx)

        for w in (
            self.shows_tab,
            self.local_transcript_tab,
            self.queue_tab,
            self.failed_tab,
            self.library_tab,
            self.settings_pane,
            self.logs_pane,
            self.about_pane,
        ):
            self.stack.addWidget(w)
        self._nav_index = {
            "shows": 0,
            "local": 1,
            "queue": 2,
            "failed": 3,
            "library": 4,
            "settings": 5,
            "logs": 6,
            "about": 7,
        }
        # Honour the landing-tab choice — sidebar highlight was set
        # earlier; now point the stack at the matching page.
        self.stack.setCurrentIndex(self._nav_index[self._initial_tab_key])
        root.addWidget(self.stack, stretch=1)

        outer.addWidget(body, stretch=1)
        self.setCentralWidget(central)

        self.log_dock = LogDock(self)
        self.addDockWidget(Qt.DockWidgetArea.BottomDockWidgetArea, self.log_dock)
        # Off by default — Settings → Show log dock toggle controls this,
        # Ctrl+L flips on demand.
        self.log_dock.setVisible(bool(getattr(self.ctx.settings, "show_log_dock", False)))

        # Fan every log message into both the dock (bottom) and the
        # sidebar Logs pane so they stay in sync.
        def _log_sink(msg: str) -> None:
            self.log_dock.append(msg)
            self.logs_pane.append(msg)

        self.shows_tab.log_sink = _log_sink  # type: ignore[attr-defined]
        # App-wide activity log (adds/removes/start/pause/deletes/…) fans into
        # the same dock + pane via this sink.
        from ui import activity_log

        activity_log.set_sink(_log_sink)
        # Translate a curated subset of bus events into activity-log lines so
        # the dock surfaces richer lifecycle info alongside direct log() calls.
        activity_log.install_event_bridge()

        self.setMenuBar(build_menu_bar(self))

        # Window-scoped shortcuts (menu items also register these, but explicit
        # QShortcuts guarantee they work even when no menu-item is focused).
        for key, fn in (
            (QKeySequence.StandardKey.Preferences, lambda: self._on_nav("settings")),
            ("Ctrl+R", lambda: self.shows_tab.start_check(force=True)),
            ("Ctrl+.", self.shows_tab._stop),
            ("Ctrl+L", lambda: self.log_dock.setVisible(not self.log_dock.isVisible())),
            ("?", lambda: self._show_cheatsheet()),
            ("Ctrl+/", lambda: self._show_cheatsheet()),
            ("Ctrl+Z", self._undo_last),
            ("Ctrl+K", self._open_command_palette),
        ):
            QShortcut(
                QKeySequence(key) if isinstance(key, str) else QKeySequence(key), self, activated=fn
            )

        # Global status bar — visible from every tab.
        sb = QStatusBar()
        self.setStatusBar(sb)
        self.status_label = QLabel()
        self.status_label.setTextFormat(Qt.TextFormat.RichText)
        sb.addPermanentWidget(self.status_label, stretch=1)
        self._status_timer = QTimer(self)
        self._status_timer.timeout.connect(self._refresh_status_bar)
        self._status_timer.start(1000)
        self._refresh_status_bar()

        self._refresh_banner()
        # Restore last-session window size from QSettings; fall back to
        # 95% of the primary screen for first launch. Store on close so
        # the next run reopens at the same dimensions.
        self._restore_geometry()

        # Sidebar counts: once at startup, then periodically so they stay
        # fresh after checks finish, retries, etc.
        self._update_sidebar_counts()
        self._counts_timer = QTimer(self)
        self._counts_timer.timeout.connect(self._update_sidebar_counts)
        self._counts_timer.start(2000)

        # Weekly yt-dlp self-update — fire once shortly after launch so the
        # window is responsive first. Helper no-ops when YouTube is off,
        # yt-dlp isn't installed, or the last update is <7 days old.
        QTimer.singleShot(
            2000,
            lambda: maybe_self_update_ytdlp(
                self.ctx.settings,
                lambda: self.ctx.settings.save(self.ctx.data_dir / "settings.yaml"),
            ),
        )

    def _restore_geometry(self) -> None:
        """Re-open at last-session size/position, clamped to the current
        screen. First launch fills 90% of the available screen area."""
        from PyQt6.QtCore import QSettings
        from PyQt6.QtGui import QGuiApplication

        qs = QSettings("madevmuc", "Paragraphos")
        saved = qs.value("window/geometry")

        screen = QGuiApplication.primaryScreen()
        avail = screen.availableGeometry() if screen is not None else None

        if saved:
            try:
                self.restoreGeometry(saved)
                # Clamp to the current screen — a saved geometry from a
                # larger external display must not overflow onto the
                # smaller built-in one when the external is gone.
                if avail is not None:
                    geo = self.geometry()
                    w = min(geo.width(), avail.width())
                    h = min(geo.height(), avail.height())
                    x = max(avail.x(), min(geo.x(), avail.x() + avail.width() - w))
                    y = max(avail.y(), min(geo.y(), avail.y() + avail.height() - h))
                    if (w, h, x, y) != (geo.width(), geo.height(), geo.x(), geo.y()):
                        self.setGeometry(x, y, w, h)
                return
            except Exception:
                pass

        # First launch — 90% of the available primary screen, centred.
        if avail is None:
            self.resize(1100, 720)
            return
        w = int(avail.width() * 0.90)
        h = int(avail.height() * 0.90)
        self.resize(w, h)
        self.move(avail.x() + (avail.width() - w) // 2, avail.y() + (avail.height() - h) // 2)

    def dragEnterEvent(self, event):  # noqa: N802 — Qt override
        md = event.mimeData()
        if md.hasUrls() or md.hasText():
            event.acceptProposedAction()

    def dropEvent(self, event):  # noqa: N802 — Qt override
        # Navigate to Local Transcript so the user sees the file arrive
        # there, then delegate the drop handling to the tab.
        self._on_nav("local")
        self.local_transcript_tab.dropEvent(event)

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        from PyQt6.QtCore import QSettings
        from PyQt6.QtGui import QGuiApplication

        # Belt-and-braces: clamp before saving so a runaway window width
        # can never persist across sessions.
        screen = self.screen() or QGuiApplication.primaryScreen()
        if screen is not None:
            avail = screen.availableGeometry()
            if self.width() > avail.width() or self.height() > avail.height():
                self.resize(min(self.width(), avail.width()), min(self.height(), avail.height()))
        QSettings("madevmuc", "Paragraphos").setValue("window/geometry", self.saveGeometry())
        super().closeEvent(event)

    def resizeEvent(self, ev) -> None:  # noqa: N802 — Qt override
        """Defensive clamp: a child widget's minimumSizeHint can force
        QMainWindow to grow beyond the screen (e.g. a QLabel without
        wordWrap showing a very long episode title). Without this, the
        window monotonically grows over a long session and can end up
        several screens wide. We clamp any resize that overshoots the
        available screen area."""
        from PyQt6.QtGui import QGuiApplication

        super().resizeEvent(ev)
        screen = self.screen() or QGuiApplication.primaryScreen()
        if screen is None:
            return
        avail = screen.availableGeometry()
        w, h = self.width(), self.height()
        clamped_w = min(w, avail.width())
        clamped_h = min(h, avail.height())
        if (clamped_w, clamped_h) != (w, h):
            self.resize(clamped_w, clamped_h)

    def _apply_banner_style(self) -> None:
        """Choose banner colors that work in both light and dark macOS modes.

        Colors are now derived from theme tokens so the banner tracks live
        appearance changes (macOS Appearance flip) via the ThemeManager
        signal — not just whatever scheme was active at window construction.

        Update-available uses `accent` (ochre in light / purple in dark) so
        it visually anchors to a different hue than the amber compile
        reminder, which uses `warn`.
        """
        from ui.themes import current_tokens, manager

        t = current_tokens()
        tm = manager()
        dark = tm.scheme() == "dark" if tm is not None else False
        self.banner.setObjectName("appBanner")
        if self._banner_state == "update":
            # Accent-tinted card. Use `accent_tint` for the panel bg and
            # `accent` for the action button; `ink` / `ink_2` keep label
            # contrast readable in both modes.
            bg = t["accent_tint"]
            fg = t["ink"]
            border = t["accent"]
            btn_bg = t["accent"]
            btn_fg = "#ffffff"
        else:
            # compile / offline / newshow / default — warn family (amber).
            # Offline piggy-backs on the same palette: it's a transient
            # pause-state, not an error, so the warn hue (rather than danger
            # red) reads right. newshow joins it: a "needs a decision" prompt,
            # not an error.
            warn = t["warn"]
            if dark:
                # Translucent warn wash — matches the pill_fail_bg pattern
                # used elsewhere in the design system.
                bg = "rgba(240, 185, 85, 0.14)"
                fg = t["warn"]
                border = warn
                btn_bg = warn
                btn_fg = t["bg"]
            else:
                bg = "rgba(184, 134, 74, 0.14)"
                fg = t["ink"]
                border = warn
                btn_bg = warn
                btn_fg = "#ffffff"
        self.banner.setStyleSheet(
            f"QWidget#appBanner {{ background:{bg}; border:1px solid {border}; "
            f"border-radius:4px; }} "
            f"QWidget#appBanner QLabel {{ color:{fg}; background:transparent; border:none; }} "
            f"QWidget#appBanner QPushButton {{ color:{btn_fg}; background:{btn_bg}; "
            f"border:none; padding:4px 10px; border-radius:3px; }} "
            f"QWidget#appBanner QPushButton:hover {{ opacity:0.9; }} "
            f'QWidget#appBanner QPushButton[flat="true"] {{ background:transparent; '
            f"color:{fg}; }} "
        )

    def _initial_tab(self) -> str:
        """Pick the landing tab based on queue state. Returns a sidebar
        key — 'queue' if any non-terminal episode exists, else 'shows'.
        Failures (DB missing, fresh install) fall through to 'shows'."""
        try:
            with self.ctx.state._conn() as c:
                n = c.execute(
                    "SELECT COUNT(*) FROM episodes "
                    "WHERE status IN ('pending','downloading','downloaded','transcribing')"
                ).fetchone()[0]
        except Exception:
            return "shows"
        return "queue" if n else "shows"

    def _on_nav(self, key: str) -> None:
        idx = self._nav_index.get(key)
        if idx is not None:
            self.stack.setCurrentIndex(idx)
            self.sidebar.set_active(key)
            w = self.stack.widget(idx)
            if hasattr(w, "refresh"):
                w.refresh()
            self._refresh_banner()

    def _show_cheatsheet(self) -> None:
        # Toggle: re-pressing the trigger while the dialog is open closes it
        # (handled in the dialog's keyPressEvent for `?`; for Cmd+/ we just
        # re-open which raises the existing instance).
        existing = getattr(self, "_cheatsheet_dlg", None)
        if existing is not None and existing.isVisible():
            existing.close()
            return
        from ui.shortcut_cheatsheet import ShortcutCheatsheet

        self._cheatsheet_dlg = ShortcutCheatsheet(self)
        self._cheatsheet_dlg.show()
        self._cheatsheet_dlg.raise_()
        self._cheatsheet_dlg.activateWindow()

    def _update_sidebar_counts(self) -> None:
        try:
            with self.ctx.state._conn() as c:
                pending = c.execute(
                    "SELECT COUNT(*) FROM episodes WHERE status='pending'"
                ).fetchone()[0]
                failed = c.execute(
                    "SELECT COUNT(*) FROM episodes WHERE status='failed'"
                ).fetchone()[0]
        except Exception:
            pending = failed = 0
        self.sidebar.set_count("shows", len(self.ctx.watchlist.shows))
        self.sidebar.set_count("queue", pending)
        self.sidebar.set_count("failed", failed)

    def _open_command_palette(self) -> None:
        """Cmd-K fuzzy command palette (9.2)."""
        from ui.command_palette import Command, CommandPalette

        cmds = [
            Command("Go to Shows", lambda: self._on_nav("shows")),
            Command("Go to Queue", lambda: self._on_nav("queue")),
            Command("Go to Library", lambda: self._on_nav("library")),
            Command("Go to Failed", lambda: self._on_nav("failed")),
            Command("Open Settings", lambda: self._on_nav("settings")),
            Command("Start check", lambda: self.shows_tab.start_check(force=True)),
            Command("Stop", self.shows_tab._stop),
            Command("Undo last action", self._undo_last),
            Command(
                "Toggle log panel",
                lambda: self.log_dock.setVisible(not self.log_dock.isVisible()),
            ),
        ]
        pal = CommandPalette(cmds, self)
        pal.resize(420, 320)
        pal.exec()

    def _undo_last(self) -> None:
        """Run the most recent undoable destructive action (9.5), if any."""
        from ui.activity_log import log as log_activity
        from ui.undo import manager as undo_manager

        label = undo_manager.undo_last()
        if label:
            log_activity(f"Undone: {label}")
            self._refresh_status_bar()
        else:
            log_activity("Nothing to undo")

    def _refresh_status_bar(self) -> None:
        from datetime import datetime, timedelta

        from ui.themes import current_tokens

        t = current_tokens()
        q = self.ctx.queue
        if not q.running:
            paused = self.ctx.state.get_meta("queue_paused") == "1"
            if paused:
                self.status_label.setText(
                    f"<span style='color:{t['warn']};'>● queue paused</span> "
                    "— click Start on any tab to resume"
                )
            else:
                self.status_label.setText(f"<span style='color:{t['ink_3']};'>● idle</span>")
            return
        elapsed = (datetime.now() - q.started_at).total_seconds() if q.started_at else 0
        remaining = q.total - q.done
        avg = q.effective_avg_sec
        # Prefer duration-based ETA (pending audio × realtime factor) to
        # match Queue hero + Queue tab header. Falls back to the legacy
        # episode-count × avg path when no duration data is available.
        duration_eta = q.duration_based_eta_sec
        if duration_eta > 0:
            eta_sec = duration_eta
        else:
            eta_sec = avg * remaining if avg else 0
        finish_at = datetime.now() + timedelta(seconds=eta_sec) if eta_sec else None
        parts = [
            f"<span style='color:{t['accent']};'>● running</span>",
            f"<b>{q.done}/{q.total}</b>",
        ]
        if q.started_at:
            parts.append(f"started {_fmt_dt_locale(q.started_at)}")
            parts.append(f"elapsed {_fmt_elapsed(elapsed)}")
        if avg:
            # Mark fallback estimates so the user knows "finish ≈" is based
            # on historical averages when no live episode has finished yet.
            tag = "ETA" if q.avg_sec_per_episode else "ETA (est.)"
            parts.append(f"{tag} {_fmt_elapsed(eta_sec)}")
            if finish_at:
                parts.append(f"finish ≈ {_fmt_dt_locale(finish_at)}")
        else:
            from core.stats import has_realtime_history

            if not has_realtime_history(self.ctx.state):
                parts.append(
                    f"<span style='color:{t['ink_3']};'>ETA available once the first "
                    "episode completes</span>"
                )
        self.status_label.setText(" · ".join(parts))

    def _refresh_banner(self) -> None:
        # Offline takes top priority — when the network is down, the
        # queue-paused notice is the only thing the user can act on; the
        # compile reminder + update banner are noise until reconnect.
        if self._banner_state == "offline":
            return
        # New-show detection sits just below offline: an externally-added show
        # awaiting a backlog decision needs the user's input, so it outranks
        # the (informational) update + compile banners. It is gated below
        # offline so it can never hide the queue-paused notice.
        from core.watchlist_guard import undecided_slugs

        undecided = undecided_slugs(self.ctx.watchlist, self.ctx.state)
        if undecided:
            self._banner_state = "newshow"
            self.banner_label.setText(
                f"{len(undecided)} new show(s) detected — choose how much history "
                f"(full archive auto-applied in 24h)"
            )
            self.banner_action_btn.setText("Choose…")
            self.banner_action_btn.setVisible(True)
            self._apply_banner_style()
            self.banner.setVisible(True)
            return
        if self._banner_state == "newshow":
            # Everything is now decided — clear the stale new-show banner.
            self._banner_state = ""
            self.banner.setVisible(False)

        # Update-available takes priority over the wiki-compile reminder —
        # a new release is a one-click action the user cares about more.
        tag = getattr(self.ctx, "update_available_tag", "") or self._update_tag
        url = getattr(self.ctx, "update_available_url", "") or self._update_url
        if tag and url and not self._is_update_dismissed(tag):
            self._show_update_state(tag, url)
            return

        # Wiki-compile reminder only makes sense for Obsidian / knowledge-hub
        # workflows. For plain-folder users, suppress it entirely.
        if not (getattr(self.ctx.settings, "obsidian_vault_path", "") or ""):
            if self._banner_state == "compile":
                self._banner_state = ""
                self.banner.setVisible(False)
            return

        output_root = Path(self.ctx.settings.output_root).expanduser()
        if not output_root.exists():
            self._banner_state = ""
            self.banner.setVisible(False)
            return
        last_compiled_mtime = 0.0
        lc = _last_compiled_path(self.ctx)
        if lc.exists():
            last_compiled_mtime = lc.stat().st_mtime
        new_count = 0
        for md in output_root.rglob("*.md"):
            if md.name == "index.md":
                continue
            if md.stat().st_mtime > last_compiled_mtime:
                new_count += 1
        if new_count > 0:
            self._banner_state = "compile"
            # Vendor-neutral copy: users run any AI coding assistant
            # (Claude Code, Gemini CLI, Cursor, Copilot CLI, etc.) —
            # don't assume Claude.
            self.banner_label.setText(
                f"📝 {new_count} transcripts newer than last wiki compile "
                f"— run your AI assistant's 'Compile' workflow "
                f"to pull them into the wiki."
            )
            self.banner_action_btn.setVisible(False)
            self._apply_banner_style()
            self.banner.setVisible(True)
        else:
            self._banner_state = ""
            self.banner.setVisible(False)

    # ---------- update-available banner ----------

    def show_update_banner(self, tag: str, url: str) -> None:
        """Public hook: called from ParagraphosApp when core.updater
        detects a newer GitHub release. Idempotent — storing the (tag, url)
        on the window + AppContext so banner survives tab navigation."""
        self._update_tag = tag
        self._update_url = url
        self.ctx.update_available_tag = tag
        self.ctx.update_available_url = url
        self._refresh_banner()

    def _show_update_state(self, tag: str, url: str) -> None:
        self._banner_state = "update"
        self._update_tag = tag
        self._update_url = url
        self.banner_label.setText(
            f"⬆️  Paragraphos {tag} is available — you're on v{self._local_version()}."
        )
        self.banner_action_btn.setText(f"Download {tag}")
        self.banner_action_btn.setVisible(True)
        self._apply_banner_style()
        self.banner.setVisible(True)

    @staticmethod
    def _local_version() -> str:
        from core.version import VERSION

        return VERSION

    def _on_banner_action(self) -> None:
        if self._banner_state == "update" and self._update_url:
            QDesktopServices.openUrl(QUrl(self._update_url))
        elif self._banner_state == "newshow":
            self._open_reconcile_dialog()

    def _open_reconcile_dialog(self) -> None:
        """Open the backlog-reconcile dialog for externally-added shows, then
        refresh the Shows tab + banner to reflect any decisions made."""
        from ui.reconcile_dialog import ReconcileDialog

        ReconcileDialog(self.ctx, self).exec()
        try:
            self.shows_tab.refresh()
        except Exception:
            pass
        self._refresh_banner()

    def _dismiss_banner(self) -> None:
        if self._banner_state == "update" and self._update_tag:
            # Persist per-tag so the next release re-surfaces the banner.
            s = QSettings("madevmuc", "Paragraphos")
            s.setValue("updater/dismissed_tag", self._update_tag)
        self.banner.setVisible(False)
        self._banner_state = ""

    def _is_update_dismissed(self, tag: str) -> bool:
        s = QSettings("madevmuc", "Paragraphos")
        return s.value("updater/dismissed_tag", "", type=str) == tag

    # ---------- offline banner / auto-resume ----------

    def on_online_changed(self, online: bool) -> None:
        """Slot wired from ``core.connectivity.ConnectivityMonitor``.

        When the network drops we DON'T pause the queue — already-
        downloaded episodes still transcribe locally (whisper.cpp needs
        no network). Feed-fetch and new downloads will fail naturally
        and pile up under ``status='failed'`` with network-class error
        text; on reconnect we re-queue those.

        Just surface a banner explaining the partial impact. The worker
        keeps draining its `downloaded` orphan-recovery path, so the
        queue keeps moving on items that don't need bytes from the
        network.
        """
        from core.connectivity import is_network_error

        state = self.ctx.state
        if not online:
            self._banner_state = "offline"
            self.banner_label.setText(
                "Offline — feeds + new downloads pause; transcription continues "
                "on already-downloaded episodes. Will auto-resume on reconnect."
            )
            self.banner_action_btn.setVisible(False)
            self._apply_banner_style()
            self.banner.setVisible(True)
            return

        # Re-queue network-failed episodes from the configurable window.
        # SELECT-then-UPDATE per row: the Python-side classifier filter is
        # cheaper + more accurate than chaining LIKE clauses for every hint.
        from datetime import datetime, timedelta, timezone

        window_h = int(getattr(self.ctx.settings, "auto_resume_failed_window_hours", 24))
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=window_h)).isoformat()
        try:
            with state._conn() as c:
                rows = c.execute(
                    "SELECT guid, error_text FROM episodes "
                    "WHERE status='failed' AND attempted_at > ?",
                    (cutoff,),
                ).fetchall()
                resumed = [r["guid"] for r in rows if is_network_error(r["error_text"])]
                if resumed:
                    c.executemany(
                        "UPDATE episodes SET status='pending', error_text=NULL WHERE guid=?",
                        [(g,) for g in resumed],
                    )
        except Exception:
            # DB hiccup — don't crash the UI; the next manual check will
            # still re-attempt failed items via the existing retry path.
            resumed = []

        # Hide the offline banner before kicking off the next check so the
        # user sees the queue start moving without stale chrome on screen.
        if self._banner_state == "offline":
            self._banner_state = ""
            self.banner.setVisible(False)
            self._refresh_banner()

        # Drain immediately — force=True so the check runs even if the
        # scheduler thinks it ran recently.
        try:
            self.shows_tab.start_check(force=True)
        except Exception:
            pass
