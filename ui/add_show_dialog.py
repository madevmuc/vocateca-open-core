"""Add Podcast dialog — 3-mode segmented input (by name / by URL / Apple link).

All three modes funnel through `_do_save(show_dict)`, preserving the original
seeding logic (backlog strategy, manifest upsert).
"""

from __future__ import annotations

import time
from typing import Optional
from urllib.parse import urlparse

from PyQt6.QtCore import QDate, QObject, QRunnable, Qt, QThread, QThreadPool, QTimer, pyqtSignal
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QComboBox,
    QDateEdit,
    QDialog,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QRadioButton,
    QStackedWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from core import youtube_meta as _youtube_meta
from core import ytdlp as _ytdlp
from core.discovery import find_rss_from_url, search_itunes
from core.models import Show
from core.prompt_gen import suggest_whisper_prompt
from core.rss import FeedHealth, build_manifest_with_url, feed_metadata
from core.sanitize import slugify
from core.sources import youtube_enabled
from core.watchlist_io import save_watchlist
from core.youtube import (
    YoutubeUrlError,
    parse_youtube_url,
    rss_url_for_channel_id,
)
from ui.feed_probe import FeedProbeWorker
from ui.themes import current_tokens
from ui.widgets.pill import Pill
from ui.widgets.show_results_table import ShowResultsTable
from ui.ytdlp_install_dialog import YtdlpInstallDialog

# --------------------------------------------------------------------------- #
# Background fetchers                                                         #
# --------------------------------------------------------------------------- #


class _FeedFetchThread(QThread):
    """Fetch feed_metadata + build_manifest_with_url + FeedHealth off-thread."""

    done = pyqtSignal(dict)  # {ok, rss, meta, manifest, health, error}

    def __init__(self, rss_url: str, parent=None):
        super().__init__(parent)
        self.rss_url = rss_url

    def run(self) -> None:
        out: dict = {"ok": False, "rss": self.rss_url}
        try:
            meta = feed_metadata(self.rss_url)
            canonical, manifest, _etag, _modified = build_manifest_with_url(self.rss_url)
            health = FeedHealth.check(canonical)
            out.update(
                {
                    "ok": True,
                    "rss": canonical,
                    "meta": meta,
                    "manifest": manifest,
                    "health": health,
                }
            )
        except Exception as e:  # noqa: BLE001
            out["error"] = str(e)
        self.done.emit(out)


class _AppleResolveThread(QThread):
    """Resolve an Apple Podcasts (or generic) landing URL → RSS URL."""

    done = pyqtSignal(dict)  # {ok, rss, error}

    def __init__(self, apple_url: str, parent=None):
        super().__init__(parent)
        self.apple_url = apple_url

    def run(self) -> None:
        out: dict = {"ok": False}
        try:
            rss = find_rss_from_url(self.apple_url)
            if not rss:
                out["error"] = "No RSS link found on that page."
            else:
                out.update({"ok": True, "rss": rss})
        except Exception as e:  # noqa: BLE001
            out["error"] = str(e)
        self.done.emit(out)


class _YoutubeResolveThread(QThread):
    """Resolve a YouTube handle/channel URL → channel preview off-thread.

    yt-dlp HTTP calls take 5–30 s. Running them on the GUI thread freezes
    the app; macOS then SIGTERMs the unresponsive process.
    """

    done = pyqtSignal(dict)  # {ok, preview, error}
    step = pyqtSignal(int, int, str)  # (current_step, total_steps, label)

    def __init__(self, parsed_kind: str, parsed_value: str, parent=None):
        super().__init__(parent)
        self.parsed_kind = parsed_kind
        self.parsed_value = parsed_value

    def run(self) -> None:
        out: dict = {"ok": False}
        try:
            self.step.emit(1, 2, "Resolving channel ID…")
            if self.parsed_kind == "handle":
                cid = _youtube_meta.resolve_handle_to_channel_id(self.parsed_value)
            elif self.parsed_kind == "channel_url":
                cid = _youtube_meta.resolve_channel_url_to_id(self.parsed_value)
            elif self.parsed_kind == "channel_id":
                cid = self.parsed_value
            else:
                raise ValueError(f"unsupported YouTube URL kind: {self.parsed_kind!r}")
            if not cid:
                raise ValueError("Couldn't resolve that URL to a YouTube channel.")
            self.step.emit(2, 2, "Fetching channel info…")
            preview = _youtube_meta.fetch_channel_preview(cid)
            out.update({"ok": True, "preview": preview})
        except Exception as e:  # noqa: BLE001
            out["error"] = str(e)
        self.done.emit(out)


class _YtFirstVideoThread(QThread):
    """Fetch a channel's oldest upload date off-thread.

    yt-dlp has to walk the channel's video listing to find the last (oldest)
    item, which can take a few seconds — so it runs off the GUI thread and
    only when the user actually picks the 'since a specific date' option.
    """

    done = pyqtSignal(str)  # "YYYY-MM-DD" or "" on failure

    def __init__(self, channel_id: str, parent=None):
        super().__init__(parent)
        self.channel_id = channel_id

    def run(self) -> None:
        try:
            iso = _youtube_meta.fetch_channel_first_video_date(self.channel_id)
        except Exception:  # noqa: BLE001
            iso = ""
        self.done.emit(iso)


class _YoutubeEnumerateThread(QThread):
    """Enumerate a channel's videos off-thread.

    ``enumerate_channel_videos`` shells out to yt-dlp and can take many
    seconds on a large channel. Running it on the GUI thread freezes the app
    (and macOS then SIGTERMs the unresponsive process), so it runs here.
    """

    done = pyqtSignal(list)  # list[dict] of video entries
    error = pyqtSignal(str)  # message on failure

    def __init__(self, channel_id: str, limit, parent=None):
        super().__init__(parent)
        self.channel_id = channel_id
        self.limit = limit

    def run(self) -> None:
        try:
            videos = _youtube_meta.enumerate_channel_videos(self.channel_id, limit=self.limit)
        except Exception as e:  # noqa: BLE001
            self.error.emit(str(e))
            return
        self.done.emit(videos)


class _CoverSignals(QObject):
    done = pyqtSignal(int, QPixmap)


class _CoverWorker(QRunnable):
    """Fetches a cover image off-thread, decodes to a 48 px-high QPixmap,
    and emits (row_index, pixmap) on success. Silent on any failure — the
    table just keeps its blank cover cell."""

    def __init__(self, row: int, url: str):
        super().__init__()
        self._row = row
        self._url = url
        self._signals = _CoverSignals()
        self.done = self._signals.done

    def run(self) -> None:
        try:
            from core.http import get_client

            r = get_client().get(self._url, timeout=6.0, follow_redirects=True)
            r.raise_for_status()
        except Exception:
            return
        px = QPixmap()
        if not px.loadFromData(r.content):
            return
        if px.isNull():
            return
        px = px.scaledToHeight(48, Qt.TransformationMode.SmoothTransformation)
        self._signals.done.emit(self._row, px)


# --------------------------------------------------------------------------- #
# Dialog                                                                      #
# --------------------------------------------------------------------------- #


def _shorten(url: str, n: int = 48) -> str:
    return url if len(url) <= n else url[: n - 1] + "\u2026"


class AddShowDialog(QDialog):
    def __init__(self, ctx, parent=None, *, initial_mode: Optional[str] = None):
        super().__init__(parent)
        self.ctx = ctx
        self.updated_watchlist = ctx.watchlist
        self.setWindowTitle("Add Podcast")
        self.resize(750, 640)

        # Shared state across modes
        self._loaded_manifest: list = []
        self._loaded_meta: dict = {}
        self._loaded_rss: str = ""
        self._fetch_thread: Optional[QThread] = None
        self._apple_thread: Optional[QThread] = None
        # Name-mode pagination: track last search so 'Load 50 more' knows
        # what to re-query; limit grows by 50 per click up to iTunes' 200 cap.
        self._name_search_term: str = ""
        self._name_search_limit: int = 50

        # QThreadPool for probe + cover workers — shared, concurrency-capped.
        # Keep it tight to stay friendly with feed hosts.
        self._search_pool = QThreadPool(self)
        self._search_pool.setMaxThreadCount(6)
        self._probed_rows: set[int] = set()

        root = QVBoxLayout(self)

        # --- Segmented mode switcher -------------------------------------- #
        # Wrapped in a container so it can be hidden when the dialog is
        # launched in a single, focused mode (e.g. the dedicated
        # "Add YouTube Channel…" button — no podcast tabs to distract).
        self._mode_switcher = QWidget()
        mode_row = QHBoxLayout(self._mode_switcher)
        mode_row.setContentsMargins(0, 0, 0, 0)
        self._mode_buttons = QButtonGroup(self)
        self._mode_buttons.setExclusive(True)
        modes = [
            ("name", "By name"),
            ("url", "By URL"),
            ("apple", "Paste Apple link"),
        ]
        # Append the 4th mode only when YouTube ingestion is enabled in
        # settings — keeps the dialog identical for podcast-only users.
        self._yt_enabled = youtube_enabled(ctx.settings)
        if self._yt_enabled:
            modes.append(("youtube", "YouTube URL"))
        for key, label in modes:
            b = QRadioButton(label)
            b.setProperty("mode", key)
            mode_row.addWidget(b)
            self._mode_buttons.addButton(b)
        mode_row.addStretch(1)
        self._mode_buttons.buttons()[0].setChecked(True)
        self._mode_buttons.buttonToggled.connect(self._on_mode_change)
        root.addWidget(self._mode_switcher)

        # --- Stacked pages ------------------------------------------------- #
        self._pages = QStackedWidget()
        self._page_name = self._build_name_page()
        self._page_url = self._build_url_page()
        self._page_apple = self._build_apple_page()
        pages = [self._page_name, self._page_url, self._page_apple]
        if self._yt_enabled:
            self._page_youtube = self._build_youtube_page()
            pages.append(self._page_youtube)
        for p in pages:
            self._pages.addWidget(p)
        root.addWidget(self._pages, 1)

        # Focused launch: jump straight to one mode and drop the switcher so
        # the dialog reads as a single-purpose popup. Only "youtube" is wired
        # for now (the dedicated Shows-tab button); unknown modes fall back to
        # the default multi-tab dialog.
        if initial_mode == "youtube" and self._yt_enabled:
            self.setWindowTitle("Add YouTube Channel")
            self._mode_switcher.setVisible(False)
            self._activate_youtube_mode()

    # ------------------------------------------------------------------ #
    # Mode switching                                                     #
    # ------------------------------------------------------------------ #

    def _on_mode_change(self, button, checked: bool) -> None:
        if not checked:
            return
        key = button.property("mode")
        idx = {"name": 0, "url": 1, "apple": 2, "youtube": 3}.get(key, 0)
        self._pages.setCurrentIndex(idx)
        if key == "youtube":
            self._refresh_youtube_install_gate()
            if not _ytdlp.is_installed() and not getattr(self, "_yt_install_attempted", False):
                self._yt_install_attempted = True
                # Defer so the YouTube page is visible before the install
                # dialog appears centred over it.
                QTimer.singleShot(0, self._open_ytdlp_installer)

    # ------------------------------------------------------------------ #
    # Mode A — By name (iTunes search, preserved behavior)               #
    # ------------------------------------------------------------------ #

    def _build_name_page(self) -> QWidget:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(0, 0, 0, 0)

        v.addWidget(QLabel("Search iTunes for a podcast by name:"))
        row = QHBoxLayout()
        self.name_input = QLineEdit()
        self.name_input.setPlaceholderText("e.g. Lex Fridman Podcast")
        self.name_input.returnPressed.connect(self._search_by_name)
        self.name_input.textChanged.connect(self._on_name_text_changed)
        row.addWidget(self.name_input, 1)
        search_btn = QPushButton("Search")
        search_btn.clicked.connect(self._search_by_name)
        row.addWidget(search_btn)
        v.addLayout(row)

        # Debounce the search-as-you-type. iTunes rate-limits aggressive
        # callers and a per-keystroke hit would jitter the results as
        # the user is still typing. 350 ms pause feels responsive while
        # coalescing bursts of keys into one request.
        self._name_search_debounce = QTimer(self)
        self._name_search_debounce.setSingleShot(True)
        self._name_search_debounce.setInterval(350)
        self._name_search_debounce.timeout.connect(self._search_by_name)

        self.results = ShowResultsTable()
        self.results.cellDoubleClicked.connect(self._pick_name_result_by_row)
        self.results.currentCellChanged.connect(self._prefill_from_current_row)
        # Auto-fetch the next page when the user scrolls within ~60 px of
        # the bottom. A visible button interrupts the flow; an infinite-
        # scroll feel is closer to what the app's users expect. Also
        # probe rows as they scroll into view.
        self.results.verticalScrollBar().valueChanged.connect(self._on_name_scroll)
        v.addWidget(self.results, 1)

        self._name_hint = QLabel("")
        self._name_hint.setStyleSheet(f"color: {current_tokens()['ink_3']}; font-size: 11px;")
        v.addWidget(self._name_hint)
        self._name_fetch_in_flight = False

        form = QFormLayout()
        self.name_slug = QLineEdit()
        self.name_title = QLineEdit()
        self.name_rss = QLineEdit()
        self.name_prompt = QTextEdit()
        self.name_prompt.setFixedHeight(80)
        form.addRow("Slug", self.name_slug)
        form.addRow("Title", self.name_title)
        form.addRow("RSS", self.name_rss)
        form.addRow("Whisper prompt", self.name_prompt)
        v.addLayout(form)

        v.addLayout(self._backlog_row("name"))
        v.addLayout(self._button_row(on_add=self._add_from_name))
        return page

    def _on_name_text_changed(self, text: str) -> None:
        """Restart the debounce timer on every keystroke.

        Short or pasted-URL inputs short-circuit — no point firing a
        search for ``"a"`` and pasted URLs route through the Enter/
        Search-button path which runs ``find_rss_from_url`` instead.
        """
        stripped = text.strip()
        if len(stripped) < 2 or stripped.startswith(("http://", "https://")):
            self._name_search_debounce.stop()
            return
        self._name_search_debounce.start()

    def _search_by_name(self) -> None:
        # Stop any pending debounce so a manual Enter/click doesn't race
        # with a still-armed timer.
        self._name_search_debounce.stop()
        term = self.name_input.text().strip()
        if not term:
            return
        self.results.set_matches([])
        self._name_hint.setText("")
        self._name_search_term = term
        self._name_search_limit = 50
        try:
            if term.startswith("http"):
                # Convenience: pasted a URL in the name mode.
                rss = find_rss_from_url(term)
                if rss:
                    self._fill_from_feed_sync(rss)
                    return
                QMessageBox.warning(self, "Not found", "No RSS link on that page.")
                return
            self._render_name_results(search_itunes(term, limit=self._name_search_limit))
            if self.results.rowCount() == 0:
                QMessageBox.information(self, "No matches", "iTunes returned no results.")
        except Exception as e:  # noqa: BLE001
            QMessageBox.warning(self, "Error", str(e))

    def _render_name_results(self, matches) -> None:
        """Fill the results table and update the hint.

        Called on initial search and on every scroll-triggered auto-load —
        we replace the full list rather than append because iTunes doesn't
        guarantee stable ordering across calls, so a superset request may
        reshuffle earlier positions.
        """
        # Preserve scroll position across re-renders so an auto-load
        # triggered at the bottom doesn't jerk the viewport back to the top.
        scroll_val = self.results.verticalScrollBar().value()
        self.results.set_matches(list(matches))
        self.results.verticalScrollBar().setValue(scroll_val)
        # Reset probe bookkeeping on a replace-all render.
        self._probed_rows = set()
        shown = self.results.rowCount()
        # iTunes caps at 200 and returns fewer when the query is narrow.
        hit_api_cap = self._name_search_limit >= 200
        capped_by_server = shown < self._name_search_limit
        if capped_by_server or hit_api_cap:
            self._name_hint.setText(f"Showing all {shown} matches.")
        else:
            self._name_hint.setText(f"Showing top {shown} · scroll for more.")
        # Kick off top-10 feed probes + covers.
        self._probe_rows(range(min(10, shown)))
        self._load_covers(range(shown))

    def _on_name_scroll(self, value: int) -> None:
        # Reuse the existing auto-load-more logic (scroll-to-bottom).
        self._maybe_auto_load_more(value)
        # Probe newly-visible rows beyond the initial top-10.
        self._probe_visible_rows()

    def _probe_visible_rows(self) -> None:
        total = self.results.rowCount()
        if total == 0:
            return
        top_row = self.results.rowAt(0)
        vh = self.results.viewport().height()
        bottom_row = self.results.rowAt(max(0, vh - 1))
        if bottom_row == -1:
            bottom_row = total - 1
        self._probe_rows(range(max(0, top_row), min(total, bottom_row + 1)))

    def _probe_rows(self, indices) -> None:
        for row in indices:
            if row in self._probed_rows:
                continue
            url = self.results.feed_url_for_row(row)
            if not url:
                continue
            self._probed_rows.add(row)
            worker = FeedProbeWorker(row, url)
            worker.done.connect(self.results.apply_probe_result)
            self._search_pool.start(worker)

    def _load_covers(self, indices) -> None:
        for row in indices:
            m = self.results.match_for_row(row)
            if m is None or not m.artwork_url:
                continue
            w = _CoverWorker(row, m.artwork_url)
            w.done.connect(self.results.set_cover)
            self._search_pool.start(w)

    def _maybe_auto_load_more(self, _value: int) -> None:
        """Trigger the next page when the user scrolls near the bottom.

        Gated on (a) a search term is set, (b) we haven't hit the 200-item
        iTunes cap, (c) the last fetch filled the requested limit (server
        hasn't signalled exhaustion), and (d) no fetch is already running.
        """
        if self._name_fetch_in_flight:
            return
        if not self._name_search_term:
            return
        if self._name_search_limit >= 200:
            return
        shown = self.results.rowCount()
        if shown == 0 or shown < self._name_search_limit:
            return  # server returned fewer than requested — no more to get.
        sb = self.results.verticalScrollBar()
        if sb.value() < sb.maximum() - 2:
            return  # not at (or within epsilon of) the bottom yet.
        self._load_more_name_results()

    def _load_more_name_results(self) -> None:
        if not self._name_search_term:
            return
        self._name_fetch_in_flight = True
        self._name_hint.setText("Loading more…")
        self._name_search_limit = min(self._name_search_limit + 50, 200)
        try:
            self._render_name_results(
                search_itunes(self._name_search_term, limit=self._name_search_limit)
            )
        except Exception as e:  # noqa: BLE001
            QMessageBox.warning(self, "Error", str(e))
        finally:
            self._name_fetch_in_flight = False

    def _pick_name_result_by_row(self, row: int, col: int) -> None:
        url = self.results.feed_url_for_row(row)
        if url is None:
            return
        self._fill_from_feed_sync(url)

    def _prefill_from_current_row(
        self, cur_row: int, _cur_col: int, _prev_row: int, _prev_col: int
    ) -> None:
        """Pre-fill RSS / title / slug from the in-memory PodcastMatch
        when the user selects a row (single-click or keyboard nav).

        The full fetch (canonical redirected URL, manifest, whisper prompt)
        still happens on double-click via ``_pick_name_result_by_row`` —
        that's the explicit "commit" action. This handler only offers an
        instant preview so the user sees feedback on selection.
        """
        m = self.results.match_for_row(cur_row)
        if m is None:
            return
        self.name_rss.setText(m.feed_url)
        self.name_title.setText(m.title)
        self.name_slug.setText(slugify(m.title or ""))

    def _fill_from_feed_sync(self, rss: str) -> None:
        try:
            meta = feed_metadata(rss)
            canonical, manifest, _etag, _modified = build_manifest_with_url(rss)
        except Exception as e:  # noqa: BLE001
            QMessageBox.warning(self, "Error", str(e))
            return
        self.name_rss.setText(canonical)
        self.name_title.setText(meta["title"])
        default_slug = slugify(meta["title"] or "")
        self.name_slug.setText(default_slug)
        prompt = suggest_whisper_prompt(
            title=meta["title"],
            author=meta["author"],
            episodes=[
                {"title": e["title"], "description": e["description"]} for e in manifest[-20:]
            ],
        )
        self.name_prompt.setPlainText(prompt)
        self._loaded_manifest = manifest
        self._loaded_meta = meta
        self._loaded_rss = canonical

    def _add_from_name(self) -> None:
        show = {
            "slug": self.name_slug.text().strip(),
            "title": self.name_title.text().strip(),
            "rss": self.name_rss.text().strip(),
            "whisper_prompt": self.name_prompt.toPlainText().strip(),
            "manifest": self._loaded_manifest,
            "backlog": self._backlog_choice("name"),
            "artwork_url": (self._loaded_meta or {}).get("artwork_url", ""),
        }
        self._do_save(show)

    # ------------------------------------------------------------------ #
    # Mode B — By URL                                                    #
    # ------------------------------------------------------------------ #

    def _build_url_page(self) -> QWidget:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(0, 0, 0, 0)

        v.addWidget(QLabel("Paste an RSS feed URL:"))
        row = QHBoxLayout()
        self.url_input = QLineEdit()
        self.url_input.setPlaceholderText("https://example.com/podcast.rss")
        self.url_input.editingFinished.connect(self._fetch_url_preview)
        row.addWidget(self.url_input, 1)
        fetch_btn = QPushButton("Preview")
        fetch_btn.clicked.connect(self._fetch_url_preview)
        row.addWidget(fetch_btn)
        v.addLayout(row)

        self.url_status = Pill("", kind="idle")
        self.url_status.setVisible(False)
        v.addWidget(self.url_status, 0, Qt.AlignmentFlag.AlignLeft)

        # Preview card
        self.url_card = QFrame()
        self.url_card.setObjectName("PreviewCard")
        self.url_card.setFrameShape(QFrame.Shape.StyledPanel)
        self.url_card.setVisible(False)
        card_v = QVBoxLayout(self.url_card)

        self.url_card_title = QLabel("")
        f = self.url_card_title.font()
        f.setPointSize(f.pointSize() + 4)
        f.setBold(True)
        self.url_card_title.setFont(f)
        self.url_card_title.setWordWrap(True)
        card_v.addWidget(self.url_card_title)

        self.url_card_publisher = QLabel("")
        self.url_card_publisher.setStyleSheet(f"color: {current_tokens()['ink_3']};")
        self.url_card_publisher.setWordWrap(True)
        card_v.addWidget(self.url_card_publisher)

        self.url_card_meta = QLabel("")
        card_v.addWidget(self.url_card_meta)

        self.url_card_warnings = QLabel("")
        self.url_card_warnings.setStyleSheet(f"color: {current_tokens()['danger']};")
        self.url_card_warnings.setWordWrap(True)
        self.url_card_warnings.setVisible(False)
        card_v.addWidget(self.url_card_warnings)

        v.addWidget(self.url_card)
        v.addStretch(1)

        v.addLayout(self._backlog_row("url"))
        self.url_add_btn_row = self._button_row(
            on_add=self._add_from_url, add_enabled=False, store_add_on="url"
        )
        v.addLayout(self.url_add_btn_row)
        return page

    def _fetch_url_preview(self) -> None:
        url = self.url_input.text().strip()
        if not url:
            return
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https"):
            QMessageBox.warning(self, "Invalid URL", "Please enter an http(s) URL.")
            return
        if self._fetch_thread and self._fetch_thread.isRunning():
            return
        self.url_status.setText("Fetching feed…")
        self.url_status.set_kind("running")
        self.url_status.setVisible(True)
        self.url_card.setVisible(False)
        self._url_add_btn.setEnabled(False)

        self._fetch_thread = _FeedFetchThread(url, self)
        self._fetch_thread.done.connect(self._on_url_fetched)
        self._fetch_thread.start()

    def _on_url_fetched(self, result: dict) -> None:
        if not result.get("ok"):
            self.url_status.setText(f"Error: {result.get('error', 'unknown')}")
            self.url_status.set_kind("fail")
            return
        meta = result["meta"]
        manifest = result["manifest"]
        health: FeedHealth = result["health"]
        rss = result["rss"]

        self._loaded_meta = meta
        self._loaded_manifest = manifest
        self._loaded_rss = rss

        self.url_card_title.setText(meta.get("title") or "(untitled)")
        self.url_card_publisher.setText(meta.get("author") or "")
        latest = manifest[-1]["pubDate"][:10] if manifest else "—"
        self.url_card_meta.setText(f"{len(manifest)} episode(s) · latest: {latest}")
        warnings = []
        if not health.ok:
            warnings.append(f"Feed health: {health.reason}")
        if not manifest:
            warnings.append("No episodes with audio enclosures were found.")
        if warnings:
            self.url_card_warnings.setText(" · ".join(warnings))
            self.url_card_warnings.setVisible(True)
        else:
            self.url_card_warnings.setVisible(False)

        self.url_card.setVisible(True)
        self.url_status.setText("Ready")
        self.url_status.set_kind("ok")
        self._url_add_btn.setEnabled(bool(manifest))

    def _add_from_url(self) -> None:
        meta = self._loaded_meta
        title = meta.get("title") or "show"
        slug = slugify(title)
        prompt = suggest_whisper_prompt(
            title=title,
            author=meta.get("author", ""),
            episodes=[
                {"title": e["title"], "description": e["description"]}
                for e in self._loaded_manifest[-20:]
            ],
        )
        show = {
            "slug": slug,
            "title": title,
            "rss": self._loaded_rss,
            "whisper_prompt": prompt,
            "manifest": self._loaded_manifest,
            "backlog": self._backlog_choice("url"),
            "artwork_url": meta.get("artwork_url", ""),
        }
        self._do_save(show)

    # ------------------------------------------------------------------ #
    # Mode C — Paste Apple link                                          #
    # ------------------------------------------------------------------ #

    def _build_apple_page(self) -> QWidget:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(0, 0, 0, 0)

        v.addWidget(QLabel("Paste an Apple Podcasts link:"))
        row = QHBoxLayout()
        self.apple_input = QLineEdit()
        self.apple_input.setPlaceholderText("https://podcasts.apple.com/…/id1234567890")
        self.apple_input.editingFinished.connect(self._detect_apple)
        row.addWidget(self.apple_input, 1)
        detect_btn = QPushButton("Detect RSS")
        detect_btn.clicked.connect(self._detect_apple)
        row.addWidget(detect_btn)
        v.addLayout(row)

        self.apple_status = Pill("", kind="idle")
        self.apple_status.setVisible(False)
        v.addWidget(self.apple_status, 0, Qt.AlignmentFlag.AlignLeft)

        # Dashed-border compact card
        self.apple_card = QFrame()
        self.apple_card.setObjectName("ApplePreviewCard")
        _t = current_tokens()
        self.apple_card.setStyleSheet(
            f"QFrame#ApplePreviewCard {{ border: 1px dashed {_t['line']}; "
            f"border-radius: 6px; padding: 8px; }}"
        )
        self.apple_card.setVisible(False)
        card_v = QVBoxLayout(self.apple_card)
        self.apple_card_title = QLabel("")
        f = self.apple_card_title.font()
        f.setBold(True)
        self.apple_card_title.setFont(f)
        self.apple_card_title.setWordWrap(True)
        card_v.addWidget(self.apple_card_title)
        self.apple_card_rss = QLabel("")
        self.apple_card_rss.setStyleSheet(f"color: {_t['ink_3']};")
        self.apple_card_rss.setWordWrap(True)
        card_v.addWidget(self.apple_card_rss)
        v.addWidget(self.apple_card)
        v.addStretch(1)

        v.addLayout(self._backlog_row("apple", default="Last 5"))

        # Custom button row with "Customise…" instead of just Cancel/Add
        btn_row = QHBoxLayout()
        btn_row.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        btn_row.addWidget(cancel)
        self.apple_customise_btn = QPushButton("Customise…")
        self.apple_customise_btn.setEnabled(False)
        self.apple_customise_btn.clicked.connect(self._customise_from_apple)
        btn_row.addWidget(self.apple_customise_btn)
        self.apple_add_btn = QPushButton("Add")
        self.apple_add_btn.setDefault(True)
        self.apple_add_btn.setEnabled(False)
        self.apple_add_btn.clicked.connect(self._add_from_apple)
        btn_row.addWidget(self.apple_add_btn)
        v.addLayout(btn_row)
        return page

    def _detect_apple(self) -> None:
        url = self.apple_input.text().strip()
        if not url:
            return
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https"):
            QMessageBox.warning(self, "Invalid URL", "Please enter an http(s) URL.")
            return
        if self._apple_thread and self._apple_thread.isRunning():
            return
        self.apple_status.setText("Detecting RSS…")
        self.apple_status.set_kind("running")
        self.apple_status.setVisible(True)
        self.apple_card.setVisible(False)
        self.apple_add_btn.setEnabled(False)
        self.apple_customise_btn.setEnabled(False)

        self._apple_thread = _AppleResolveThread(url, self)
        self._apple_thread.done.connect(self._on_apple_resolved)
        self._apple_thread.start()

    def _on_apple_resolved(self, result: dict) -> None:
        if not result.get("ok"):
            self.apple_status.setText(f"Error: {result.get('error', 'unknown')}")
            self.apple_status.set_kind("fail")
            return
        rss = result["rss"]
        # Now pull metadata (lightweight second hop).
        self._fetch_thread = _FeedFetchThread(rss, self)
        self._fetch_thread.done.connect(self._on_apple_feed_fetched)
        self.apple_status.setText("Loading feed…")
        self.apple_status.set_kind("running")
        self._fetch_thread.start()

    def _on_apple_feed_fetched(self, result: dict) -> None:
        if not result.get("ok"):
            self.apple_status.setText(f"Error: {result.get('error', 'unknown')}")
            self.apple_status.set_kind("fail")
            return
        meta = result["meta"]
        self._loaded_meta = meta
        self._loaded_manifest = result["manifest"]
        self._loaded_rss = result["rss"]
        self.apple_card_title.setText(meta.get("title") or "(untitled)")
        self.apple_card_rss.setText(f"RSS detected at {_shorten(result['rss'])}")
        self.apple_card.setVisible(True)
        self.apple_status.setText("Ready")
        self.apple_status.set_kind("ok")
        self.apple_add_btn.setEnabled(bool(self._loaded_manifest))
        self.apple_customise_btn.setEnabled(True)

    def _add_from_apple(self) -> None:
        meta = self._loaded_meta
        title = meta.get("title") or "show"
        slug = slugify(title)
        prompt = suggest_whisper_prompt(
            title=title,
            author=meta.get("author", ""),
            episodes=[
                {"title": e["title"], "description": e["description"]}
                for e in self._loaded_manifest[-20:]
            ],
        )
        show = {
            "slug": slug,
            "title": title,
            "rss": self._loaded_rss,
            "whisper_prompt": prompt,
            "manifest": self._loaded_manifest,
            "backlog": self._backlog_choice("apple"),
            "artwork_url": meta.get("artwork_url", ""),
        }
        self._do_save(show)

    def _customise_from_apple(self) -> None:
        """Jump to Mode A pre-filled with the detected feed."""
        # Switch mode
        self._mode_buttons.buttons()[0].setChecked(True)
        # Pre-fill search term from detected title + pre-run the search.
        title = (self._loaded_meta or {}).get("title", "")
        if title:
            self.name_input.setText(title)
            self._search_by_name()
        # Also pre-fill the form fields directly from the resolved feed, so
        # the user can hit Add immediately without picking a search result.
        if self._loaded_rss:
            self._fill_from_feed_sync(self._loaded_rss)

    # ------------------------------------------------------------------ #
    # Common: backlog toggle, button row, save funnel                    #
    # ------------------------------------------------------------------ #

    def _backlog_row(self, key: str, default: str = "Last 5") -> QVBoxLayout:
        """Two-row backlog selector: count radios + time-window dropdown.

        Returns a QVBoxLayout containing both rows. Mutually exclusive:
        picking a time window deselects radios; picking a radio resets the
        time dropdown to '— none —'.
        """
        wrapper = QVBoxLayout()
        wrapper.setContentsMargins(0, 0, 0, 0)

        radios_row = QHBoxLayout()
        radios_row.addWidget(QLabel("Backlog:"))
        grp = QButtonGroup(self)
        grp.setExclusive(True)
        for label in ("Most recent", "Last 5", "Last 10", "Last 20", "Last 50", "All"):
            b = QRadioButton(label)
            if label == default:
                b.setChecked(True)
            grp.addButton(b)
            radios_row.addWidget(b)
        radios_row.addStretch(1)
        wrapper.addLayout(radios_row)

        time_row = QHBoxLayout()
        time_row.addWidget(QLabel("Or by time:"))
        combo = QComboBox()
        combo.addItem("— none —", userData=None)
        for label, days in (
            ("Last 7 days", 7),
            ("Last 30 days", 30),
            ("Last 6 months", 183),
            ("Last 12 months", 365),
        ):
            combo.addItem(label, userData=days)
        time_row.addWidget(combo)
        time_row.addStretch(1)
        wrapper.addLayout(time_row)

        # Mutual exclusion wiring.
        def _on_time_changed(_idx: int) -> None:
            if combo.currentData() is None:
                return
            grp.setExclusive(False)
            for btn in grp.buttons():
                btn.setChecked(False)
            grp.setExclusive(True)

        def _on_radio_toggled(checked: bool) -> None:
            if not checked:
                return
            if combo.currentIndex() != 0:
                combo.blockSignals(True)
                combo.setCurrentIndex(0)
                combo.blockSignals(False)

        combo.currentIndexChanged.connect(_on_time_changed)
        for b in grp.buttons():
            b.toggled.connect(_on_radio_toggled)

        setattr(self, f"_backlog_grp_{key}", grp)
        setattr(self, f"_backlog_time_{key}", combo)
        return wrapper

    def _backlog_choice(self, key: str) -> str:
        """Return one of:
        - 'All'
        - 'Most recent'
        - 'Last N' (5/10/20/50)
        - 'Time:N' where N is the time-window in days (7/30/183/365)
        """
        combo: QComboBox = getattr(self, f"_backlog_time_{key}", None)
        if combo is not None and combo.currentData() is not None:
            return f"Time:{int(combo.currentData())}"
        grp: QButtonGroup = getattr(self, f"_backlog_grp_{key}")
        btn = grp.checkedButton()
        return btn.text() if btn else "Last 5"

    def _button_row(
        self, *, on_add, add_enabled: bool = True, store_add_on: Optional[str] = None
    ) -> QHBoxLayout:
        row = QHBoxLayout()
        row.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        row.addWidget(cancel)
        add = QPushButton("Add")
        add.setDefault(True)
        add.setEnabled(add_enabled)
        add.clicked.connect(on_add)
        row.addWidget(add)
        if store_add_on:
            setattr(self, f"_{store_add_on}_add_btn", add)
        return row

    # ------------------------------------------------------------------ #
    # Mode D — YouTube URL                                               #
    # ------------------------------------------------------------------ #

    def _build_youtube_page(self) -> QWidget:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(0, 0, 0, 0)

        self._loaded_yt_preview: dict = {}

        # Install gate — shown when yt-dlp is missing.
        self._yt_install_btn = QPushButton("Install yt-dlp")
        self._yt_install_btn.clicked.connect(self._open_ytdlp_installer)
        self._yt_install_btn.setVisible(False)
        v.addWidget(self._yt_install_btn, 0, Qt.AlignmentFlag.AlignLeft)

        v.addWidget(QLabel("Paste a YouTube channel URL or video URL:"))
        row = QHBoxLayout()
        self.youtube_url_input = QLineEdit()
        self.youtube_url_input.setPlaceholderText("Paste YouTube channel URL or video URL")
        self.youtube_url_input.editingFinished.connect(self._on_youtube_url_resolve)
        row.addWidget(self.youtube_url_input, 1)
        self._yt_resolve_btn = QPushButton("Resolve")
        self._yt_resolve_btn.clicked.connect(self._on_youtube_url_resolve)
        row.addWidget(self._yt_resolve_btn)
        v.addLayout(row)

        self.yt_status = Pill("", kind="idle")
        self.yt_status.setVisible(False)
        v.addWidget(self.yt_status, 0, Qt.AlignmentFlag.AlignLeft)

        # Indeterminate marquee — visible only while a resolve OR an off-thread
        # channel enumeration is in flight, so the user can see the app isn't
        # frozen during the yt-dlp wait. The Cancel button rides alongside it
        # and is only shown while enumeration is running (the user can bail).
        prog_row = QHBoxLayout()
        self.yt_progress = QProgressBar()
        self.yt_progress.setRange(0, 0)
        self.yt_progress.setTextVisible(False)
        self.yt_progress.setVisible(False)
        prog_row.addWidget(self.yt_progress, 1)
        self._yt_enum_cancel_btn = QPushButton("Cancel")
        self._yt_enum_cancel_btn.setVisible(False)
        self._yt_enum_cancel_btn.clicked.connect(self._cancel_yt_enumerate)
        prog_row.addWidget(self._yt_enum_cancel_btn, 0)
        v.addLayout(prog_row)

        # Off-thread channel-enumeration state.
        self._yt_enumerate_thread: Optional[QThread] = None
        self._yt_pending: dict = {}
        self._yt_enumerating: bool = False

        # Live-tick state for the resolve progress UI.
        self._yt_resolve_timer: Optional[QTimer] = None
        self._yt_resolve_started_at: float = 0.0
        self._yt_resolve_step_label: str = ""
        self._yt_resolve_step_idx: tuple = (0, 2)

        # Preview card — channel thumbnail (auto-loaded) on the left,
        # title + meta on the right.
        self.yt_card = QFrame()
        self.yt_card.setObjectName("YoutubePreviewCard")
        self.yt_card.setFrameShape(QFrame.Shape.StyledPanel)
        self.yt_card.setVisible(False)
        card_h = QHBoxLayout(self.yt_card)
        self.yt_card_thumb = QLabel("")
        self.yt_card_thumb.setFixedSize(48, 48)
        self.yt_card_thumb.setVisible(False)
        card_h.addWidget(self.yt_card_thumb, 0, Qt.AlignmentFlag.AlignTop)
        card_v = QVBoxLayout()
        self.yt_card_title = QLabel("")
        f = self.yt_card_title.font()
        f.setPointSize(f.pointSize() + 4)
        f.setBold(True)
        self.yt_card_title.setFont(f)
        self.yt_card_title.setWordWrap(True)
        card_v.addWidget(self.yt_card_title)
        self.yt_card_meta = QLabel("")
        self.yt_card_meta.setStyleSheet(f"color: {current_tokens()['ink_3']};")
        card_v.addWidget(self.yt_card_meta)
        card_h.addLayout(card_v, 1)
        v.addWidget(self.yt_card)

        # Slug — editable; defaults to the channel name on resolve. This is
        # the on-disk show folder + watchlist key, so let the user tidy it.
        slug_row = QHBoxLayout()
        slug_row.addWidget(QLabel("Slug:"))
        self._yt_slug_input = QLineEdit()
        self._yt_slug_input.setPlaceholderText("auto-filled from the channel name")
        slug_row.addWidget(self._yt_slug_input, 1)
        v.addLayout(slug_row)

        # Per-show transcript language. Pre-filled from the YouTube
        # default in Settings → YouTube. Used as the lang code passed to
        # both yt-dlp's caption fetch (with a fallback chain inside
        # core.youtube_captions) and whisper-cli (when audio fallback
        # fires).
        lang_row = QHBoxLayout()
        lang_row.addWidget(QLabel("Transcript language:"))
        self._yt_lang_combo = QComboBox()
        self._yt_lang_combo.addItem("German (de)", userData="de")
        self._yt_lang_combo.addItem("English (en)", userData="en")
        _seed_lang = getattr(self.ctx.settings, "youtube_default_language", "de") or "de"
        for i in range(self._yt_lang_combo.count()):
            if self._yt_lang_combo.itemData(i) == _seed_lang:
                self._yt_lang_combo.setCurrentIndex(i)
                break
        lang_row.addWidget(self._yt_lang_combo)
        lang_row.addStretch(1)
        v.addLayout(lang_row)

        # Caption import. When checked, each video is checked individually
        # for an uploader-provided (manual) subtitle in the chosen language;
        # if one exists it's moved straight into the library with no whisper
        # pass, otherwise that video falls back to whisper transcription.
        # Auto-generated captions are never used. Maps to the show's
        # youtube_transcript_pref ("captions" when checked, "whisper" when not).
        self._yt_captions_chk = QCheckBox(
            "Use uploader-provided subtitles when available "
            "(skip transcription; checked per video — auto-generated captions are never used)"
        )
        self._yt_captions_chk.setToolTip(
            "Per video: if the channel uploaded a real subtitle track in the chosen "
            "language, import it directly into the library. Videos without a manual "
            "subtitle are transcribed with whisper. Auto-generated captions are ignored."
        )
        _seed_src = getattr(self.ctx.settings, "youtube_default_transcript_source", "captions")
        self._yt_captions_chk.setChecked(_seed_src in ("captions", "auto-captions"))
        v.addWidget(self._yt_captions_chk)

        # Backfill choice (default: Only new). Count radios OR a specific
        # "since" date — mutually exclusive. "Only new" seeds the current
        # feed window as a done baseline so only future uploads transcribe.
        bf_row = QHBoxLayout()
        bf_row.addWidget(QLabel("Backfill:"))
        self._yt_backfill_grp = QButtonGroup(self)
        self._yt_backfill_grp.setExclusive(True)
        for label in ("Only new", "Last 5", "Last 20", "Last 100"):
            b = QRadioButton(label)
            if label == "Only new":
                b.setChecked(True)
            self._yt_backfill_grp.addButton(b)
            bf_row.addWidget(b)
        bf_row.addStretch(1)
        v.addLayout(bf_row)

        # Or: transcribe everything published on/after a specific date.
        # The default is the channel's first upload (fetched lazily on enable),
        # i.e. "the whole channel" unless the user narrows it.
        self._yt_first_video_date: str = ""  # cached oldest-upload ISO date
        self._yt_first_video_thread: Optional[QThread] = None
        date_row = QHBoxLayout()
        self._yt_since_chk = QCheckBox("Or since a specific date:")
        date_row.addWidget(self._yt_since_chk)
        self._yt_since_date = QDateEdit()
        self._yt_since_date.setCalendarPopup(True)
        self._yt_since_date.setDisplayFormat("yyyy-MM-dd")
        self._yt_since_date.setMinimumDate(QDate(2005, 1, 1))  # YouTube's founding
        self._yt_since_date.setMaximumDate(QDate.currentDate())
        self._yt_since_date.setDate(QDate.currentDate().addMonths(-3))
        self._yt_since_date.setEnabled(False)
        self._yt_since_user_set = False
        self._yt_since_date.dateChanged.connect(self._on_yt_since_date_changed)
        date_row.addWidget(self._yt_since_date)
        self._yt_since_hint = QLabel("defaults to the channel's first video")
        self._yt_since_hint.setStyleSheet(f"color: {current_tokens()['ink_3']};")
        date_row.addWidget(self._yt_since_hint)
        date_row.addStretch(1)
        v.addLayout(date_row)

        # Mutual exclusion: enabling the date deselects the count radios;
        # picking a count radio clears the date checkbox.
        self._yt_since_chk.toggled.connect(self._on_yt_since_toggled)
        for b in self._yt_backfill_grp.buttons():
            b.toggled.connect(self._on_yt_radio_toggled)

        v.addStretch(1)

        # Add / Cancel.
        btn_row = QHBoxLayout()
        btn_row.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        btn_row.addWidget(cancel)
        self._yt_add_btn = QPushButton("Add")
        self._yt_add_btn.setDefault(True)
        self._yt_add_btn.setEnabled(False)
        self._yt_add_btn.clicked.connect(self._add_from_youtube)
        btn_row.addWidget(self._yt_add_btn)
        v.addLayout(btn_row)

        return page

    def _activate_youtube_mode(self) -> None:
        """Programmatic switch into the YouTube tab (used by tests)."""
        for b in self._mode_buttons.buttons():
            if b.property("mode") == "youtube":
                b.setChecked(True)
                break

    def _refresh_youtube_install_gate(self) -> None:
        installed = _ytdlp.is_installed()
        self._yt_install_btn.setVisible(not installed)
        self.youtube_url_input.setEnabled(installed)
        self._yt_resolve_btn.setEnabled(installed)

    def _open_ytdlp_installer(self) -> None:
        dlg = YtdlpInstallDialog(mode="install", parent=self)
        dlg.finished_install.connect(self._on_ytdlp_install_finished)
        # showEvent triggers start() automatically — no manual start() needed.
        dlg.exec()

    def _on_ytdlp_install_finished(self, ok: bool) -> None:
        if ok:
            self._refresh_youtube_install_gate()
            # Retry the URL parse / preview if the user already pasted one.
            if self.youtube_url_input.text().strip():
                self._on_youtube_url_resolve()

    def _on_youtube_url_resolve(self) -> None:
        url = self.youtube_url_input.text().strip()
        if not url:
            return
        if not _ytdlp.is_installed():
            self._refresh_youtube_install_gate()
            return
        try:
            parsed = parse_youtube_url(url)
        except YoutubeUrlError as e:
            self.yt_status.setText(f"Not a YouTube URL: {e}")
            self.yt_status.set_kind("fail")
            self.yt_status.setVisible(True)
            self.yt_card.setVisible(False)
            self._yt_add_btn.setEnabled(False)
            return

        if parsed.kind == "video":
            # v1.2: video flow not yet supported in the Add dialog.
            self.yt_status.setText(
                "Adding single videos comes in a follow-up — please paste a channel URL for now."
            )
            self.yt_status.set_kind("fail")
            self._yt_add_btn.setEnabled(False)
            return

        # Initial status — the step signal will overwrite this almost
        # immediately, but seed it so the user sees motion before the
        # first emit reaches the GUI thread.
        self._yt_resolve_started_at = time.monotonic()
        self._yt_resolve_step_label = "Resolving channel ID…"
        self._yt_resolve_step_idx = (1, 2)
        self._refresh_yt_resolve_status()
        self.yt_status.set_kind("running")
        self.yt_status.setVisible(True)
        self.yt_progress.setVisible(True)
        self._yt_add_btn.setEnabled(False)
        self._yt_resolve_btn.setEnabled(False)
        self.youtube_url_input.setEnabled(False)

        # Off-thread: yt-dlp HTTP calls would otherwise block the GUI thread
        # and macOS would SIGTERM the unresponsive process.
        self._yt_resolve_thread = _YoutubeResolveThread(parsed.kind, parsed.value, self)
        self._yt_resolve_thread.step.connect(self._on_youtube_resolve_step)
        self._yt_resolve_thread.done.connect(self._on_youtube_resolve_done)
        self._yt_resolve_thread.start()

        # 1 Hz live-elapsed counter so the user sees the seconds tick by.
        self._yt_resolve_timer = QTimer(self)
        self._yt_resolve_timer.timeout.connect(self._refresh_yt_resolve_status)
        self._yt_resolve_timer.start(1000)

    def _on_youtube_resolve_step(self, current: int, total: int, label: str) -> None:
        self._yt_resolve_step_idx = (current, total)
        self._yt_resolve_step_label = label
        self._refresh_yt_resolve_status()

    def _refresh_yt_resolve_status(self) -> None:
        elapsed = int(time.monotonic() - self._yt_resolve_started_at)
        cur, total = self._yt_resolve_step_idx
        self.yt_status.setText(f"Step {cur}/{total}: {self._yt_resolve_step_label} ({elapsed}s)")

    def _on_youtube_resolve_done(self, out: dict) -> None:
        # Stop the elapsed-second ticker + hide the marquee.
        if getattr(self, "_yt_resolve_timer", None) is not None:
            self._yt_resolve_timer.stop()
            self._yt_resolve_timer = None
        self.yt_progress.setVisible(False)
        # Re-enable input/resolve regardless of outcome.
        self._yt_resolve_btn.setEnabled(True)
        self.youtube_url_input.setEnabled(True)
        if not out.get("ok"):
            self.yt_status.setText(f"Error: {out.get('error', 'unknown')}")
            self.yt_status.set_kind("fail")
            self._yt_add_btn.setEnabled(False)
            return
        preview = out["preview"]
        self._loaded_yt_preview = preview
        # New channel — drop any cached first-video date from a prior resolve.
        self._yt_first_video_date = ""
        if hasattr(self, "_yt_since_hint"):
            self._yt_since_hint.setText("defaults to the channel's first video")
        title = preview.get("title") or "(untitled)"
        self.yt_card_title.setText(title)
        # Default the slug to the channel name, but never clobber an edit the
        # user already made by hand.
        new_slug = slugify(title)
        cur = self._yt_slug_input.text().strip()
        if not cur or cur == getattr(self, "_yt_autoslug", ""):
            self._yt_slug_input.setText(new_slug)
        self._yt_autoslug = new_slug
        vc = preview.get("video_count") or 0
        suffix = "+ recent" if preview.get("video_count_is_lower_bound") else ""
        self.yt_card_meta.setText(
            f"{vc}{suffix} video(s) · channel id: {preview.get('channel_id', '')}"
        )
        # Auto-load the channel thumbnail off-thread (silent on failure).
        self.yt_card_thumb.setVisible(False)
        art = preview.get("artwork_url") or ""
        if art:
            worker = _CoverWorker(-1, art)
            worker.done.connect(self._on_yt_thumb_loaded)
            self._search_pool.start(worker)
        self.yt_card.setVisible(True)
        self.yt_status.setText("Ready")
        self.yt_status.set_kind("ok")
        self._yt_add_btn.setEnabled(True)

    def _on_yt_thumb_loaded(self, _row: int, pixmap: QPixmap) -> None:
        self.yt_card_thumb.setPixmap(pixmap)
        self.yt_card_thumb.setVisible(True)

    def _yt_backfill_choice(self) -> str:
        btn = self._yt_backfill_grp.checkedButton()
        return btn.text() if btn else "Only new"

    def _yt_since_date_iso(self) -> str | None:
        """Return the 'since' date as YYYY-MM-DD when active, else None."""
        if not self._yt_since_chk.isChecked():
            return None
        return self._yt_since_date.date().toString("yyyy-MM-dd")

    def _on_yt_since_toggled(self, checked: bool) -> None:
        """Enabling the 'since date' picker deselects the count radios and
        defaults the date to the channel's first upload (fetched lazily)."""
        self._yt_since_date.setEnabled(checked)
        if not checked:
            return
        self._yt_backfill_grp.setExclusive(False)
        for b in self._yt_backfill_grp.buttons():
            b.setChecked(False)
        self._yt_backfill_grp.setExclusive(True)
        # Default to the channel's first video. Use the cached date if we
        # already have it; otherwise fetch it in the background.
        self._yt_since_user_set = False
        if self._yt_first_video_date:
            self._apply_first_video_date(self._yt_first_video_date)
            return
        cid = (self._loaded_yt_preview or {}).get("channel_id") or ""
        if not cid:
            return
        if self._yt_first_video_thread is not None and self._yt_first_video_thread.isRunning():
            return
        self._yt_since_hint.setText("finding the channel's first video…")
        self._yt_first_video_thread = _YtFirstVideoThread(cid, self)
        self._yt_first_video_thread.done.connect(self._on_yt_first_video_date)
        self._yt_first_video_thread.start()

    def _on_yt_first_video_date(self, iso: str) -> None:
        self._yt_first_video_date = iso
        self._yt_since_hint.setText("defaults to the channel's first video")
        # Only override the field if the user hasn't picked a date themselves.
        if (
            iso
            and self._yt_since_chk.isChecked()
            and not getattr(self, "_yt_since_user_set", False)
        ):
            self._apply_first_video_date(iso)

    def _apply_first_video_date(self, iso: str) -> None:
        d = QDate.fromString(iso, "yyyy-MM-dd")
        if d.isValid():
            self._yt_since_date.blockSignals(True)
            self._yt_since_date.setDate(d)
            self._yt_since_date.blockSignals(False)

    def _on_yt_since_date_changed(self, _d) -> None:
        self._yt_since_user_set = True

    def _on_yt_radio_toggled(self, checked: bool) -> None:
        """Picking a count radio clears the 'since date' checkbox."""
        if not checked:
            return
        if self._yt_since_chk.isChecked():
            self._yt_since_chk.blockSignals(True)
            self._yt_since_chk.setChecked(False)
            self._yt_since_date.setEnabled(False)
            self._yt_since_chk.blockSignals(False)

    def _add_from_youtube(self) -> None:
        """Validate the selection, then kick off the (slow) channel
        enumeration on a worker thread. The save itself happens later in
        ``_on_yt_enumerate_done`` once the worker returns."""
        preview = self._loaded_yt_preview
        if not preview:
            QMessageBox.warning(self, "Missing", "Resolve a channel URL first.")
            return
        title = preview.get("title") or "channel"
        cid = preview.get("channel_id") or ""
        if not cid:
            QMessageBox.warning(self, "Missing", "Could not determine channel id.")
            return
        slug = self._yt_slug_input.text().strip() or slugify(title)

        # Decide enumeration depth. A "since" date overrides the count radios
        # (mutually exclusive in the UI): fetch everything and filter by date.
        since_iso = self._yt_since_date_iso()
        choice = self._yt_backfill_choice()

        if since_iso is not None:
            limit = None  # fetch all; client-side date filter below
        elif choice == "Last 100":
            limit = 100
        elif choice == "Last 20":
            limit = 20
        elif choice == "Last 5":
            limit = 5
        else:  # "Only new" — seed the current feed window as a done baseline
            # so only genuinely new uploads transcribe. The channel Atom feed
            # returns ~15 entries; 30 covers it with margin.
            limit = 30

        # Stash the prep so the worker's done handler can finish the save.
        self._yt_pending = {
            "title": title,
            "cid": cid,
            "slug": slug,
            "since_iso": since_iso,
            "choice": choice,
            "preview": preview,
        }

        # Indeterminate progress + Cancel; disable Add while the (potentially
        # many-second) yt-dlp enumeration runs off the GUI thread so the app
        # stays responsive.
        self._yt_enumerating = True
        self.yt_progress.setVisible(True)
        self._yt_enum_cancel_btn.setVisible(True)
        self._yt_add_btn.setEnabled(False)

        self._yt_enumerate_thread = _YoutubeEnumerateThread(cid, limit, self)
        self._yt_enumerate_thread.done.connect(self._on_yt_enumerate_done)
        self._yt_enumerate_thread.error.connect(self._on_yt_enumerate_error)
        self._yt_enumerate_thread.start()

    def _teardown_yt_enumerate_ui(self) -> None:
        """Hide the progress/cancel affordances and re-enable Add."""
        self._yt_enumerating = False
        self.yt_progress.setVisible(False)
        self._yt_enum_cancel_btn.setVisible(False)
        self._yt_add_btn.setEnabled(True)

    def _cancel_yt_enumerate(self) -> None:
        """Abandon an in-flight enumeration. ``enumerate_channel_videos`` is a
        blocking subprocess that can't be cleanly interrupted mid-flight, so we
        request interruption, disconnect the result slots (a late result is
        ignored), drop our reference (the thread stays alive via its Qt parent),
        and restore the UI."""
        t = self._yt_enumerate_thread
        if t is not None:
            try:
                t.requestInterruption()
                t.done.disconnect(self._on_yt_enumerate_done)
                t.error.disconnect(self._on_yt_enumerate_error)
            except (TypeError, RuntimeError):
                pass
            self._yt_enumerate_thread = None
        self._teardown_yt_enumerate_ui()

    def _on_yt_enumerate_error(self, msg: str) -> None:
        self._teardown_yt_enumerate_ui()
        QMessageBox.warning(self, "Error", f"Failed to enumerate videos: {msg}")

    def _on_yt_enumerate_done(self, videos: list) -> None:
        """Build the manifest from the enumerated videos and save the show.

        Empty enumeration → "No videos" info, no save. The since-date filter
        can also empty the manifest even when ``videos`` was non-empty; that
        too surfaces the info dialog and saves nothing."""
        self._teardown_yt_enumerate_ui()
        if not videos:
            QMessageBox.information(self, "No videos", "0 videos match this selection.")
            return

        pending = self._yt_pending or {}
        title = pending.get("title") or "channel"
        cid = pending.get("cid") or ""
        slug = pending.get("slug") or ""
        since_iso = pending.get("since_iso")
        choice = pending.get("choice") or "Only new"
        preview = pending.get("preview") or {}

        # Build a manifest the existing _do_save funnel understands.
        # Date sourcing: yt-dlp --flat-playlist returns `timestamp`
        # (Unix epoch seconds), not `upload_date`. Convert to ISO so
        # build_slug doesn't fall back to 1970-01-01 in the filename.
        import time as _time

        manifest = []
        for v in videos:
            vid = v.get("id") or v.get("url") or ""
            if not vid:
                continue
            ts = v.get("timestamp") or 0
            pub = ""
            if ts:
                pub = _time.strftime("%Y-%m-%d", _time.gmtime(int(ts)))
            elif v.get("upload_date"):
                # Some yt-dlp paths emit YYYYMMDD instead — normalise.
                ud = str(v["upload_date"])
                if len(ud) == 8 and ud.isdigit():
                    pub = f"{ud[:4]}-{ud[4:6]}-{ud[6:8]}"
                else:
                    pub = ud
            manifest.append(
                {
                    "guid": vid,
                    "title": v.get("title") or vid,
                    "pubDate": pub,
                    # YouTube videos have no MP3 enclosure — point at the
                    # watch URL; the YouTube pipeline branch resolves the
                    # actual source (captions or audio) itself.
                    "mp3_url": f"https://www.youtube.com/watch?v={vid}",
                }
            )

        # A "since" date keeps only videos published on/after the cutoff
        # (ISO date strings compare lexicographically). Unknown-date videos
        # are dropped to avoid silently dragging in the whole back-catalogue.
        if since_iso is not None:
            manifest = [m for m in manifest if m["pubDate"] and m["pubDate"] >= since_iso]

        # The since-date filter (or videos with no usable id) can empty the
        # manifest even though enumeration returned entries — never save an
        # empty show; surface the same "no videos" notice instead.
        if not manifest:
            QMessageBox.information(self, "No videos", "0 videos match this selection.")
            return

        # Backlog mode controls which seeded items transcribe. "Only new"
        # marks the entire seeded baseline done so only future uploads run;
        # every other choice keeps the seeded videos pending. The "since"
        # filter already trimmed the manifest, so its remainder stays pending.
        if choice == "Only new" and since_iso is None:
            backlog_mode = "Only new"
        else:
            backlog_mode = "All"

        # Caption preference: checked → import uploader subtitles per video
        # (manual only; whisper fallback). Unchecked → always whisper. Auto-
        # generated captions are never used by either path.
        transcript_pref = "captions" if self._yt_captions_chk.isChecked() else "whisper"

        show_dict = {
            "slug": slug,
            "title": title,
            "rss": rss_url_for_channel_id(cid),
            "whisper_prompt": "",
            "manifest": manifest,
            "backlog": backlog_mode,
            "artwork_url": preview.get("artwork_url", "") or "",
            "source": "youtube",
            "youtube_transcript_pref": transcript_pref,
            # User-picked from the dropdown above (seeded from the
            # YouTube default language in Settings). Used as lang code
            # for caption fetch + whisper-cli fallback.
            "language": self._yt_lang_combo.currentData() or "de",
        }
        self._do_save(show_dict)

    # ------------------------------------------------------------------ #
    # Save funnel — logic preserved from the pre-rewrite dialog          #
    # ------------------------------------------------------------------ #

    def _do_save(self, show: dict) -> None:
        slug = (show.get("slug") or "").strip()
        if not slug:
            QMessageBox.warning(self, "Missing", "Slug required.")
            return
        if any(s.slug == slug for s in self.updated_watchlist.shows):
            QMessageBox.warning(self, "Exists", f"{slug!r} is already in the watchlist.")
            return
        rss = (show.get("rss") or "").strip()
        if not rss:
            QMessageBox.warning(self, "Missing", "RSS URL required.")
            return

        # Honour show["language"] if the caller passed one (the YouTube
        # path forces "en"); fall back to the model default ("de") for
        # podcast modes, which is what existing users expect.
        _lang = (show.get("language") or "").strip()
        model_kwargs = dict(
            slug=slug,
            title=(show.get("title") or "").strip() or slug,
            rss=rss,
            whisper_prompt=(show.get("whisper_prompt") or "").strip(),
            artwork_url=(show.get("artwork_url") or "").strip(),
            source=(show.get("source") or "podcast"),
        )
        if _lang:
            model_kwargs["language"] = _lang
        _pref = (show.get("youtube_transcript_pref") or "").strip()
        if _pref:
            model_kwargs["youtube_transcript_pref"] = _pref
        model = Show(**model_kwargs)
        self.updated_watchlist.shows.append(model)
        save_watchlist(self.ctx)

        # Seed episodes in state; handle backlog strategy.
        manifest = show.get("manifest") or []
        for ep in manifest:
            self.ctx.state.upsert_episode(
                show_slug=slug,
                guid=ep["guid"],
                title=ep["title"],
                pub_date=ep["pubDate"],
                mp3_url=ep["mp3_url"],
            )

        mode = show.get("backlog") or "Last 5"
        if mode == "Only new":
            # Baseline mode (YouTube "Only new"): mark every seeded video done
            # so the back-catalogue is skipped and only future uploads — new
            # entries the feed poll discovers later — get transcribed.
            with self.ctx.state._conn() as c:
                c.execute("UPDATE episodes SET status='done' WHERE show_slug=?", (slug,))
        elif mode == "All":
            pass  # leave everything pending
        elif mode == "Most recent":
            # Keep only the latest 1 pending; mark older as done.
            with self.ctx.state._conn() as c:
                c.execute(
                    """
                    UPDATE episodes SET status='done'
                    WHERE show_slug=? AND guid NOT IN (
                        SELECT guid FROM episodes WHERE show_slug=?
                        ORDER BY pub_date DESC LIMIT 1
                    )""",
                    (slug, slug),
                )
        elif mode.startswith("Last "):
            n = int(mode.split()[1])
            with self.ctx.state._conn() as c:
                c.execute(
                    """
                    UPDATE episodes SET status='done'
                    WHERE show_slug=? AND guid NOT IN (
                        SELECT guid FROM episodes WHERE show_slug=?
                        ORDER BY pub_date DESC LIMIT ?
                    )""",
                    (slug, slug, n),
                )
        elif mode.startswith("Time:"):
            # Mark every episode older than the cutoff as done. Pub-date
            # format varies across feeds (RFC 2822, ISO 8601, YouTube
            # YYYYMMDD); parse defensively in Python and update by guid.
            from datetime import datetime, timedelta, timezone
            from email.utils import parsedate_to_datetime

            days = int(mode.split(":", 1)[1])
            cutoff = datetime.now(timezone.utc) - timedelta(days=days)

            def _parse(pd: str) -> datetime | None:
                if not pd:
                    return None
                try:
                    dt = parsedate_to_datetime(pd)
                    if dt is not None:
                        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
                except (TypeError, ValueError):
                    pass
                try:
                    return datetime.fromisoformat(pd.replace("Z", "+00:00"))
                except ValueError:
                    pass
                if len(pd) == 8 and pd.isdigit():  # YouTube YYYYMMDD
                    try:
                        return datetime.strptime(pd, "%Y%m%d").replace(tzinfo=timezone.utc)
                    except ValueError:
                        pass
                return None

            stale_guids = [
                ep["guid"] for ep in manifest if (_parse(ep.get("pubDate", "")) or cutoff) < cutoff
            ]
            if stale_guids:
                with self.ctx.state._conn() as c:
                    placeholders = ",".join("?" for _ in stale_guids)
                    c.execute(
                        f"UPDATE episodes SET status='done' "
                        f"WHERE show_slug=? AND guid IN ({placeholders})",
                        (slug, *stale_guids),
                    )

        # A GUI add IS a backlog decision (we seeded episodes + applied the
        # strategy above), so mark the show decided — otherwise the worker's
        # per-show gate would wrongly skip it. Mirrors the blessed CLI
        # `paragraphos add`, which sets the same marker.
        from core.watchlist_guard import mark_decided

        mark_decided(self.ctx.state, slug)

        self.accept()
