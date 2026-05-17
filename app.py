"""Paragraphos — menu-bar entry point.

Uses QSystemTrayIcon (pure Qt) so the Qt event loop drives everything —
avoids the rumps/NSApp vs. Qt event-loop conflict we ran into.

Run:
    cd scripts/paragraphos
    PYTHONPATH=. ../../.venv/bin/python app.py
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from PyQt6.QtCore import QEvent, QObject, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFileOpenEvent, QFont, QIcon, QPainter, QPixmap
from PyQt6.QtWidgets import (
    QAbstractSpinBox,
    QApplication,
    QComboBox,
    QFileDialog,
    QLineEdit,
    QMessageBox,
    QPlainTextEdit,
    QSystemTrayIcon,
    QTextEdit,
)

from core.logger import setup_logging  # noqa: E402
from core.models import backfill_setup_completed  # noqa: E402
from core.paths import migrate_from_legacy, user_data_dir  # noqa: E402
from core.scheduler import check_counts_as_success, should_catch_up  # noqa: E402
from core.version import VERSION as _LOCAL_VERSION  # noqa: E402
from ui.app_context import AppContext  # noqa: E402
from ui.first_run_wizard import show_wizard_if_needed  # noqa: E402
from ui.main_window import MainWindow  # noqa: E402
from ui.setup_dialog import show_setup_if_needed  # noqa: E402
from ui.worker_thread import CheckAllThread  # noqa: E402

# One-time migration: if the repo source tree has legacy data, copy it to the
# user's Application Support dir. After that, user_data_dir() is canonical.
_LEGACY = Path(__file__).resolve().parent / "data"
_migrated = migrate_from_legacy(_LEGACY)
if _migrated:
    print(
        f"migrated user data to ~/Library/Application Support/Paragraphos/: {_migrated}",
        flush=True,
    )
DATA_DIR = user_data_dir()


def _build_icon() -> QIcon:
    """Bold 'P' on a filled dark circle — non-template so it's visible in both
    light and dark menu bars without relying on emoji fonts (which produce
    blank template icons on many macOS setups)."""
    size = 22
    pm = QPixmap(size, size)
    pm.fill(QColor(0, 0, 0, 0))
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setBrush(QColor(30, 30, 30))
    p.setPen(QColor(30, 30, 30))
    p.drawEllipse(1, 1, size - 2, size - 2)
    p.setPen(QColor(255, 255, 255))
    f = QFont("Helvetica")
    f.setPointSize(13)
    f.setBold(True)
    p.setFont(f)
    p.drawText(pm.rect(), 0x84, "P")  # Qt::AlignCenter
    p.end()
    return QIcon(pm)


class ParagraphosApp(QObject):
    notify = pyqtSignal(str, str, str)  # title, subtitle, body
    update_available = pyqtSignal(str, str)  # tag, html_url — GUI-thread safe

    def __init__(self) -> None:
        super().__init__()
        self.ctx = AppContext.load(DATA_DIR)
        setup_logging(DATA_DIR, retention_days=self.ctx.settings.log_retention_days)
        # One-line system fingerprint at startup — useful when users send
        # logs for debugging. Carefully NO PII: no username, no hostname,
        # no IP, no file paths, no watchlist content. macOS version,
        # arch, CPU/RAM, Python + Paragraphos version, key tuning + tool
        # presence.
        import logging
        import platform

        from core.version import VERSION as _PARAGRAPHOS_VERSION

        log = logging.getLogger(__name__)
        try:
            ram_gb = "?"
            try:
                import subprocess

                proc = subprocess.run(
                    ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=2
                )
                if proc.returncode == 0 and proc.stdout.strip().isdigit():
                    ram_gb = f"{int(proc.stdout) // (1024**3)} GB"
            except Exception:
                pass
            try:
                from core.hw import detect

                _hw = detect()
                cpu_cores = _hw[1] if isinstance(_hw, tuple) else None
            except Exception:
                cpu_cores = None
            from core import ytdlp as _ytdlp_mod

            ytdlp_present = _ytdlp_mod.is_installed()
            # yt-dlp is a PyInstaller-bundled binary — its first
            # `--version` call costs ~11 s on cold cache (measured
            # 2026-04-23). Blocking the GUI startup that long is
            # unacceptable. Cache the value in meta after the first
            # successful probe; on subsequent launches read from cache.
            # If absent, log "—" and kick off an out-of-band probe in a
            # daemon thread that updates the meta — next launch picks
            # it up. Yt-dlp self-updates weekly so the cached value
            # never drifts more than 7 days.
            ytdlp_version = self.ctx.state.get_meta("ytdlp_version_cached") or "—"
            if ytdlp_present and ytdlp_version == "—":
                import threading

                def _probe_ytdlp():
                    try:
                        p = subprocess.run(
                            [str(_ytdlp_mod.ytdlp_path()), "--version"],
                            capture_output=True,
                            text=True,
                            timeout=20,
                        )
                        if p.returncode == 0:
                            v = p.stdout.strip().splitlines()[0]
                            if v:
                                self.ctx.state.set_meta("ytdlp_version_cached", v)
                    except Exception:
                        pass

                threading.Thread(
                    target=_probe_ytdlp, name="ytdlp-version-probe", daemon=True
                ).start()
            # Use the locator the transcriber's PATH-augmenter uses (NOT
            # bare shutil.which), so the fingerprint matches what
            # whisper-cli is actually invoked as. On a .app launched
            # from /Applications the inherited PATH is /usr/bin:/bin
            # only — shutil.which("whisper-cli") returns None even
            # though the binary lives at /opt/homebrew/bin and
            # transcription works fine via WHISPER_BIN's resolved path.
            from core.transcriber import WHISPER_BIN as _WBIN
            from core.transcriber import _locate_ffmpeg_dir as _ff_dir

            def _homebrew_version(bin_path: Path) -> str:
                """Extract a Homebrew formula's version from the symlink
                target, e.g. /opt/homebrew/Cellar/whisper-cpp/1.8.4/bin/...
                → '1.8.4'. Avoids spawning the binary (whisper-cli's
                first-launch GGML init costs seconds + dumps an unhelpful
                BLAS-backend banner that's not a version)."""
                try:
                    real = Path(bin_path).resolve()
                    parts = real.parts
                    if "Cellar" in parts:
                        i = parts.index("Cellar")
                        # parts[i+1] = formula name, parts[i+2] = version
                        if i + 2 < len(parts):
                            return parts[i + 2]
                except Exception:
                    pass
                return "—"

            whisper_bin_path = Path(_WBIN)
            whisper_present = whisper_bin_path.exists()
            whisper_version = _homebrew_version(whisper_bin_path) if whisper_present else "—"
            ffmpeg_dir_path = _ff_dir()
            ffmpeg_present = ffmpeg_dir_path is not None
            ffmpeg_version = (
                _homebrew_version(Path(ffmpeg_dir_path) / "ffmpeg") if ffmpeg_present else "—"
            )

            # Hardware-aware recommendations vs. current settings — log any
            # mismatch so support tickets show 'is the user on the optimal
            # tuning?' at a glance.
            try:
                from core.hw import recommended_multiproc_split, recommended_parallel_workers

                rec_par = recommended_parallel_workers()
                rec_mp = recommended_multiproc_split()
            except Exception:
                rec_par = None
                rec_mp = None

            s = self.ctx.settings
            # Pre-format the full message once so we can both (a) send it
            # to the file handler now and (b) replay it into the in-app
            # LogDock later (after MainWindow wires one). Logging it to
            # the file early matters for post-crash debugging; surfacing
            # it in the dock matters so a user who opens Logs without
            # tailing the log file still sees what they're running.
            _fingerprint_msg = (
                "paragraphos startup | "
                "version=%s | macOS=%s (%s) | python=%s | "
                "cpu_cores=%s | ram=%s | "
                "tooling: whisper-cli=%s (%s) yt-dlp=%s (%s) ffmpeg=%s (%s) | "
                "settings: model=%s parallel=%s%s multiproc=%s%s fast_mode=%s "
                "auto_start=%s auto_start_delay=%ss save_srt=%s "
                "mp3_retention_days=%s "
                "sources_podcasts=%s sources_youtube=%s "
                "youtube_default_language=%s youtube_default_transcript_source=%s "
                "rss_concurrency=%s download_concurrency=%s use_etag_cache=%s "
                "library_scan_cache=%s notify_mode=%s "
                "connectivity_monitor=%s auto_resume_window_h=%s "
                "show_log_dock=%s"
            ) % (
                _PARAGRAPHOS_VERSION,
                platform.mac_ver()[0] or "unknown",
                platform.machine(),
                platform.python_version(),
                cpu_cores or "?",
                ram_gb,
                "yes" if whisper_present else "no",
                whisper_version,
                "yes" if ytdlp_present else "no",
                ytdlp_version,
                "yes" if ffmpeg_present else "no",
                ffmpeg_version,
                s.whisper_model,
                s.parallel_transcribe,
                f" (rec={rec_par})"
                if rec_par is not None and rec_par != s.parallel_transcribe
                else "",
                s.whisper_multiproc,
                f" (rec={rec_mp})" if rec_mp is not None and rec_mp != s.whisper_multiproc else "",
                s.whisper_fast_mode,
                s.auto_start_queue,
                getattr(s, "auto_start_delay_seconds", 5),
                s.save_srt,
                s.mp3_retention_days,
                s.sources_podcasts,
                s.sources_youtube,
                getattr(s, "youtube_default_language", "de"),
                s.youtube_default_transcript_source,
                s.rss_concurrency,
                s.download_concurrency,
                s.use_etag_cache,
                s.library_scan_cache,
                s.notify_mode,
                getattr(s, "connectivity_monitor_enabled", True),
                getattr(s, "auto_resume_failed_window_hours", 24),
                getattr(s, "show_log_dock", False),
            )
            log.info(_fingerprint_msg)
            # Stash for replay into the LogDock once open_window wires
            # one — see _replay_fingerprint_into_dock below.
            self._startup_fingerprint_msg = _fingerprint_msg
        except Exception as _exc:  # noqa: BLE001
            log.warning("paragraphos startup fingerprint failed: %s", _exc)
            self._startup_fingerprint_msg = None
        self._thread: CheckAllThread | None = None
        self._run_tally: dict[str, object] = {}
        self._catch_up_pending = False

        # Non-blocking update check against GitHub releases. Runs in a
        # daemon thread; emit through a signal so the UI sees it on the GUI
        # thread regardless of where the HTTP callback fires.
        from core.updater import check_for_update

        self.update_available.connect(self._on_update_available)
        if self.ctx.settings.update_check_enabled:
            check_for_update(
                local_version=_LOCAL_VERSION,
                on_update_available=lambda tag, url: self.update_available.emit(tag, url),
                repo=self.ctx.settings.github_repo,
            )

        if not QSystemTrayIcon.isSystemTrayAvailable():
            print("ERROR: system tray not available on this system.", flush=True)
        from ui.widgets import IconRenderer

        self._icon_renderer = IconRenderer()
        self.tray = QSystemTrayIcon(self._icon_renderer.render())
        self.tray.setToolTip("Paragraphos")
        self.tray.activated.connect(self._on_tray_activated)

        # Tray push notifications on macOS: QSystemTrayIcon.showMessage
        # maps to legacy NSUserNotification, which ignores any QIcon we
        # pass — it always shows the bundle's own CFBundleIconFile.
        # Passing MessageIcon.Information as Qt does by default makes
        # macOS overlay a generic ⓘ glyph on top. NoIcon clears that so
        # the bubble shows just the app icon (which IS the pilcrow via
        # the bundled assets/AppIcon.icns wired through py2app
        # iconfile=).
        _orig_show = self.tray.showMessage

        def _show_with_icon(title, body, *args, **kwargs):
            if args or kwargs:
                return _orig_show(title, body, *args, **kwargs)
            return _orig_show(
                title,
                body,
                QSystemTrayIcon.MessageIcon.NoIcon,
                5000,
            )

        self.tray.showMessage = _show_with_icon  # type: ignore[assignment]

        self._rebuild_tray_menu(running=False)
        self.tray.show()

        # Re-render the tray icon when macOS flips light/dark so its
        # glyph color tracks the new menu-bar appearance.
        from ui.themes import manager as _theme_manager

        _tm = _theme_manager()
        if _tm is not None:
            _tm.themeChanged.connect(self._on_theme_changed)
        print(
            f"paragraphos ready — tray visible={self.tray.isVisible()}, "
            f"system-tray-available={QSystemTrayIcon.isSystemTrayAvailable()}",
            flush=True,
        )

        # Open the window FIRST, then catch-up, so the Stop button is wired
        # via ShowsTab.start_check() instead of running headless.
        QTimer.singleShot(300, self.open_window)

        self._window: MainWindow | None = None

        # Scheduler — runs in the APScheduler BackgroundScheduler (thread).
        # The cron job calls _run_check; Qt signals marshal back to the GUI thread.
        from core.scheduler import build_scheduler

        self._sched = build_scheduler(
            self.ctx.settings.daily_check_time, self._run_check_on_gui_thread
        )
        self._sched.start()

        # Delay before either the catch-up or the regular auto-start fires.
        # Settings → 'Auto-start delay' (default 5 s). Gives the window time
        # to paint and the tray icon to appear before the queue grabs CPU.
        _delay_ms = max(0, int(getattr(self.ctx.settings, "auto_start_delay_seconds", 5))) * 1000
        self._auto_start_delay_ms = _delay_ms
        _qapp = QApplication.instance()
        if _qapp is not None:
            _qapp.applicationStateChanged.connect(self._on_app_activated)
            _qapp.applicationStateChanged.connect(self._on_activation_update_check)

        if self.ctx.settings.catch_up_missed and should_catch_up(
            self.ctx.state.get_meta("last_successful_check"),
            self.ctx.settings.daily_check_time,
        ):
            # Fire AFTER the window opens so ShowsTab owns the thread.
            self.ctx.state.set_meta("queue_paused", "0")
            self._catch_up_pending = True
            QTimer.singleShot(
                _delay_ms,
                lambda: (setattr(self, "_catch_up_pending", False), self._run_check()),
            )
        elif getattr(self.ctx.settings, "auto_start_queue", True):
            # Auto-start the queue on launch (checkbox in Settings, on by
            # default). If a previous session left the queue paused, the
            # user's explicit setting here overrides — a launch-time
            # auto-start means "resume and go", not "sit and wait".
            self.ctx.state.set_meta("queue_paused", "0")
            QTimer.singleShot(_delay_ms, lambda: self._run_check(force=False))

    def _rebuild_tray_menu(
        self,
        *,
        running: bool,
        done: int = 0,
        total: int = 0,
        current_title: str = "",
        eta_sec: int | None = None,
    ) -> None:
        """Rebuild the tray context menu, swapping between idle and a
        rich status block while a queue run is active. Keeps a strong
        reference on `self` so the QMenu is not GC'd while shown."""
        from ui.menu_bar import build_tray_menu

        self._tray_menu = build_tray_menu(
            running=running,
            done=done,
            total=total,
            current_title=current_title,
            eta_sec=eta_sec,
            on_open=self.open_window,
            on_check_now=lambda: self._run_check(force=True),
            on_import_opml=self._import_opml,
            on_quit=self.quit_with_confirm,
        )
        self.tray.setContextMenu(self._tray_menu)

    def _on_update_available(self, tag: str, url: str) -> None:
        """GUI-thread receiver for the updater's async callback. Stores
        the (tag, url) on AppContext so any later-opened MainWindow can
        still find it, surfaces an in-window banner with a Download button,
        and fires a one-shot tray notification."""
        self.ctx.update_available_tag = tag
        self.ctx.update_available_url = url
        if self._window is not None:
            self._window.show_update_banner(tag, url)
        self.tray.showMessage(
            "Paragraphos update available",
            f"{tag} is out — you have v{_LOCAL_VERSION}. Click the Download button in the window.",
        )

    def _on_theme_changed(self, _mode: str) -> None:
        """Re-render the tray icon so its glyph color flips with the
        menu-bar appearance. Cheap — just re-draws a 22/44 px pixmap.
        Preserves the current idle vs. running state if any.
        """
        q = self.ctx.queue
        if q.running and q.total > 0:
            self.tray.setIcon(self._icon_renderer.render(q.done, q.total, running=True))
        else:
            self.tray.setIcon(self._icon_renderer.render())

    def _on_tray_activated(self, reason):
        # Single-click on macOS tray opens the window; Qt's default context menu
        # still works on right-click.
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.open_window()

    def open_window(self) -> None:
        first_open = self._window is None
        if self._window is None:
            self._window = MainWindow()
            # If a background check was already running before the window
            # existed, hand the thread over so the Stop button works.
            if self._thread and self._thread.isRunning():
                self._window.shows_tab.attach_external_thread(self._thread)
            # If an update was detected before the window existed, surface
            # the banner now that there's a window to show it in.
            if self.ctx.update_available_tag and self.ctx.update_available_url:
                self._window.show_update_banner(
                    self.ctx.update_available_tag, self.ctx.update_available_url
                )
        if first_open:
            # Replay the startup fingerprint into the dock + logs pane so
            # a user who opens Logs can see exactly which tool versions
            # and settings this process is running with. The fingerprint
            # is logged to the file handler during __init__ (before the
            # dock exists), but the in-app dock only receives messages
            # passed to its .append() API.
            self._replay_fingerprint_into_dock()
        self._window.show()
        self._window.raise_()
        self._window.activateWindow()

    def _replay_fingerprint_into_dock(self) -> None:
        msg = getattr(self, "_startup_fingerprint_msg", None)
        if not msg or self._window is None:
            return
        try:
            self._window.log_dock.append(msg)
        except Exception:  # noqa: BLE001
            pass
        try:
            self._window.logs_pane.append(msg)
        except Exception:  # noqa: BLE001
            pass

    def _run_check_on_gui_thread(self) -> None:
        # Scheduled fire (APScheduler cron) — keep force=False so parked
        # feeds stay parked until their 1/3/7-day backoff window expires.
        QTimer.singleShot(0, self._run_check)

    def _run_check(self, *, force: bool = False) -> None:
        # If the window exists, delegate to ShowsTab.start_check() — that path
        # wires the Stop button correctly. Otherwise fall back to owning the
        # thread ourselves (e.g. a scheduler firing before the user opens the
        # window).
        #
        # ``force`` only propagates meaningfully to user-initiated entry
        # points (tray "Check now"). Scheduler / startup catch-up call this
        # with the default False so feed backoff is respected.
        if self._window is not None:
            started = self._window.shows_tab.start_check(force=force)
            if not started:
                self.tray.showMessage("Paragraphos", "A check is already running.")
                return
            self._thread = self._window.shows_tab._thread
        else:
            if self._thread and self._thread.isRunning():
                self.tray.showMessage("Paragraphos", "A check is already running.")
                return
            self._thread = CheckAllThread(self.ctx, self.ctx.settings, force=force)
            self._thread.start()
        # Whatever the source, connect app-level notification hooks.
        self._thread.episode_done.connect(self._on_episode_done)
        self._thread.finished_all.connect(self._on_check_done)

    def _on_app_activated(self, state: Qt.ApplicationState) -> None:
        """Catch up a missed daily check when the app is brought to the
        foreground. ``should_catch_up`` gates this to once per daily slot
        (it compares against last_successful_check), so this does not
        re-fire on every tray click within the same day. ``_catch_up_pending``
        guards the delay window between scheduling and the run actually
        starting, so a refocus within that window (or the cold-launch
        catch-up overlapping an activation) does not queue a second
        ``_run_check`` and emit a spurious "already running" toast."""
        if state != Qt.ApplicationState.ApplicationActive:
            return
        if self._catch_up_pending:
            return
        if not self.ctx.settings.catch_up_missed:
            return
        if self._is_queue_busy():
            return
        if not should_catch_up(
            self.ctx.state.get_meta("last_successful_check"),
            self.ctx.settings.daily_check_time,
        ):
            return
        self.ctx.state.set_meta("queue_paused", "0")
        self._catch_up_pending = True
        QTimer.singleShot(
            self._auto_start_delay_ms,
            lambda: (setattr(self, "_catch_up_pending", False), self._run_check()),
        )

    def _on_activation_update_check(self, state: Qt.ApplicationState) -> None:
        """Re-check GitHub releases when the app is foregrounded, gated to
        once per 24h via ``last_update_check`` meta. Fully decoupled from
        the catch-up slot — a user with catch_up_missed off (or no missed
        daily check) must still get update checks. ``check_for_update``
        spawns its own daemon thread, so this returns immediately."""
        from core.updater import check_for_update, should_recheck_update

        if state != Qt.ApplicationState.ApplicationActive:
            return
        if not self.ctx.settings.update_check_enabled:
            return
        now = datetime.now(timezone.utc)
        if not should_recheck_update(self.ctx.state.get_meta("last_update_check"), now):
            return
        self.ctx.state.set_meta("last_update_check", now.isoformat())
        check_for_update(
            local_version=_LOCAL_VERSION,
            on_update_available=lambda tag, url: self.update_available.emit(tag, url),
            repo=self.ctx.settings.github_repo,
        )

    def _on_episode_done(
        self,
        slug: str,
        guid: str,
        action: str,
        done_idx: int,
        total: int,
        show_title: str,
        ep_title: str,
    ) -> None:
        # Live tray icon — renders current fraction while a run is active.
        self.tray.setIcon(self._icon_renderer.render(done_idx, total, running=True))
        # Rich status block in the tray context menu — rebuilt on every
        # episode_done tick so the fraction / ETA / Now line stay live.
        q = self.ctx.queue
        eta = int(q.effective_avg_sec * (total - done_idx)) if q.effective_avg_sec else None
        self._rebuild_tray_menu(
            running=True,
            done=done_idx,
            total=total,
            current_title=f"{show_title} — {ep_title}",
            eta_sec=eta,
        )
        # Tally into the rolling run-summary — used by daily_summary mode.
        self._run_tally.setdefault(action, 0)
        self._run_tally[action] += 1
        if self._run_tally.get("_first_ep_title") is None and action == "transcribed":
            self._run_tally["_first_ep_title"] = f"{show_title} — {ep_title}"

        mode = self.ctx.settings.notify_mode
        if mode == "off":
            return
        if action != "transcribed":
            return
        spot_key = f"spotcheck_done:{slug}"
        title_prefix = f"{done_idx}/{total}"
        if self.ctx.state.get_meta(spot_key) != "1":
            # Spot-check: one-time per-show QA handshake. Respects
            # notify_mode="off" via the early-return above — users who
            # opted out of notifications get zero tray messages, ever.
            self.ctx.state.set_meta(spot_key, "1")
            self.tray.showMessage(
                f"✅ First transcript — {show_title}",
                f"{title_prefix} — {ep_title[:80]}\n"
                f"Open in Obsidian to spot-check the whisper_prompt quality.",
            )
            return
        if mode == "per_episode":
            self.tray.showMessage(
                f"{title_prefix} — {show_title}",
                ep_title[:120],
            )

    def quit_with_confirm(self) -> bool:
        """Show a confirm dialog if the queue is running / work would be lost.

        Returns True if the app is actually quitting, False if the user
        cancelled. Covers tray menu 'Quit' and Cmd+Q (via event filter).
        """
        if self._is_queue_busy():
            from PyQt6.QtWidgets import QMessageBox

            q = self.ctx.queue
            box = QMessageBox(
                QMessageBox.Icon.Warning,
                "Queue still running",
                f"Paragraphos is still working on {q.done}/{q.total} episodes. "
                "Quitting now will interrupt the current download/transcription "
                "— the partial MP3 survives (resumable), but a partial transcript "
                "will be discarded and re-run next time.\n\n"
                "Quit anyway?",
                QMessageBox.StandardButton.NoButton,
                self._window if self._window else None,
            )
            quit_btn = box.addButton("Quit", QMessageBox.ButtonRole.DestructiveRole)
            box.addButton("Stay", QMessageBox.ButtonRole.RejectRole)
            box.setDefaultButton(box.buttons()[-1])  # Stay is safer default
            box.exec()
            if box.clickedButton() is not quit_btn:
                return False
        QApplication.quit()
        return True

    def _is_queue_busy(self) -> bool:
        q = self.ctx.queue
        if q.running:
            return True
        # Check the DB too — an episode might be mid-download/transcribe even
        # when q.running is False (e.g. app somehow lost thread state).
        with self.ctx.state._conn() as c:
            row = c.execute(
                "SELECT COUNT(*) FROM episodes WHERE status IN ('downloading','transcribing')"
            ).fetchone()
        return (row[0] or 0) > 0

    def _on_check_done(self) -> None:
        from core.connectivity import is_online

        stopped = bool(getattr(self._thread, "_stop", False)) if self._thread else False
        paused = self.ctx.state.get_meta("queue_paused") == "1"
        if check_counts_as_success(stopped=stopped, paused=paused, online=is_online()):
            self.ctx.state.set_meta(
                "last_successful_check",
                datetime.now(timezone.utc).isoformat(),
            )
        # Daily-summary notification: single consolidated message after a
        # run instead of one-per-episode. Useful for overnight catch-ups.
        if self.ctx.settings.notify_mode == "daily_summary":
            t = self._run_tally
            done = int(t.get("transcribed", 0))
            skipped = int(t.get("skipped", 0))
            failed = int(t.get("failed", 0))
            if done + failed > 0:
                parts = []
                if done:
                    parts.append(f"{done} new")
                if failed:
                    parts.append(f"{failed} failed")
                if skipped:
                    parts.append(f"{skipped} skipped")
                self.tray.showMessage(
                    "Paragraphos — run complete",
                    " · ".join(parts) + "\n" + f"First: {t.get('_first_ep_title') or '—'}",
                )
        self._run_tally = {}
        # Revert tray context menu to the idle shape.
        self._rebuild_tray_menu(running=False)
        # Briefly show ✓ on the tray, then revert to idle 'P'.
        self.tray.setIcon(self._icon_renderer.render(override_text="✓"))
        QTimer.singleShot(5000, lambda: self.tray.setIcon(self._icon_renderer.render()))
        if self._window:
            self._window.shows_tab.refresh()

    def on_file_dropped(self, path: str) -> None:
        """Finder drag-&-drop of .opml onto Dock / app icon."""
        p = Path(path)
        if p.suffix.lower() not in (".opml", ".xml"):
            return
        self._import_opml_from_path(p)
        # Open the window so the user sees the new shows appear.
        self.open_window()

    def _import_opml_from_path(self, path: Path) -> None:
        from core.models import Show
        from core.opml import parse_opml
        from core.rss import build_manifest, feed_metadata
        from core.sanitize import slugify

        try:
            entries = parse_opml(path)
        except Exception as e:
            self.tray.showMessage("OPML import failed", str(e))
            return
        existing = {s.slug for s in self.ctx.watchlist.shows}
        added = 0
        for entry in entries:
            try:
                meta = feed_metadata(entry["xmlUrl"])
                manifest = build_manifest(entry["xmlUrl"], timeout=60)
            except Exception:
                continue
            slug = slugify(meta["title"] or entry["title"])
            if slug in existing:
                continue
            self.ctx.watchlist.shows.append(
                Show(
                    slug=slug,
                    title=meta["title"] or entry["title"],
                    rss=entry["xmlUrl"],
                    whisper_prompt="",
                )
            )
            for ep in manifest:
                self.ctx.state.upsert_episode(
                    show_slug=slug,
                    guid=ep["guid"],
                    title=ep["title"],
                    pub_date=ep["pubDate"],
                    mp3_url=ep["mp3_url"],
                )
            added += 1
        self.ctx.watchlist.save(self.ctx.data_dir / "watchlist.yaml")
        self.tray.showMessage("OPML imported", f"Added {added} show(s) from {path.name}")
        if self._window:
            self._window.shows_tab.refresh()

    def _import_opml(self) -> None:
        from core.models import Show
        from core.opml import parse_opml
        from core.rss import build_manifest, feed_metadata
        from core.sanitize import slugify

        path, _filter = QFileDialog.getOpenFileName(
            None, "Select OPML file", str(Path.home()), "OPML (*.opml *.xml)"
        )
        if not path:
            return
        try:
            entries = parse_opml(Path(path))
        except Exception as e:
            QMessageBox.warning(None, "OPML error", str(e))
            return

        existing = {s.slug for s in self.ctx.watchlist.shows}
        added, errors = 0, []
        for entry in entries:
            try:
                meta = feed_metadata(entry["xmlUrl"])
                manifest = build_manifest(entry["xmlUrl"], timeout=60)
            except Exception as e:
                errors.append(f"{entry['title']}: {e}")
                continue
            slug = slugify(meta["title"] or entry["title"])
            if slug in existing:
                continue
            self.ctx.watchlist.shows.append(
                Show(
                    slug=slug,
                    title=meta["title"] or entry["title"],
                    rss=entry["xmlUrl"],
                    whisper_prompt="",
                )
            )
            for ep in manifest:
                self.ctx.state.upsert_episode(
                    show_slug=slug,
                    guid=ep["guid"],
                    title=ep["title"],
                    pub_date=ep["pubDate"],
                    mp3_url=ep["mp3_url"],
                )
            added += 1
        self.ctx.watchlist.save(self.ctx.data_dir / "watchlist.yaml")
        summary = f"Imported {added} new show(s)."
        if errors:
            summary += "\n\nErrors (first 10):\n" + "\n".join(errors[:10])
        QMessageBox.information(None, "OPML import", summary)


class ParagraphosQApplication(QApplication):
    """Intercepts macOS QFileOpenEvent so Finder → Dock drops of .opml files
    land inside the running app instead of launching a new instance.

    Also intercepts QuitEvent (⌘Q, app menu Quit) to route it through our
    confirm-if-queue-running dialog. A weak reference to ParagraphosApp is set
    from main() so we can delegate.
    """

    file_opened = pyqtSignal(str)
    quit_requested = pyqtSignal()

    def event(self, e):
        t = e.type()
        if t == QEvent.Type.FileOpen and isinstance(e, QFileOpenEvent):
            self.file_opened.emit(e.file())
            return True
        if t == QEvent.Type.Quit:
            # Delegate to the app-owned handler. Quit-events arrive from
            # Cmd+Q, Dock → Quit, and apple-quit — catch them all.
            self.quit_requested.emit()
            return True
        return super().event(e)


_INPUT_TYPES = (QLineEdit, QTextEdit, QPlainTextEdit, QAbstractSpinBox, QComboBox)


class _FocusClearFilter(QObject):
    """Clear focus from text/number inputs when the user clicks outside them.

    Without this, clicking on the gray background of the Settings pane leaves
    the previously-focused QLineEdit still showing a cursor — which looks like
    a bug. We only target input widgets; buttons and menus keep their normal
    focus behaviour (Qt handles those automatically on click).
    """

    def eventFilter(self, obj, event):
        if event.type() == QEvent.Type.MouseButtonPress:
            app = QApplication.instance()
            fw = app.focusWidget() if app else None
            if fw and isinstance(fw, _INPUT_TYPES):
                try:
                    target = app.widgetAt(event.globalPosition().toPoint())
                except AttributeError:
                    target = None
                if target is not fw and not _is_descendant(target, fw):
                    fw.clearFocus()
        return False


def _is_descendant(widget, ancestor) -> bool:
    while widget is not None:
        if widget is ancestor:
            return True
        widget = widget.parent()
    return False


def _acquire_single_instance_lock():
    """Acquire an exclusive flock on a per-user lock file. Returns the
    open fd on success (caller must keep it alive for the app's lifetime),
    or None if another instance already holds the lock.

    Without this, accidental double-launches (Dock click while already
    running, kill + immediate relaunch races, etc.) leave multiple
    paragraphos processes hammering the same SQLite DB and the user
    sees stale UI from a zombie instance.
    """
    import fcntl

    from core.paths import user_data_dir

    lock_path = user_data_dir() / "paragraphos.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = open(lock_path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fd.write(str(os.getpid()))
        fd.flush()
        return fd
    except BlockingIOError:
        fd.close()
        return None


def maybe_start_watch_folder(
    *,
    settings,
    state,
    watchlist_path,
):
    """Create + start a WatchFolder iff enabled in settings. Returns the
    instance (or None). Callers own the stop()."""
    from core.watch_folder import WatchFolder

    if not getattr(settings, "watch_folder_enabled", False):
        return None
    wf = WatchFolder(
        root=Path(settings.watch_folder_root).expanduser(),
        state=state,
        watchlist_path=watchlist_path,
        max_duration_hours=settings.local_max_duration_hours,
    )
    wf.start()
    return wf


def _install_slot_exception_handler() -> None:
    """Replace ``sys.excepthook`` so a Python exception raised inside a
    PyQt6 slot logs + (best-effort) shows a non-fatal dialog instead of
    aborting the whole app via ``qFatal``.

    PyQt6 changed PyQt5's behaviour: an uncaught exception in a slot
    now reaches ``pyqt6_err_print()`` which calls ``qFatal`` → SIGABRT.
    For an interactive desktop app that's user-hostile — one Python
    bug in a button handler kills the entire window with no chance to
    save state. Routing through ``sys.excepthook`` neutralises the
    qFatal path; the exception is logged and (when a QApplication is
    alive) surfaced via QMessageBox.
    """
    import logging
    import traceback

    log = logging.getLogger("paragraphos")
    original = sys.excepthook

    def _hook(exc_type, exc, tb):
        # Log the full traceback first — never lose the diagnostic.
        text = "".join(traceback.format_exception(exc_type, exc, tb))
        log.error("uncaught exception:\n%s", text)
        # Best-effort UI surface; tolerate any failure inside the dialog
        # (e.g. no QApplication, headless mode, exception during
        # construction of the QMessageBox itself).
        try:
            from PyQt6.QtWidgets import QApplication, QMessageBox

            if QApplication.instance() is not None:
                QMessageBox.critical(
                    None,
                    "Paragraphos — internal error",
                    f"{exc_type.__name__}: {exc}\n\n"
                    "The app stayed running. Check the log for the "
                    "full traceback.",
                )
        except Exception:  # noqa: BLE001
            pass
        # Chain to the previous excepthook so anything else hooked in
        # (debugger, IDE) still sees the exception.
        try:
            original(exc_type, exc, tb)
        except Exception:  # noqa: BLE001
            pass

    sys.excepthook = _hook


def main() -> int:
    # Single-instance gate. If another paragraphos is already running,
    # exit silently — the running instance keeps serving the user.
    _lock_fd = _acquire_single_instance_lock()
    if _lock_fd is None:
        print(
            "Paragraphos is already running — bring the running window to the front.",
            file=sys.stderr,
        )
        return 0
    # Keep the lock fd alive for the app's lifetime by stashing it on a
    # module-level holder; the OS releases the flock when the process exits.
    globals()["_PARAGRAPHOS_LOCK_FD"] = _lock_fd

    qapp = ParagraphosQApplication(sys.argv)
    qapp.setQuitOnLastWindowClosed(False)

    # Install AFTER QApplication so the QMessageBox in the hook can
    # find an instance, but BEFORE any widget is constructed so the
    # very first slot exception is caught.
    _install_slot_exception_handler()

    # App / dock / window icon — bundled AppIcon.icns.
    _icon_path = Path(__file__).resolve().parent / "assets" / "AppIcon.icns"
    if _icon_path.exists():
        qapp.setWindowIcon(QIcon(str(_icon_path)))

    # Install the theme manager BEFORE any widget construction — widgets
    # subscribe to its themeChanged signal at __init__ time.
    from ui.themes import install_manager

    install_manager(qapp)
    _focus_filter = _FocusClearFilter()
    qapp.installEventFilter(_focus_filter)
    qapp._focus_filter = _focus_filter  # keep reference alive
    if not show_wizard_if_needed(qapp):
        print("First-run wizard cancelled — exiting.", flush=True)
        return 0
    app = ParagraphosApp()
    # Background connectivity monitor — pauses the queue + shows a banner
    # when the network drops, auto-resumes + re-queues network-failed items
    # when it returns. Off-switch via Settings.connectivity_monitor_enabled
    # for users behind captive portals where the probes would be noisy.
    from core.connectivity import ConnectivityMonitor

    if app.ctx.settings.connectivity_monitor_enabled:
        app._conn_monitor = ConnectivityMonitor()
        app._conn_monitor.online_changed.connect(
            lambda online: app._window.on_online_changed(online) if app._window else None
        )
        app._conn_monitor.start()
    # Universal-ingest watch folder — starts iff the user opted in via
    # Settings. Observes the chosen root recursively and ingests any
    # dropped-in media file through ``core.local_source``.
    watch_folder = maybe_start_watch_folder(
        settings=app.ctx.settings,
        state=app.ctx.state,
        watchlist_path=app.ctx.data_dir / "watchlist.yaml",
    )
    if watch_folder is not None:
        app._watch_folder = watch_folder
        qapp.aboutToQuit.connect(watch_folder.stop)

        from PyQt6.QtCore import QTimer

        _wf_timer = QTimer()
        _wf_timer.setInterval(30_000)  # 30 s
        _wf_timer.timeout.connect(app._watch_folder.check_for_resume)
        _wf_timer.start()
        app._watch_folder_timer = _wf_timer  # keep-alive reference
        qapp.aboutToQuit.connect(_wf_timer.stop)
    # New-install migration: flip ``setup_completed`` for legacy users
    # whose customised folder paths imply they've already done the work
    # the setup dialog asks about. Fresh installs see the dialog once;
    # returning users don't get ambushed.
    backfill_setup_completed(app.ctx.settings)
    show_setup_if_needed(app.ctx.settings, app._window)
    # Persist whatever the setup dialog wrote back (incl. the
    # ``setup_completed=True`` flag on Finish).
    app.ctx.settings.save(app.ctx.data_dir / "settings.yaml")
    qapp.file_opened.connect(app.on_file_dropped)
    qapp.quit_requested.connect(app.quit_with_confirm)
    from core.http import close_client

    qapp.aboutToQuit.connect(close_client)
    ParagraphosApp.instance = app  # keep reference
    return qapp.exec()


if __name__ == "__main__":
    raise SystemExit(main())
