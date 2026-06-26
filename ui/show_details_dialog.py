"""Per-show details dialog — opens on row-double-click in Shows tab.

A resizable/maximizable dialog (min 620×560) with an artwork header, a
120 px / flex form grid, the full episode list (multi-select table with
status `Pill`s), and a footer row (Remove · Mark stale · Save).

Save / remove / mark-stale logic is preserved from the previous revision
— only the layout and widget composition changed.
"""

from __future__ import annotations

from pathlib import Path

from PyQt6.QtCore import QDate, Qt, QThread, QTimer, pyqtSignal
from PyQt6.QtGui import QFont, QPainter, QPainterPath, QPixmap
from PyQt6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDateEdit,
    QDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QSizePolicy,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from core import ytdlp
from core.state import EpisodeStatus
from core.stats import compute_show_stats
from core.watchlist_io import save_watchlist
from core.youtube import channel_id_from_feed_url, manifest_from_videos
from ui.prioritize import (
    PRIORITY_RUN_NEXT,
    PRIORITY_RUN_NOW,
    bump_priority,
    can_bump,
)
from ui.retranscribe import retranscribe_episode
from ui.themes import current_tokens
from ui.widgets.pill import Pill

# Episode-status → Pill-kind mapping. `done` is the canonical success
# state in `core.stats`; other values map conservatively. Neither
# `skipped` (intentionally not processed) nor `deferred` (waiting to be
# re-checked later, e.g. a live/premiere not yet finished) is a failure:
# `skipped` reads as neutral/idle, `deferred` as amber waiting/paused —
# both visually distinct from `failed`.
_STATUS_PILL_KIND = {
    "done": "ok",
    "transcribed": "ok",
    "failed": "fail",
    "pending": "running",
    "downloading": "running",
    "downloaded": "running",
    "transcribing": "running",
    "skipped": "idle",
    "deferred": "pausing",
    "paused": "pausing",  # user-deactivated: held in the queue, not processed
    # Synthetic back-catalogue rows discovered by the history stream — not
    # yet seeded into the DB, so they read as neutral/idle until triggered.
    "available": "idle",
}

# Paced back-catalogue streaming (Task 4.7). Appending the full channel
# history all at once janks the UI on a long-running channel, so we drip the
# not-yet-seeded videos into the table a batch at a time on a QTimer, and cap
# how many we append per session behind a "Load more" button.
_HISTORY_TICK_MS = 60  # interval between paced appends
_HISTORY_BATCH = 25  # rows appended per tick
_HISTORY_CAP = 300  # max synthetic rows appended before "Load more"

# (display label, whisper language code) — mirrors the pre-restyle picker.
_LANGUAGES = [
    ("Deutsch", "de"),
    ("English", "en"),
    ("Español", "es"),
    ("Français", "fr"),
    ("Italiano", "it"),
    ("Nederlands", "nl"),
    ("Português", "pt"),
    ("Polski", "pl"),
    ("Čeština", "cs"),
    ("Русский", "ru"),
    ("日本語", "ja"),
    ("中文", "zh"),
    ("Auto-detect", "auto"),
]


class _FeedMetadataThread(QThread):
    """Short-lived worker: fetches RSS channel metadata off the UI thread.

    Emits `ok(dict)` on success or `err(str)` on failure. The dialog owns the
    instance (kept as `self._metadata_thread`) so it isn't GC'd mid-flight.
    """

    ok = pyqtSignal(dict)
    err = pyqtSignal(str)

    def __init__(self, url: str, timeout: float = 15.0, parent=None):
        super().__init__(parent)
        self._url = url
        self._timeout = timeout

    def run(self) -> None:  # noqa: D401 — QThread entry
        from core.rss import feed_metadata

        try:
            meta = feed_metadata(self._url, timeout=self._timeout)
        except Exception as exc:  # noqa: BLE001 — surfaced via signal
            self.err.emit(str(exc))
            return
        self.ok.emit(meta or {})


class _ArtworkFetchThread(QThread):
    """Short-lived worker: downloads (or reads from cache) cover art.

    Emits ``ready(Path)`` on success or ``missing()`` on any failure —
    the dialog keeps showing the 🎙 placeholder when missing fires, so
    we don't need to distinguish error types.
    """

    ready = pyqtSignal(object)  # pathlib.Path
    missing = pyqtSignal()

    def __init__(self, slug: str, url: str, parent=None):
        super().__init__(parent)
        self._slug = slug
        self._url = url

    def run(self) -> None:  # noqa: D401 — QThread entry
        from core.artwork import ensure_artwork

        path = ensure_artwork(self._slug, self._url)
        if path is None:
            self.missing.emit()
        else:
            self.ready.emit(path)


class _YoutubeHistoryThread(QThread):
    """Short-lived worker: enumerates a YouTube channel's full upload history
    off the UI thread via yt-dlp's flat-playlist dump.

    Emits ``loaded(list)`` with the flat-playlist dicts on success or
    ``failed(str)`` on error. The dialog owns the instance (kept as
    ``self._history_thread``) so it isn't GC'd mid-flight, and cancels it on
    close. Mirrors the ``_FeedMetadataThread`` idiom — the import lives inside
    ``run`` so tests can patch ``core.youtube_meta.enumerate_channel_videos``.
    """

    loaded = pyqtSignal(list)
    failed = pyqtSignal(str)

    def __init__(self, channel_id: str, include_shorts: bool, parent=None):
        super().__init__(parent)
        self._channel_id = channel_id
        self._include_shorts = include_shorts

    def run(self) -> None:  # noqa: D401 — QThread entry
        from core.youtube_meta import enumerate_channel_videos

        try:
            videos = enumerate_channel_videos(self._channel_id, include_shorts=self._include_shorts)
        except Exception as exc:  # noqa: BLE001 — surfaced via signal
            self.failed.emit(str(exc))
            return
        self.loaded.emit(videos or [])


def _rounded_pixmap(src: QPixmap, side: int, radius: int) -> QPixmap:
    """Crop ``src`` to a ``side``×``side`` square with rounded corners.

    Scaling is done with SmoothTransformation and the crop is centered so
    16:9 / portrait sources still look right in the 64 px frame.
    """
    scaled = src.scaled(
        side,
        side,
        Qt.AspectRatioMode.KeepAspectRatioByExpanding,
        Qt.TransformationMode.SmoothTransformation,
    )
    # Centre-crop to square.
    x = (scaled.width() - side) // 2
    y = (scaled.height() - side) // 2
    cropped = scaled.copy(x, y, side, side)

    out = QPixmap(side, side)
    out.fill(Qt.GlobalColor.transparent)
    p = QPainter(out)
    p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    path = QPainterPath()
    path.addRoundedRect(0, 0, side, side, radius, radius)
    p.setClipPath(path)
    p.drawPixmap(0, 0, cropped)
    p.end()
    return out


class ShowDetailsDialog(QDialog):
    def __init__(self, ctx, slug: str, parent=None):
        super().__init__(parent)
        self.ctx = ctx
        self.slug = slug
        # Active episode-status filter (None = show all). Initialised before
        # any widget builder runs so the first `_reload_episodes()` (inside
        # `_build_episodes_table`) sees it.
        self._status_filter: str | None = None
        # Paced back-catalogue stream state (Task 4.7). The buffer is the
        # queue of not-yet-appended "available" manifest entries; it is
        # drained from the front by `_append_next_batch`. Initialised before
        # any builder runs so the very first `_reload_episodes()` can safely
        # reference it. The cap is an instance attribute so it can be tuned
        # (and is lowered by tests) without touching the module constant.
        self._available_buffer: list = []
        # guid → manifest entry for every synthetic "available" row currently
        # known (on screen or buffered). Lets bulk-queue seed an available row
        # that has no DB row yet, and survives filter toggles.
        self._available_entries: dict[str, dict] = {}
        self._history_cap: int = _HISTORY_CAP
        self._history_session_count: int = 0
        # Latched once the stream is cancelled (dialog closing): a late
        # `loaded` signal or stray timer tick must not re-start appending.
        self._history_cancelled: bool = False
        self.show_ = next((s for s in ctx.watchlist.shows if s.slug == slug), None)
        if self.show_ is None:
            self.reject()
            return
        self.setWindowTitle(f"{self.show_.title} — Details")
        # Minimum size (not fixed): the dialog has to fit header + form +
        # collapsible Advanced + episodes table + footer. Fixed 440 h
        # clipped the footer off-screen on the v1.0.0 restyle.
        self.setMinimumSize(620, 560)
        # Open at 80%×80% of the main window so the episode browser has room to
        # show a long back-catalogue (falls back to a fixed size if unparented).
        self._resize_to_parent()
        # The episodes table is now a full browser (every episode, not the
        # last 10) — let the user maximize/resize the window to scan a long
        # back-catalogue. The dialog is already non-fixed; this just exposes
        # the OS maximize affordance.
        self.setWindowFlag(Qt.WindowType.WindowMaximizeButtonHint, True)

        root = QVBoxLayout(self)
        root.setContentsMargins(16, 16, 16, 12)
        root.setSpacing(12)

        root.addLayout(self._build_header())
        root.addLayout(self._build_form())
        root.addWidget(self._build_feed_health_panel())
        root.addWidget(self._build_advanced_group())
        root.addWidget(self._build_episode_toolbar())
        root.addWidget(self._build_episode_search_bar())
        root.addWidget(self._build_episodes_table(), 1)
        root.addLayout(self._build_footer())

        # Kick off the paced back-catalogue stream now that the table exists
        # (no-op for non-YouTube shows or when yt-dlp isn't installed).
        self._start_history_stream()

    def _resize_to_parent(self) -> None:
        """Size the dialog to 80%×80% of the main window so the episode list has
        room; clamp to the minimum and fall back to a fixed size if unparented."""
        par = self.parent()
        win = par.window() if par is not None else None
        if win is not None and win.width() > 100 and win.height() > 100:
            self.resize(max(620, int(win.width() * 0.8)), max(560, int(win.height() * 0.8)))
        else:
            self.resize(660, 640)

    # ── header ───────────────────────────────────────────────

    def _build_header(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(12)

        art = QLabel()
        art.setFixedSize(64, 64)
        art.setFrameShape(QFrame.Shape.StyledPanel)
        _t = current_tokens()
        art.setStyleSheet(
            f"QLabel {{ background: {_t['surface_alt']};"
            f" border: 1px solid {_t['line']}; border-radius: 6px; }}"
        )
        art.setAlignment(Qt.AlignmentFlag.AlignCenter)
        # Placeholder glyph — stays on screen until (and unless) the
        # async artwork fetch resolves with a real pixmap. Keeps the
        # dialog render cleanly when the feed exposes no cover art.
        art.setText("🎙")
        art.setObjectName("ShowArtwork")
        self._artwork_label = art
        row.addWidget(art, 0, Qt.AlignmentFlag.AlignTop)

        # Kick off artwork load off-thread so dialog open isn't blocked
        # on a CDN round-trip. Cache hits still read from disk inside
        # ensure_artwork, but we always hop to a QThread for uniformity.
        self._maybe_load_artwork(getattr(self.show_, "artwork_url", "") or "")

        text_col = QVBoxLayout()
        text_col.setSpacing(2)

        title = QLabel(self.show_.title or self.show_.slug)
        f = QFont()
        f.setPointSize(15)
        f.setBold(True)
        title.setFont(f)
        title.setWordWrap(True)
        text_col.addWidget(title)

        s = compute_show_stats(self.ctx.state, self.slug)
        meta_text = f"{self.show_.slug} · {s.total} eps · {s.done} done · {s.pending} pending"
        meta = QLabel(meta_text)
        meta.setProperty("class", "muted")
        meta.setStyleSheet(f"color: {_t['ink_3']}; font-size: 11px;")
        text_col.addWidget(meta)

        feed = QLabel(self.show_.rss)
        feed.setStyleSheet(f"color: {_t['ink_3']}; font-family: Menlo, monospace; font-size: 11px;")
        feed.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        text_col.addWidget(feed)
        text_col.addStretch(1)

        row.addLayout(text_col, 1)

        # Right-hand "Refresh from feed" button — re-fetches feed metadata
        # (title, publisher, canonical URL) so the user can populate / sync
        # details without editing the row manually.
        self._refresh_btn = QPushButton("Refresh from feed")
        self._refresh_btn.setToolTip("Re-fetch RSS metadata and update fields")
        self._refresh_btn.clicked.connect(self._refresh_from_feed)
        row.addWidget(self._refresh_btn, 0, Qt.AlignmentFlag.AlignTop)
        return row

    def _maybe_load_artwork(self, url: str) -> None:
        """Start an async fetch of the cover art at ``url``.

        No-op when ``url`` is empty (leaves the 🎙 placeholder). Guards
        against starting a second fetch while one is already running —
        Refresh-from-feed can call this repeatedly.
        """
        if not url:
            return
        existing = getattr(self, "_artwork_thread", None)
        if existing is not None and existing.isRunning():
            return
        thread = _ArtworkFetchThread(self.slug, url, parent=self)
        thread.ready.connect(self._on_artwork_ready)
        thread.missing.connect(self._on_artwork_missing)
        thread.finished.connect(thread.deleteLater)
        thread.finished.connect(lambda: setattr(self, "_artwork_thread", None))
        self._artwork_thread = thread
        thread.start()

    def _on_artwork_ready(self, path) -> None:
        lbl = getattr(self, "_artwork_label", None)
        if lbl is None:
            return
        pm = QPixmap(str(path))
        if pm.isNull():
            # File exists but isn't decodable — leave placeholder.
            return
        lbl.setText("")
        lbl.setPixmap(_rounded_pixmap(pm, 64, 6))

    def _on_artwork_missing(self) -> None:
        # Network or cache miss — placeholder is already rendered, nothing to do.
        return

    def _invalidate_artwork_cache(self) -> None:
        """Delete any cached artwork file for this slug so a fresh URL
        triggers a re-fetch on the next ``ensure_artwork`` call."""
        from core.artwork import artwork_dir

        d = artwork_dir()
        for ext in (".jpg", ".png", ".webp", ".gif", ".img"):
            p = d / f"{self.slug}{ext}"
            if p.exists():
                try:
                    p.unlink()
                except OSError:
                    pass

    def _refresh_from_feed(self) -> None:
        """Pull channel metadata off-thread and update editable fields.

        `feed_metadata` can block up to 15 s on slow CDNs, which would freeze
        the dialog if run on the UI thread. We spin up a short-lived
        `_FeedMetadataThread` and apply the result (or surface the error) in
        slots that run back on the UI thread.
        """
        # Guard against double-click while a previous refresh is still
        # in-flight.
        existing = getattr(self, "_metadata_thread", None)
        if existing is not None and existing.isRunning():
            return

        self._refresh_btn.setEnabled(False)
        self._refresh_btn.setText("Fetching…")

        thread = _FeedMetadataThread(self.rss_edit.text().strip(), timeout=15.0, parent=self)
        thread.ok.connect(self._on_refresh_ok)
        thread.err.connect(self._on_refresh_err)
        # Drop the reference once the thread is finished so we can start a new
        # one on the next click.
        thread.finished.connect(thread.deleteLater)
        thread.finished.connect(lambda: setattr(self, "_metadata_thread", None))
        self._metadata_thread = thread
        thread.start()

    def _on_refresh_ok(self, meta: dict) -> None:
        # Apply — only overwrite fields the feed actually supplied.
        title_changed = False
        if meta.get("title") and meta["title"] != self._title_edit.text():
            self._title_edit.setText(meta["title"])
            self.show_.title = meta["title"]
            title_changed = True
        canonical = meta.get("canonical_url")
        if canonical and canonical != self.rss_edit.text().strip():
            self.rss_edit.setText(canonical)
            self.show_.rss = canonical
        # Artwork: persist on the Show so a subsequent dialog open (or
        # watchlist save via _save) doesn't lose it. We also trigger an
        # async (re)load so the header updates in-place without the user
        # having to reopen the dialog.
        artwork_url = meta.get("artwork_url") or ""
        new_art = artwork_url and artwork_url != getattr(self.show_, "artwork_url", "")
        if artwork_url:
            self.show_.artwork_url = artwork_url
            if new_art:
                # URL changed — drop the cached file so ensure_artwork
                # fetches fresh bytes instead of returning the stale one.
                self._invalidate_artwork_cache()
            self._maybe_load_artwork(artwork_url)
        # Persist the updated Show to the watchlist so the Shows-tab row
        # reflects the new title/rss/artwork without the user having to
        # hit Save first. Best-effort — if ctx.data_dir isn't present we
        # fall through and the user can still click Save manually.
        try:
            save_watchlist(self.ctx)
            parent = self.parent()
            while parent is not None:
                shows_tab = getattr(parent, "shows_tab", None)
                if shows_tab is not None:
                    shows_tab.refresh()
                    break
                parent = parent.parent()
        except Exception:
            pass
        # Advanced group is collapsed by default; if the refresh wrote a new
        # title there, pop the group open so the user sees what changed
        # before hitting Save.
        if title_changed and hasattr(self, "_advanced_box"):
            self._advanced_box.setChecked(True)
        self._refresh_btn.setEnabled(True)
        self._refresh_btn.setText("✓ Refreshed")
        QTimer.singleShot(1400, self._reset_refresh_btn_label)

    def _on_refresh_err(self, message: str) -> None:
        QMessageBox.warning(
            self,
            "Refresh failed",
            f"Could not fetch feed metadata:\n{message}",
        )
        self._refresh_btn.setEnabled(True)
        self._refresh_btn.setText("Refresh from feed")

    def _reset_refresh_btn_label(self) -> None:
        # Guarded: dialog may have been closed before the QTimer fires.
        if self._refresh_btn is not None:
            self._refresh_btn.setText("Refresh from feed")

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt override
        """Ensure any in-flight metadata fetch is reaped before the dialog dies."""
        # Cancel the paced back-catalogue stream first: stop the timer + reap
        # the enumeration thread so nothing touches a tearing-down widget.
        self._cancel_history_stream()
        thread = getattr(self, "_metadata_thread", None)
        if thread is not None and thread.isRunning():
            # Disconnect slots so the thread's result can't touch a widget
            # that's being torn down.
            try:
                thread.ok.disconnect()
                thread.err.disconnect()
            except (TypeError, RuntimeError):
                pass
            thread.quit()
            thread.wait(2000)
        art_thread = getattr(self, "_artwork_thread", None)
        if art_thread is not None and art_thread.isRunning():
            try:
                art_thread.ready.disconnect()
                art_thread.missing.disconnect()
            except (TypeError, RuntimeError):
                pass
            # Artwork fetch is a single blocking httpx GET — give it up to
            # 3 s to unwind so we don't hang on dialog close.
            art_thread.quit()
            art_thread.wait(3000)
        super().closeEvent(event)

    # ── form grid ────────────────────────────────────────────

    def _build_form(self) -> QGridLayout:
        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(6)
        grid.setColumnMinimumWidth(0, 120)
        grid.setColumnStretch(0, 0)
        grid.setColumnStretch(1, 1)

        r = 0

        grid.addWidget(self._label("Slug"), r, 0)
        self.slug_edit = QLineEdit(self.show_.slug)
        self.slug_edit.setReadOnly(True)
        self.slug_edit.setEnabled(False)
        grid.addWidget(self.slug_edit, r, 1)
        r += 1

        grid.addWidget(self._label("Feed URL"), r, 0)
        self.rss_edit = QLineEdit(self.show_.rss)
        grid.addWidget(self.rss_edit, r, 1)
        r += 1

        grid.addWidget(self._label("Enabled"), r, 0)
        self.enabled_toggle = QCheckBox()
        self.enabled_toggle.setChecked(bool(self.show_.enabled))
        grid.addWidget(self.enabled_toggle, r, 1)
        r += 1

        grid.addWidget(self._label("Last checked"), r, 0)
        last_checked = self._fmt_last_checked()
        self.last_checked_lbl = QLabel(last_checked)
        _t = current_tokens()
        self.last_checked_lbl.setStyleSheet(f"color: {_t['ink_3']};")
        grid.addWidget(self.last_checked_lbl, r, 1)
        r += 1

        grid.addWidget(self._label("Backlog"), r, 0)
        self.backlog_lbl = QLabel(self._fmt_backlog())
        self.backlog_lbl.setStyleSheet(f"color: {_t['ink_3']};")
        grid.addWidget(self.backlog_lbl, r, 1)
        r += 1

        grid.addWidget(self._label("Output subdir"), r, 0)
        self.output_edit = QLineEdit(self.show_.output_override or "")
        self.output_edit.setPlaceholderText(f"(default: {self.show_.slug})")
        grid.addWidget(self.output_edit, r, 1)
        r += 1

        return grid

    def _label(self, text: str) -> QLabel:
        lbl = QLabel(text)
        # Let the themed QSS pick the color — inline palette(mid) rendered
        # white-on-white in dark mode because Qt's palette role doesn't
        # track our custom ThemeManager. Font size stays 12 px.
        lbl.setStyleSheet("font-size: 12px;")
        lbl.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        return lbl

    def _fmt_last_checked(self) -> str:
        try:
            v = self.ctx.state.get_meta("last_successful_check")
        except Exception:
            v = None
        return v if v else "—"

    def _fmt_backlog(self) -> str:
        try:
            with self.ctx.state._conn() as c:
                row = c.execute(
                    "SELECT "
                    "SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) AS pending, "
                    "SUM(CASE WHEN status='failed'  THEN 1 ELSE 0 END) AS failed  "
                    "FROM episodes WHERE show_slug=?",
                    (self.slug,),
                ).fetchone()
            p = row["pending"] or 0
            fa = row["failed"] or 0
            return f"{p} pending · {fa} failed"
        except Exception:
            return "—"

    # ── feed health ──────────────────────────────────────────

    def _build_feed_health_panel(self) -> QWidget:
        """Compact 'Feed health' panel: pill + categorised last error +
        backoff state + per-category recommendation + Retry-now button.
        Hidden when feed_health is 'ok' or 'unknown' so a healthy show
        doesn't carry a permanent 'all is well' badge."""
        from core.feed_errors import label as _label
        from core.feed_errors import recommendation as _rec

        state = self.ctx.state
        slug = self.slug
        health = state.get_meta(f"feed_health:{slug}") or "unknown"
        cat = state.get_meta(f"feed_fail_category:{slug}") or ""
        msg = state.get_meta(f"feed_fail_message:{slug}") or ""
        at = state.get_meta(f"feed_fail_at:{slug}") or ""
        backoff_until = state.get_meta(f"feed_backoff_until:{slug}") or ""
        fail_count = int(state.get_meta(f"feed_fail_count:{slug}") or 0)

        container = QWidget()
        self._feed_health_container = container
        if health != "fail":
            container.setVisible(False)
            return container

        _t = current_tokens()
        container.setStyleSheet(
            f"QWidget#feedHealthPanel {{ background: {_t['surface_alt']}; "
            f"border: 1px solid {_t['line']}; border-radius: 6px; }}"
        )
        container.setObjectName("feedHealthPanel")

        v = QVBoxLayout(container)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(6)

        title_row = QHBoxLayout()
        title_lbl = QLabel("Feed health")
        f = QFont()
        f.setBold(True)
        title_lbl.setFont(f)
        title_row.addWidget(title_lbl)
        pill_text = f"fail · {_label(cat)}" if cat else "fail"
        pill = Pill(pill_text, kind="fail")
        title_row.addWidget(pill)
        title_row.addStretch()
        retry_btn = QPushButton("Retry now")
        retry_btn.setToolTip("Clear backoff state and immediately re-fetch this feed.")
        retry_btn.clicked.connect(self._retry_feed_now)
        title_row.addWidget(retry_btn)
        v.addLayout(title_row)

        # Detail lines
        if at:
            lbl = QLabel(f"<b>When:</b> {at}")
            lbl.setStyleSheet("font-size: 12px;")
            v.addWidget(lbl)
        if msg:
            lbl = QLabel(f"<b>Message:</b> {msg[:300]}")
            lbl.setStyleSheet("font-size: 12px;")
            lbl.setWordWrap(True)
            v.addWidget(lbl)
        if fail_count and backoff_until:
            lbl = QLabel(
                f"<b>Backoff:</b> {fail_count} consecutive fails — parked until {backoff_until}"
            )
            lbl.setStyleSheet("font-size: 12px;")
            v.addWidget(lbl)
        if cat:
            tip = QLabel(f"<b>Suggested fix:</b> {_rec(cat)}")
            tip.setStyleSheet(f"color: {_t['ink_3']}; font-size: 12px;")
            tip.setWordWrap(True)
            v.addWidget(tip)
        return container

    def _retry_feed_now(self) -> None:
        """Clear backoff for this show + re-fetch synchronously. Updates
        the panel in place (rebuilds via show_dialog refresh would be
        overkill)."""
        from datetime import datetime as _dt
        from datetime import timezone as _tz

        from core.feed_errors import categorize
        from core.rss import build_manifest

        state = self.ctx.state
        for k in (
            "feed_fail_count",
            "feed_backoff_until",
            "feed_fail_category",
            "feed_fail_message",
            "feed_fail_at",
        ):
            state.set_meta(f"{k}:{self.slug}", "0" if k.endswith("count") else "")
        try:
            build_manifest(self.show_.rss, timeout=30)
        except Exception as e:  # noqa: BLE001
            state.set_meta(f"feed_health:{self.slug}", "fail")
            state.set_meta(f"feed_fail_category:{self.slug}", categorize(e))
            state.set_meta(f"feed_fail_message:{self.slug}", str(e)[:500])
            state.set_meta(f"feed_fail_at:{self.slug}", _dt.now(_tz.utc).isoformat())
            QMessageBox.warning(
                self,
                "Retry failed",
                f"Feed fetch failed:\n\n{e}",
            )
            return
        state.set_meta(f"feed_health:{self.slug}", "ok")
        QMessageBox.information(self, "Retry succeeded", "Feed fetch succeeded — backoff cleared.")
        # Rebuild the panel so the user sees the cleared state immediately.
        # ORDER MATTERS: capture the old container BEFORE calling
        # _build_feed_health_panel, because that builder reassigns
        # self._feed_health_container to a freshly-created widget. If we
        # captured `old` after the build, `old` would alias the new
        # un-parented widget; old.parentWidget() would be None and
        # .layout() would raise AttributeError → PyQt6 qFatal → SIGABRT
        # (the 2026-04-23 crash).
        old = self._feed_health_container
        parent = old.parentWidget() if old is not None else None
        if parent is None:
            return  # nothing to swap into; defensive, shouldn't happen
        parent_layout = parent.layout()
        new_panel = self._build_feed_health_panel()
        idx = parent_layout.indexOf(old)
        parent_layout.removeWidget(old)
        old.deleteLater()
        parent_layout.insertWidget(idx, new_panel)

    # ── advanced (collapsed by default) ──────────────────────

    def _build_advanced_group(self) -> QWidget:
        """Advanced section: header row (label + Switch) over a collapsible
        body. Replaces the previous checkable QGroupBox so the toggle
        reads as a modern on/off switch instead of a square checkbox."""
        from ui.widgets import Switch

        container = QWidget()
        vbox = QVBoxLayout(container)
        vbox.setContentsMargins(0, 4, 0, 0)
        vbox.setSpacing(6)

        # Header
        header = QHBoxLayout()
        header.setContentsMargins(0, 0, 0, 0)
        title_lbl = QLabel("Advanced — tuning")
        f = QFont()
        f.setBold(True)
        title_lbl.setFont(f)
        header.addWidget(title_lbl)
        header.addStretch(1)
        self._advanced_switch = Switch()
        # Alias kept for _refresh_from_feed which called setChecked(True).
        self._advanced_box = self._advanced_switch
        header.addWidget(self._advanced_switch)
        vbox.addLayout(header)

        # Body — hosts the grid with the advanced fields.
        body = QWidget()
        vbox.addWidget(body)

        inner = QGridLayout(body)
        inner.setHorizontalSpacing(10)
        inner.setVerticalSpacing(6)
        inner.setContentsMargins(0, 0, 0, 0)
        inner.setColumnMinimumWidth(0, 120)
        inner.setColumnStretch(0, 0)
        inner.setColumnStretch(1, 1)

        r = 0
        inner.addWidget(self._label("Title"), r, 0)
        self._title_edit = QLineEdit(self.show_.title or "")
        inner.addWidget(self._title_edit, r, 1)
        r += 1

        inner.addWidget(self._label("Language"), r, 0)
        self._language_combo = QComboBox()
        for label, code in _LANGUAGES:
            self._language_combo.addItem(f"{label} ({code})", code)
        current = getattr(self.show_, "language", "de") or "de"
        idx = next((i for i, (_, c) in enumerate(_LANGUAGES) if c == current), 0)
        self._language_combo.setCurrentIndex(idx)
        inner.addWidget(self._language_combo, r, 1)
        r += 1

        # Whisper-prompt edit occupies its own row; the hint sits as a
        # standalone row below it in column 1 only. This avoids the
        # sub-VBox variant whose wrapping widget underreported its
        # height to the grid and let the hint draw on top of the edit.
        inner.addWidget(self._label("Whisper prompt"), r, 0, Qt.AlignmentFlag.AlignTop)
        self._whisper_prompt_edit = QPlainTextEdit(self.show_.whisper_prompt or "")
        self._whisper_prompt_edit.setFixedHeight(80)
        inner.addWidget(self._whisper_prompt_edit, r, 1)
        r += 1

        hint = QLabel("Comma-separated hints (names, jargon, places). Improves recognition.")
        hint.setStyleSheet(f"color: {current_tokens()['ink_3']}; font-size: 11px;")
        hint.setWordWrap(True)
        inner.addWidget(hint, r, 1)
        r += 1

        # YouTube-only: transcript-source preference (per-channel override of
        # the Settings default). Tuple form lets us decouple display labels
        # from the persisted internal value.
        self.transcript_pref_combo: QComboBox | None = None
        self._skip_shorts_toggle: QCheckBox | None = None
        if getattr(self.show_, "source", "podcast") == "youtube":
            inner.addWidget(self._label("Transcript source"), r, 0)
            combo = QComboBox()
            combo.setObjectName("transcript_pref_combo")
            options = [
                ("Captions first, whisper fallback", "captions"),
                ("Always whisper", "whisper"),
            ]
            for label, value in options:
                combo.addItem(label, value)
            initial = getattr(self.show_, "youtube_transcript_pref", "") or "captions"
            for i, (_, v) in enumerate(options):
                if v == initial:
                    combo.setCurrentIndex(i)
                    break
            inner.addWidget(combo, r, 1)
            self.transcript_pref_combo = combo
            r += 1

            # YouTube-only: exclude Shorts from backfill and as a per-video
            # safety net. Defaults from the show (model default is True).
            inner.addWidget(self._label("Skip Shorts"), r, 0)
            self._skip_shorts_toggle = QCheckBox()
            self._skip_shorts_toggle.setChecked(bool(getattr(self.show_, "skip_shorts", True)))
            inner.addWidget(self._skip_shorts_toggle, r, 1)
            r += 1

            shorts_hint = QLabel("Excludes Shorts on backfill and as a per-video safety net.")
            shorts_hint.setStyleSheet(f"color: {current_tokens()['ink_3']}; font-size: 11px;")
            shorts_hint.setWordWrap(True)
            inner.addWidget(shorts_hint, r, 1)
            r += 1

        # Toggle: switch controls body visibility + grows/shrinks the
        # dialog so the expanded body doesn't overflow into the
        # episodes table below.
        def _toggle(expanded: bool):
            body.setVisible(expanded)
            cur = self.size()
            target_h = 760 if expanded else 560
            if cur.height() != target_h:
                self.resize(cur.width(), target_h)

        self._advanced_switch.toggled.connect(_toggle)
        _toggle(False)
        return container

    # ── episode toolbar ──────────────────────────────────────

    def _build_episode_toolbar(self) -> QWidget:
        """Compact controls row that sits directly above the episode table:
        a status filter (left), then the date-sweep + selection bulk-queue
        actions (right)."""
        bar = QWidget()
        row = QHBoxLayout(bar)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(8)

        # Status filter (left): narrows the table to a single status. The
        # combo is wired AFTER its items are added so populating it doesn't
        # fire the slot before the episodes table exists.
        row.addWidget(QLabel("Filter:"))
        self._status_filter_combo = QComboBox()
        self._status_filter_combo.addItems(
            ["All", "pending", "failed", "skipped", "deferred", "paused", "done"]
        )
        self._status_filter_combo.currentTextChanged.connect(self._on_status_filter_changed)
        row.addWidget(self._status_filter_combo)

        row.addStretch(1)

        # Date-sweep: queue every not-yet-done episode published on or after
        # the chosen date. Default the picker to ~1 year ago so the common
        # "catch up the last year" sweep is one click away.
        self._since_date_edit = QDateEdit()
        self._since_date_edit.setCalendarPopup(True)
        self._since_date_edit.setDisplayFormat("yyyy-MM-dd")
        self._since_date_edit.setDate(QDate.currentDate().addYears(-1))
        row.addWidget(self._since_date_edit)

        queue_since_btn = QPushButton("Queue all since")
        queue_since_btn.setToolTip(
            "Queue every not-yet-done episode published on or after the chosen date."
        )
        queue_since_btn.clicked.connect(self._queue_since)
        row.addWidget(queue_since_btn)

        queue_sel_btn = QPushButton("Queue selected")
        queue_sel_btn.setToolTip("Queue every selected episode for transcription.")
        queue_sel_btn.clicked.connect(self._queue_selected)
        row.addWidget(queue_sel_btn)

        # "Load more" — hidden until the paced history stream hits its
        # per-session cap with more back-catalogue still to show. Clicking it
        # resumes appending the next cap-sized window.
        self._load_more_btn = QPushButton("Load more")
        self._load_more_btn.setToolTip(
            "Append more back-catalogue videos discovered on the channel."
        )
        self._load_more_btn.clicked.connect(self._load_more)
        self._load_more_btn.hide()
        row.addWidget(self._load_more_btn)

        return bar

    def _build_episode_search_bar(self) -> QWidget:
        """A dedicated, full-width search row directly above the episode table —
        kept off the crowded toolbar so it's always visible and usable."""
        bar = QWidget()
        row = QHBoxLayout(bar)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(8)
        row.addWidget(QLabel("Search:"))
        # Free-text search over episode titles. Typing pulls in the full
        # back-catalogue (flushes the paced buffer) so a match is never hidden
        # behind the cap / "Load more", then hides the non-matching rows.
        self._ep_search = QLineEdit()
        self._ep_search.setPlaceholderText("Filter episodes by title…")
        self._ep_search.setClearButtonEnabled(True)
        self._ep_search.textChanged.connect(self._on_episode_search)
        row.addWidget(self._ep_search, 1)
        # Shown while the full back-catalogue is being enumerated off-thread, so
        # the user knows more episodes than the DB-seeded ones are on the way.
        self._history_status = QLabel("")
        # Orange so the "still loading more episodes" hint actually stands out
        # next to the search field (the muted grey was barely legible).
        self._history_status.setStyleSheet("color: #f5a623; font-weight: 600; padding-left: 6px;")
        self._history_status.hide()
        row.addWidget(self._history_status)
        return bar

    # ── recent episodes ──────────────────────────────────────

    def _build_episodes_table(self) -> QTableWidget:
        tbl = QTableWidget(0, 3)
        tbl.setHorizontalHeaderLabels(["Date", "Title", "Status"])
        tbl.verticalHeader().setVisible(False)
        # Row multi-select: bulk actions (next task) operate on every
        # selected episode. ExtendedSelection enables shift/ctrl ranges;
        # SelectRows keeps the whole row highlighted, not single cells.
        tbl.setSelectionMode(QTableWidget.SelectionMode.ExtendedSelection)
        tbl.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        tbl.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        tbl.setShowGrid(False)
        # Allow click/keyboard selection (the old NoFocus blocked it) while
        # keeping the table out of the tab-order via ClickFocus.
        tbl.setFocusPolicy(Qt.FocusPolicy.ClickFocus)

        hh = tbl.horizontalHeader()
        hh.setSectionResizeMode(0, QHeaderView.ResizeMode.Fixed)
        hh.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        hh.setSectionResizeMode(2, QHeaderView.ResizeMode.Fixed)
        tbl.setColumnWidth(0, 90)
        # Wide enough for the longest status pill ("transcribing"/"downloading")
        # incl. its padding — the old 90 px clipped "downloading" to "downloadin".
        tbl.setColumnWidth(2, 130)

        # Size so several rows are visible within the dialog.
        tbl.setMinimumHeight(140)
        tbl.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)

        # Right-click on a row → "Re-transcribe this episode".
        self._episodes_tbl = tbl
        tbl.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        tbl.customContextMenuRequested.connect(self._on_episode_context_menu)

        # Populate rows from the DB. Kept separate so later actions can
        # refresh the table in place via _reload_episodes().
        self._reload_episodes()
        return tbl

    def _on_status_filter_changed(self, text: str) -> None:
        """Toolbar combo slot: ``"All"`` clears the filter, any other value
        restricts the table to that status. Rebuilds the table in place and
        keeps the back-catalogue stream filter-aware: a filter pauses paced
        appending; clearing it resumes appending whatever is still buffered."""
        self._status_filter = None if text == "All" else text
        self._reload_episodes()
        if self._history_cancelled:
            return
        if self._status_filter is None:
            if self._available_buffer:
                # Filter cleared with entries still pending → resume pacing.
                # Reset the per-session cap counter so rows that were already
                # visible (and got parked back into the buffer when the filter
                # was applied) re-materialize immediately instead of hiding
                # behind "Load more" at the >cap boundary.
                self._history_session_count = 0
                self._ensure_history_timer().start(_HISTORY_TICK_MS)
                self._append_next_batch()
        else:
            self._stop_history_timer()

    def _episode_rows(self) -> list:
        """Episodes for this show, newest first.

        No LIMIT — the table is a full per-show browser, so every episode
        renders (the previous last-10 cap is gone). When ``_status_filter``
        is set, only episodes with that status are returned (parameterised,
        so no injection); the ``pub_date DESC`` order is preserved either way.
        """
        sql = "SELECT guid, pub_date, title, status FROM episodes WHERE show_slug=?"
        params: list = [self.slug]
        if self._status_filter:
            sql += " AND status = ?"
            params.append(self._status_filter)
        sql += " ORDER BY pub_date DESC"
        with self.ctx.state._conn() as c:
            return c.execute(sql, tuple(params)).fetchall()

    def _reload_episodes(self) -> None:
        """Re-query episodes and rebuild the table body in place.

        Rebuilds every Date/Title/Status-pill row from ``_episode_rows()``.
        The Date cell stashes the guid at ``UserRole`` and the status at
        ``UserRole + 1`` so the context menu (and bulk-select helpers) can
        resolve per-row identity without re-hitting the DB.

        A full rebuild would otherwise drop the synthetic ``available``
        back-catalogue rows the history stream appended, so we harvest the
        currently-shown available rows first. When no status filter is active
        we re-append the ones that haven't since been seeded; when a filter IS
        active we instead push them back onto the FRONT of the buffer (deduped)
        so clearing the filter re-materializes them in their original order.
        """
        tbl = self._episodes_tbl
        # Harvest the available rows already on screen so the rebuild can
        # restore them; their full manifest entry is stashed at UserRole + 2.
        shown_available = []
        for i in range(tbl.rowCount()):
            item = tbl.item(i, 0)
            if item is None:
                continue
            if (item.data(Qt.ItemDataRole.UserRole + 1) or "") == "available":
                entry = item.data(Qt.ItemDataRole.UserRole + 2)
                if entry:
                    shown_available.append(entry)
                    self._available_entries[entry["guid"]] = entry

        rows = self._episode_rows()
        tbl.clearContents()
        tbl.setRowCount(len(rows))
        for i, r in enumerate(rows):
            date_item = QTableWidgetItem((r["pub_date"] or "")[:10])
            date_item.setFont(QFont("Menlo"))
            # Stash guid + status on the date cell — retrievable from the
            # context menu to gate priority-bump actions.
            date_item.setData(Qt.ItemDataRole.UserRole, r["guid"])
            date_item.setData(Qt.ItemDataRole.UserRole + 1, r["status"] or "")
            tbl.setItem(i, 0, date_item)
            tbl.setItem(i, 1, QTableWidgetItem(r["title"] or ""))
            status = (r["status"] or "").lower()
            kind = _STATUS_PILL_KIND.get(status, "idle")
            pill = Pill(status or "—", kind=kind)
            # Wrap pill in container so table cell padding looks right.
            holder = QWidget()
            lay = QHBoxLayout(holder)
            lay.setContentsMargins(4, 2, 4, 2)
            lay.addWidget(pill)
            lay.addStretch(1)
            tbl.setCellWidget(i, 2, holder)

        if shown_available:
            seeded = self._seeded_guids()
            # Drop any harvested entry that has since become a real DB row so
            # the registry never points a seeded guid back at a synthetic one.
            for g in seeded:
                self._available_entries.pop(g, None)
            if self._status_filter is None:
                # Unfiltered: re-append the still-unseeded available rows.
                for entry in shown_available:
                    if entry.get("guid") not in seeded:
                        self._append_available_row(entry)
            else:
                # Filtered: a filter hides synthetic rows, so park the still-
                # unseeded entries back at the FRONT of the buffer (deduped by
                # guid, original order) so clearing the filter restores them.
                buffered = {m["guid"] for m in self._available_buffer}
                restored = [
                    e
                    for e in shown_available
                    if e.get("guid") not in seeded and e.get("guid") not in buffered
                ]
                if restored:
                    self._available_buffer = restored + self._available_buffer
        # Re-apply any active title search to the freshly rebuilt rows.
        self._reapply_search()

    # ── title search ─────────────────────────────────────────

    def _on_episode_search(self, text: str) -> None:
        q = text.strip().lower()
        # Make search comprehensive: pull every remaining back-catalogue row in
        # so a match isn't hidden behind the paced cap / "Load more".
        if q and self._available_buffer and self._status_filter is None:
            self._flush_available_buffer()
        self._apply_episode_search(q)

    def _flush_available_buffer(self) -> None:
        """Append ALL remaining buffered back-catalogue rows at once so every
        known episode is present to search against."""
        if self._status_filter is not None:
            return
        while self._available_buffer:
            self._append_available_row(self._available_buffer.pop(0))
        self._stop_history_timer()
        self._set_load_more_visible(False)

    def _apply_episode_search(self, query: str) -> None:
        """Hide rows whose title doesn't contain ``query`` (already lower-cased);
        an empty query un-hides everything."""
        tbl = self._episodes_tbl
        for i in range(tbl.rowCount()):
            if not query:
                tbl.setRowHidden(i, False)
                continue
            item = tbl.item(i, 1)
            title = (item.text() if item is not None else "").lower()
            tbl.setRowHidden(i, query not in title)

    def _reapply_search(self) -> None:
        """Re-apply the active title search after the table body was rebuilt."""
        edit = getattr(self, "_ep_search", None)
        if edit is not None and edit.text().strip():
            self._apply_episode_search(edit.text().strip().lower())

    def _selected_guids(self) -> list[str]:
        """Guids of every selected row, in row order.

        Bulk actions read each selected row's Date cell ``UserRole`` (where
        the per-row guid is stashed). Uses ``selectionModel().selectedRows()``
        so each row is counted once regardless of how many cells it spans.
        """
        tbl = self._episodes_tbl
        model = tbl.selectionModel()
        if model is None:
            return []
        guids: list[str] = []
        for index in sorted(model.selectedRows(), key=lambda i: i.row()):
            item = tbl.item(index.row(), 0)
            if item is None:
                continue
            guid = item.data(Qt.ItemDataRole.UserRole)
            if guid:
                guids.append(guid)
        return guids

    def _on_episode_context_menu(self, pos) -> None:
        tbl = self._episodes_tbl
        index = tbl.indexAt(pos)
        if not index.isValid():
            return
        date_item = tbl.item(index.row(), 0)
        if date_item is None:
            return
        guid = date_item.data(Qt.ItemDataRole.UserRole)
        if not guid:
            return
        status = date_item.data(Qt.ItemDataRole.UserRole + 1) or ""
        # Synthetic back-catalogue row: the only meaningful action is to seed
        # + queue this single video. Not a real DB row yet, so none of the
        # re-transcribe / bump / diff actions apply.
        if status == "available":
            menu = QMenu(self)
            menu.addAction(
                "Queue this video",
                lambda g=guid: self._trigger_available(g),
            )
            menu.exec(tbl.viewport().mapToGlobal(pos))
            return
        menu = QMenu(self)
        menu.addAction(
            "Re-transcribe this episode",
            lambda g=guid: self._retranscribe(g),
        )
        if can_bump(status):
            menu.addSeparator()
            menu.addAction(
                "Run next",
                lambda g=guid: self._bump(g, PRIORITY_RUN_NEXT),
            )
            menu.addAction(
                "Run now",
                lambda g=guid: self._bump(g, PRIORITY_RUN_NOW),
            )
        md_path = self._md_path_for(guid)
        if md_path is not None:
            bak = md_path.with_suffix(".md.bak")
            if bak.exists() and md_path.exists():
                menu.addAction(
                    "View diff",
                    lambda b=bak, cur=md_path: self._open_diff(b, cur),
                )
        menu.exec(tbl.viewport().mapToGlobal(pos))

    def _md_path_for(self, guid: str) -> Path | None:
        """Mirror `ui.retranscribe` path derivation so diff sees the same file."""
        from core.pipeline import build_slug

        ep = self.ctx.state.get_episode(guid)
        if ep is None:
            return None
        try:
            output_root = Path(self.ctx.settings.output_root).expanduser()
        except Exception:
            return None
        slug = build_slug(ep.get("pub_date") or "", ep.get("title") or "", "0000")
        return output_root / ep["show_slug"] / f"{slug}.md"

    def _open_diff(self, old: Path, new: Path) -> None:
        from ui.transcript_diff_dialog import TranscriptDiffDialog

        TranscriptDiffDialog(old, new, parent=self).exec()

    def _retranscribe(self, guid: str) -> None:
        retranscribe_episode(self.ctx, guid)
        # Kick the worker + force-refresh the Queue so the re-transcribed
        # episode immediately jumps to the top of the visible queue.
        self._nudge_worker()
        # Refresh backlog label so the user sees the bump take effect.
        self.backlog_lbl.setText(self._fmt_backlog())

    def _nudge_worker(self) -> None:
        """Kick the background worker + force-refresh the Queue tab so a
        priority change takes effect immediately instead of sitting idle
        until the next scheduled check (could be hours away).

        Shared by `_bump` (single episode) and `_queue_guids` (bulk). Every
        step is best-effort and guarded — in tests the dialog has no parent,
        so this short-circuits to a no-op.
        """
        shows_tab = self.parent()
        if shows_tab is None or not hasattr(shows_tab, "start_check"):
            return
        try:
            shows_tab.start_check(only_slug=self.slug, force=True)
        except Exception:
            pass
        # Force-refresh the Queue tab table NOW (instead of waiting for its
        # 3 s tick) so the user sees the bumped row jump to the top
        # immediately. Reach the queue tab via the main window —
        # shows_tab.parent() is the main window, which has `queue_tab`.
        try:
            main_win = shows_tab.window()
            queue_tab = getattr(main_win, "queue_tab", None)
            if queue_tab is not None and hasattr(queue_tab, "refresh"):
                queue_tab._last_table_refresh = 0.0
                queue_tab.refresh()
        except Exception:
            pass

    def _queue_guids(self, guids: list[str]) -> None:
        """Bulk-queue ``guids``: set each PENDING + bump to PRIORITY_RUN_NEXT,
        then nudge the worker once and refresh the table + backlog label.

        Synthetic ``available`` rows have no DB row yet, so ``set_status`` would
        silently hit zero rows. For each guid we first check the DB: if it's
        unseeded but a known available entry, we seed it (upsert) and drop it
        from the buffer/registry; if it's unseeded AND unknown, we skip it.
        Then the normal pending + bump runs against a guaranteed-real row.

        Empty list → no-op (no DB writes, no worker nudge, no refresh).
        """
        if not guids:
            return
        did_queue = False
        for guid in guids:
            if self.ctx.state.get_episode(guid) is None:
                entry = self._available_entries.get(guid)
                if entry is None:
                    # Unseeded and not a known available row — nothing to queue.
                    continue
                self.ctx.state.upsert_episode(
                    show_slug=self.slug,
                    guid=entry["guid"],
                    title=entry["title"],
                    pub_date=entry["pubDate"],
                    mp3_url=entry["mp3_url"],
                )
                self._available_buffer = [m for m in self._available_buffer if m["guid"] != guid]
                self._available_entries.pop(guid, None)
            self.ctx.state.set_status(guid, EpisodeStatus.PENDING)
            bump_priority(self.ctx, guid, PRIORITY_RUN_NEXT)
            did_queue = True
        if not did_queue:
            return
        # Nudge once after the whole batch, not per-guid.
        self._nudge_worker()
        self._reload_episodes()
        self.backlog_lbl.setText(self._fmt_backlog())

    def _queue_selected(self) -> None:
        """Queue every currently-selected episode row."""
        self._queue_guids(self._selected_guids())

    def _queue_since(self) -> None:
        """Queue every not-yet-done episode published on/after the picker date.

        A date sweep must NOT re-queue already-completed episodes, so `done`
        rows are excluded. Runs a dedicated SELECT (independent of the active
        status filter) so the sweep covers the whole back-catalogue, not just
        the currently-visible subset. ISO date strings compare
        lexicographically, so a plain ``>=`` on the ``YYYY-MM-DD`` prefix is a
        correct on/after-cutoff test.
        """
        cutoff = self._since_date_edit.date().toString("yyyy-MM-dd")
        with self.ctx.state._conn() as c:
            rows = c.execute(
                "SELECT guid FROM episodes "
                "WHERE show_slug=? AND substr(pub_date, 1, 10) >= ? "
                "AND status != 'done' "
                "ORDER BY pub_date DESC",
                (self.slug, cutoff),
            ).fetchall()
        self._queue_guids([r["guid"] for r in rows])

    def _bump(self, guid: str, priority: int) -> None:
        bump_priority(self.ctx, guid, priority)
        # Kick the worker so the bump takes effect immediately. Without
        # this, set_priority just updates SQL and the episode sits idle
        # until the next scheduled check.
        self._nudge_worker()
        # The recent-episodes table is ordered by pub_date so a priority
        # bump doesn't visually reorder rows here — but the backlog label
        # (pending/failed counts) is what the user watches on this dialog.
        self.backlog_lbl.setText(self._fmt_backlog())

    # ── paced back-catalogue stream (Task 4.7) ───────────────

    def _start_history_stream(self) -> None:
        """Begin enumerating the channel's full upload history off-thread.

        No-op unless the show is a YouTube source AND yt-dlp is installed. The
        enumeration runs in ``_YoutubeHistoryThread``; its result lands in
        ``_on_history_loaded`` back on the UI thread, which then paces the
        not-yet-seeded videos into the table.
        """
        if getattr(self.show_, "source", "podcast") != "youtube":
            return
        if not ytdlp.is_installed():
            return
        cid = channel_id_from_feed_url(self.show_.rss)
        if not cid:
            return
        # `skip_shorts` True (the model default) → enumerate the /videos tab
        # which excludes Shorts; invert it for enumerate's include_shorts.
        include_shorts = not getattr(self.show_, "skip_shorts", True)
        thread = _YoutubeHistoryThread(cid, include_shorts, parent=self)
        thread.loaded.connect(self._on_history_loaded)
        thread.failed.connect(self._on_history_failed)
        thread.finished.connect(thread.deleteLater)
        # Drop our reference once the C++ object is gone so a later
        # `_cancel_history_stream` can't poke a deleted thread (mirrors the
        # `_metadata_thread`/`_artwork_thread` pattern).
        thread.finished.connect(lambda: setattr(self, "_history_thread", None))
        self._history_thread = thread
        if getattr(self, "_history_status", None) is not None:
            self._history_status.setText("Loading the channel's full episode list…")
            self._history_status.show()
        thread.start()

    def _on_history_failed(self, message: str) -> None:
        """A failed back-catalogue enumeration is non-fatal — the DB-seeded
        rows are already on screen, so we swallow the error silently."""
        if getattr(self, "_history_status", None) is not None:
            self._history_status.hide()
        return

    def _seeded_guids(self) -> set[str]:
        """Every guid already persisted for this show (any status)."""
        with self.ctx.state._conn() as c:
            rows = c.execute("SELECT guid FROM episodes WHERE show_slug=?", (self.slug,)).fetchall()
        return {r["guid"] for r in rows}

    def _on_history_loaded(self, videos: list) -> None:
        """Receive the full flat-playlist list and start paced appending.

        Converts the videos to manifest entries, drops the ones already seeded
        in the DB (those are already real rows), and drips the remainder into
        the table on a timer — appending the first batch immediately so the
        user sees results without waiting a tick.
        """
        # A `loaded` signal can arrive after the dialog began closing (the
        # thread finished its yt-dlp dump just as we cancelled); ignore it.
        if self._history_cancelled:
            return
        if getattr(self, "_history_status", None) is not None:
            self._history_status.hide()
        manifest = manifest_from_videos(videos)
        seeded = self._seeded_guids()
        self._available_buffer = [m for m in manifest if m["guid"] not in seeded]
        self._available_entries = {m["guid"]: m for m in self._available_buffer}
        self._history_session_count = 0
        self._ensure_history_timer().start(_HISTORY_TICK_MS)
        # Show the first batch right away instead of waiting a full tick.
        self._append_next_batch()

    def _ensure_history_timer(self) -> QTimer:
        timer = getattr(self, "_history_timer", None)
        if timer is None:
            timer = QTimer(self)
            timer.timeout.connect(self._append_next_batch)
            self._history_timer = timer
        return timer

    def _stop_history_timer(self) -> None:
        timer = getattr(self, "_history_timer", None)
        if timer is not None:
            timer.stop()

    def _append_next_batch(self) -> None:
        """Append up to ``_HISTORY_BATCH`` available rows from the front of the
        buffer, stopping once the per-session cap is reached.

        Drains the buffer (newest-first as enumerated). When the buffer empties
        the timer stops and the "Load more" button is hidden. When the cap is
        hit with entries still buffered, the timer stops and "Load more" is
        revealed so the user can pull the next window in on demand.

        Synthetic rows must never leak into a filtered view, so this is a no-op
        (without popping the buffer) while a status filter is active — the
        entries stay buffered and re-materialize when the filter is cleared.
        """
        if self._history_cancelled:
            return
        if self._status_filter is not None:
            # Filtered view: don't append synthetic rows, keep the buffer
            # intact, and stop ticking until the filter is cleared.
            self._stop_history_timer()
            return
        if not self._available_buffer:
            self._stop_history_timer()
            self._set_load_more_visible(False)
            return
        appended = 0
        while (
            self._available_buffer
            and appended < _HISTORY_BATCH
            and self._history_session_count < self._history_cap
        ):
            self._append_available_row(self._available_buffer.pop(0))
            appended += 1
            self._history_session_count += 1
        if not self._available_buffer:
            self._stop_history_timer()
            self._set_load_more_visible(False)
        elif self._history_session_count >= self._history_cap:
            self._stop_history_timer()
            self._set_load_more_visible(True)

    def _append_available_row(self, entry: dict) -> None:
        """Append one synthetic ``available`` row for a back-catalogue video.

        The Date cell stashes the guid at ``UserRole``, the ``"available"``
        marker at ``UserRole + 1`` (matching the DB-row convention), and the
        full manifest entry at ``UserRole + 2`` so triggering can seed it.
        """
        tbl = self._episodes_tbl
        i = tbl.rowCount()
        tbl.insertRow(i)
        date_item = QTableWidgetItem((entry.get("pubDate") or "")[:10])
        date_item.setFont(QFont("Menlo"))
        date_item.setData(Qt.ItemDataRole.UserRole, entry["guid"])
        date_item.setData(Qt.ItemDataRole.UserRole + 1, "available")
        date_item.setData(Qt.ItemDataRole.UserRole + 2, entry)
        # Register so bulk-queue can seed this row even though it has no DB row.
        self._available_entries[entry["guid"]] = entry
        tbl.setItem(i, 0, date_item)
        tbl.setItem(i, 1, QTableWidgetItem(entry.get("title") or ""))
        pill = Pill("available", kind=_STATUS_PILL_KIND["available"])
        holder = QWidget()
        lay = QHBoxLayout(holder)
        lay.setContentsMargins(4, 2, 4, 2)
        lay.addWidget(pill)
        lay.addStretch(1)
        tbl.setCellWidget(i, 2, holder)

    def _set_load_more_visible(self, visible: bool) -> None:
        btn = getattr(self, "_load_more_btn", None)
        if btn is not None:
            btn.setVisible(visible)

    def _load_more(self) -> None:
        """Resume paced appending for the next cap-sized window of videos."""
        self._history_session_count = 0
        self._set_load_more_visible(False)
        if not self._available_buffer:
            return
        self._ensure_history_timer().start(_HISTORY_TICK_MS)
        self._append_next_batch()

    def _trigger_available(self, guid: str) -> None:
        """Seed + queue a single back-catalogue video.

        Delegates to the bulk path, which now seeds an unseeded ``available``
        row (upsert → ``pending``), bumps it to PRIORITY_RUN_NEXT, nudges the
        worker, prunes it from the buffer/registry, and rebuilds the table —
        after which the row is a real ``pending`` DB row, not a synthetic one.
        """
        self._queue_guids([guid])

    def _cancel_history_stream(self) -> None:
        """Stop the paced timer, reap the enumeration thread, clear the buffer.

        Called from ``closeEvent`` so a dialog close can't leave a timer
        ticking or a worker shelling out to yt-dlp in the background. The latch
        also ignores any `loaded`/tick that races in after this returns.
        """
        self._history_cancelled = True
        self._stop_history_timer()
        thread = getattr(self, "_history_thread", None)
        if thread is not None:
            try:
                thread.loaded.disconnect()
                thread.failed.disconnect()
            except (TypeError, RuntimeError, AttributeError):
                pass
            try:
                if thread.isRunning():
                    thread.requestInterruption()
                    thread.quit()
                    # A thread blocked in the yt-dlp subprocess (enumerate
                    # timeout is 300 s) can outlive this 2 s wait and keep
                    # running in the background until the dump returns; its
                    # signals are disconnected and the latch is set, so it's
                    # harmless. Consistent with the metadata/artwork threads.
                    thread.wait(2000)
            except (RuntimeError, AttributeError):
                pass
        self._available_buffer = []
        self._available_entries = {}

    # ── footer ───────────────────────────────────────────────

    def _build_footer(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(8)

        remove = QPushButton("Remove")
        remove.setProperty("role", "ghost")
        remove.setStyleSheet(f"QPushButton {{ color: {current_tokens()['danger']}; }}")
        remove.clicked.connect(self._remove)
        row.addWidget(remove)

        mark_stale = QPushButton("Mark stale")
        mark_stale.setProperty("role", "ghost")
        mark_stale.clicked.connect(self._mark_stale)
        row.addWidget(mark_stale)

        row.addStretch(1)

        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        row.addWidget(cancel)

        save = QPushButton("Save")
        save.setProperty("role", "primary")
        save.setDefault(True)
        save.clicked.connect(self._save)
        row.addWidget(save)

        return row

    # ── actions ──────────────────────────────────────────────

    def _save(self):
        self.show_.rss = self.rss_edit.text().strip()
        self.show_.enabled = self.enabled_toggle.isChecked()
        out = self.output_edit.text().strip()
        self.show_.output_override = out or None
        # Advanced — tuning
        new_title = self._title_edit.text().strip()
        if new_title:
            self.show_.title = new_title
        self.show_.language = self._language_combo.currentData() or "de"
        self.show_.whisper_prompt = self._whisper_prompt_edit.toPlainText().strip()
        if self.transcript_pref_combo is not None:
            self.show_.youtube_transcript_pref = self.transcript_pref_combo.currentData() or ""
        if self._skip_shorts_toggle is not None:
            self.show_.skip_shorts = self._skip_shorts_toggle.isChecked()
        save_watchlist(self.ctx)
        self.accept()

    def _mark_stale(self):
        with self.ctx.state._conn() as c:
            c.execute(
                "UPDATE episodes SET status='pending' WHERE show_slug=?",
                (self.slug,),
            )
        QMessageBox.information(
            self,
            "Marked stale",
            f"All episodes of '{self.show_.title}' were marked pending.",
        )
        # Refresh the backlog label in-place so the user sees the effect.
        self.backlog_lbl.setText(self._fmt_backlog())

    def _remove(self):
        resp = QMessageBox.question(
            self,
            "Remove show",
            f"Remove '{self.show_.title}' from the watchlist?\n"
            "Its episode history is cleared (so re-adding starts fresh); "
            "transcript files already on disk are kept.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if resp != QMessageBox.StandardButton.Yes:
            return
        self.ctx.watchlist.shows = [s for s in self.ctx.watchlist.shows if s.slug != self.slug]
        save_watchlist(self.ctx)
        # Purge the episode rows so re-adding the same channel re-queues from a
        # clean slate instead of finding its old episodes still marked done.
        self.ctx.state.delete_episodes_for_show(self.slug)
        from ui.activity_log import log as log_activity

        log_activity(f"Removed show '{self.show_.title}' ({self.slug})")
        self.accept()
