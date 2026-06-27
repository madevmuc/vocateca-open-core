"""Library tab — browse all completed transcripts.

Three-panel splitter:
  • shows tree (left)
  • episode list (middle)
  • markdown preview (right)

Reads `state.episodes WHERE status='done'`. Episodes whose on-disk
.md is missing are filtered out. No schema changes.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from PyQt6.QtCore import QSettings, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QAction, QGuiApplication
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QMessageBox,
    QPushButton,
    QSplitter,
    QTableWidget,
    QTableWidgetItem,
    QTextBrowser,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from core import macopen

# Read at most the first 500 KB of large transcripts to keep the
# QTextBrowser snappy. Files above this threshold get a banner note.
_PREVIEW_HARD_LIMIT_BYTES = 5 * 1024 * 1024
_PREVIEW_SOFT_LIMIT_BYTES = 500 * 1024

# Pseudo-show id used by the tree root for "All episodes".
_ALL_KEY = "__all__"


class LibraryTab(QWidget):
    """Browse-only library page. Read-only by design."""

    current_episode_changed = pyqtSignal(object)  # guid: str | None

    def __init__(self, ctx):
        super().__init__()
        self.ctx = ctx
        self._rows: list[dict] = []
        self._filtered: list[dict] = []
        self._selected_show: str = _ALL_KEY  # tree-driven filter
        self._current_guid: Optional[str] = None

        self._splitter = QSplitter(Qt.Orientation.Horizontal, self)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(self._splitter)

        # ── Panel 1 — tree ────────────────────────────────────────
        self.tree = QTreeWidget()
        self.tree.setHeaderHidden(True)
        self.tree.setRootIsDecorated(False)
        self.tree.itemSelectionChanged.connect(self._on_tree_select)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._on_tree_context_menu)
        self._splitter.addWidget(self.tree)

        # ── Panel 2 — list ───────────────────────────────────────
        list_panel = QWidget()
        lp = QVBoxLayout(list_panel)
        lp.setContentsMargins(0, 0, 0, 0)
        self.filter_edit = QLineEdit()
        self.filter_edit.setPlaceholderText("Filter…")
        self.filter_edit.textChanged.connect(self._on_filter_text)
        self._filter_debounce = QTimer(self)
        self._filter_debounce.setSingleShot(True)
        self._filter_debounce.setInterval(250)
        self._filter_debounce.timeout.connect(self._apply_filter)
        lp.addWidget(self.filter_edit)
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Date", "Title", "Source", "Show"])
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.verticalHeader().setVisible(False)
        hdr = self.table.horizontalHeader()
        hdr.setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        hdr.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        hdr.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        hdr.setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.table.itemSelectionChanged.connect(self._on_row_select)
        self.table.itemDoubleClicked.connect(self._on_row_double_click)
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._on_row_context_menu)
        # Click-to-sort. _populate_table disables sorting during the
        # bulk insert and re-enables after.
        self.table.setSortingEnabled(True)
        hdr.setSortIndicatorShown(True)
        lp.addWidget(self.table)

        from ui.widgets.empty_state import EmptyState

        self.empty_state = EmptyState(
            title="No transcripts yet",
            hint="They'll appear here after the first run completes.",
        )
        lp.addWidget(self.empty_state)
        self.empty_state.setVisible(False)
        self._splitter.addWidget(list_panel)

        # ── Panel 3 — preview ─────────────────────────────────────
        preview_panel = QWidget()
        pp = QVBoxLayout(preview_panel)
        pp.setContentsMargins(8, 8, 8, 8)
        # Header strip
        header = QWidget()
        hl = QVBoxLayout(header)
        hl.setContentsMargins(0, 0, 0, 6)
        self.preview_title = QLabel("")
        f = self.preview_title.font()
        f.setPointSize(f.pointSize() + 4)
        f.setBold(True)
        self.preview_title.setFont(f)
        self.preview_title.setWordWrap(True)
        self.preview_subtitle = QLabel("")
        self.preview_subtitle.setStyleSheet("color: palette(mid);")
        self.preview_subtitle.setWordWrap(True)
        hl.addWidget(self.preview_title)
        hl.addWidget(self.preview_subtitle)
        # Action buttons
        btn_row = QHBoxLayout()
        btn_row.setContentsMargins(0, 0, 0, 0)
        self.btn_open_md = QPushButton("Open .md")
        self.btn_reveal = QPushButton("Reveal in Finder")
        self.btn_open_with = QPushButton("Open With…")
        for b in (self.btn_open_md, self.btn_reveal, self.btn_open_with):
            b.setEnabled(False)
        self.btn_open_md.clicked.connect(self._action_open_md)
        self.btn_reveal.clicked.connect(self._action_reveal)
        self.btn_open_with.clicked.connect(self._action_open_with)
        btn_row.addStretch()
        btn_row.addWidget(self.btn_open_md)
        btn_row.addWidget(self.btn_reveal)
        btn_row.addWidget(self.btn_open_with)
        hl.addLayout(btn_row)
        pp.addWidget(header)

        self.preview = QTextBrowser()
        self.preview.setOpenExternalLinks(True)
        self._set_empty_preview()
        pp.addWidget(self.preview, stretch=1)
        self._splitter.addWidget(preview_panel)

        # Splitter sizes — restored from QSettings; sensible default.
        self._restore_splitter()
        # Right-click on the splitter handle → reset widths.
        for i in range(1, self._splitter.count()):
            handle = self._splitter.handle(i)
            handle.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
            handle.customContextMenuRequested.connect(
                lambda _pos, h=handle: self._on_handle_context(h)
            )
        self._splitter.splitterMoved.connect(self._save_splitter)

        # Debounced auto-refresh. Wired by ShowsTab to fire once after
        # 1 s of quiet following the last episode_done — avoids
        # rebuilding the tree N times during a check pass that finishes
        # 50 episodes in a burst, while still landing the new rows
        # before the user clicks back to Library. Pre-2026-05-04 the
        # tab was scanned ONCE on construction and never again, so a
        # session that ran for hours showed a static snapshot.
        self._auto_refresh_timer = QTimer(self)
        self._auto_refresh_timer.setSingleShot(True)
        self._auto_refresh_timer.setInterval(1000)
        self._auto_refresh_timer.timeout.connect(self.refresh)

        # Initial build.
        self.refresh()

    # ── Public refresh ───────────────────────────────────────────
    def refresh(self) -> None:
        """Reload episode list from state DB + filesystem."""
        self._load()

    # ── Auto-refresh hooks ───────────────────────────────────────
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
        """Slot wired in MainWindow to the worker's episode_done signal.
        Restarts the debounce timer; refresh fires 1 s after the last
        signal in a burst. Reuses the same 7-tuple shape as
        QueueTab.on_episode_done so ShowsTab's existing forwarder can
        connect to either consumer interchangeably.

        ``MainWindow._on_nav`` separately calls ``refresh()`` whenever
        the user clicks back into the Library tab — so even if the
        auto-refresh ever misses (signal dropped, timer paused while
        the window was hidden), navigation always reconciles state."""
        if action == "transcribed":
            self._auto_refresh_timer.start()

    # ── Data loading ─────────────────────────────────────────────
    def _load(self) -> None:
        rows: list[dict] = []
        try:
            with self.ctx.state._conn() as c:
                cur = c.execute(
                    "SELECT guid, show_slug, title, pub_date, duration_sec, "
                    "completed_at FROM episodes WHERE status='done' "
                    "ORDER BY pub_date DESC"
                )
                fetched = list(cur)
        except Exception:
            fetched = []
        for row in fetched:
            d = dict(row)
            md_path = self._resolve_md_path(
                d["show_slug"], d.get("pub_date") or "", d.get("title") or ""
            )
            if md_path is None or not md_path.exists():
                continue
            d["md_path"] = md_path
            rows.append(d)
        self._rows = rows
        self._build_tree()
        self._apply_filter()

    def _resolve_md_path(self, show_slug: str, pub_date: str, title: str) -> Optional[Path]:
        """Find the on-disk .md for an episode.

        Two paths to a hit, in order:

        1. Construct the canonical path the pipeline would have
           written (``<output_root>/<slug>/<date>_0000_<title>.md``)
           and stat it. Cheap; covers shows that genuinely have
           ``episode_number=0000`` in their slug.

        2. If that misses, glob the show dir for
           ``<YYYY-MM-DD>_*<title-fragment>*.md``. Same conservative
           rules as ``core.pipeline._find_existing_audio``: title
           prefix scope, ambiguous → most recently modified, refuses
           to fall through to a date-only match. Catches the slug-
           drift case where the transcript was written under the real
           ``episode_number`` (e.g. ``_0314_``) but the Library row
           has none.

           Pre-2026-05-04 the Library skipped step 2 and silently
           dropped every transcript whose filename used a non-zero
           episode number — most recent episodes vanished from the
           tree even though state and disk both had them.
        """
        from core.pipeline import build_slug
        from core.sanitize import sanitize_filename

        show_dir = Path(self.ctx.settings.output_root).expanduser() / show_slug
        slug = build_slug(pub_date, title, "0000")
        canonical = show_dir / f"{slug}.md"
        if canonical.exists():
            return canonical
        if not show_dir.is_dir():
            return None
        date_prefix = (pub_date or "")[:10]
        if not date_prefix:
            return None
        title_part = sanitize_filename(title or "", max_bytes=120)[:20]
        if not title_part:
            return None
        candidates = [
            p for p in show_dir.glob(f"{date_prefix}_*.md") if p.is_file() and title_part in p.name
        ]
        if not candidates:
            return None
        if len(candidates) == 1:
            return candidates[0]
        # Ambiguous: same date + title prefix but different episode
        # numbers (rare). Prefer the most recently modified.
        return max(candidates, key=lambda p: p.stat().st_mtime_ns)

    # ── Show metadata ────────────────────────────────────────────
    def _show_meta(self, slug: str) -> tuple[str, str]:
        """Return (title, source) for a show slug; falls back to slug
        when watchlist has no entry (e.g., show was deleted but
        transcripts remain on disk)."""
        wl = getattr(self.ctx, "watchlist", None)
        if wl is not None:
            for s in getattr(wl, "shows", []):
                if s.slug == slug:
                    return (s.title or slug, s.source or "podcast")
        return (slug, "podcast")

    @staticmethod
    def _source_glyph(source: str) -> str:
        # 📺 TV for YouTube (better mental model than the play-triangle —
        # the user reads the tree as 'what kind of show is this'); 🎙 mic
        # stays for podcasts.
        return "📺" if source == "youtube" else "🎙"

    # ── Tree ─────────────────────────────────────────────────────
    def _build_tree(self) -> None:
        self.tree.blockSignals(True)
        try:
            self.tree.clear()
            all_node = QTreeWidgetItem([f"All episodes ({len(self._rows)})"])
            all_node.setData(0, Qt.ItemDataRole.UserRole, _ALL_KEY)
            self.tree.addTopLevelItem(all_node)

            # Group by slug, sorted by show title (alphabetical).
            by_slug: dict[str, int] = {}
            for r in self._rows:
                by_slug[r["show_slug"]] = by_slug.get(r["show_slug"], 0) + 1
            entries = []
            for slug, n in by_slug.items():
                title, source = self._show_meta(slug)
                entries.append((title.lower(), title, slug, source, n))
            entries.sort()
            for _key, title, slug, source, n in entries:
                glyph = self._source_glyph(source)
                node = QTreeWidgetItem([f"{glyph} {title} ({n})"])
                node.setData(0, Qt.ItemDataRole.UserRole, slug)
                self.tree.addTopLevelItem(node)

            # Re-apply selection.
            self._select_tree_key(self._selected_show)
        finally:
            self.tree.blockSignals(False)

    def _select_tree_key(self, key: str) -> None:
        for i in range(self.tree.topLevelItemCount()):
            item = self.tree.topLevelItem(i)
            if item.data(0, Qt.ItemDataRole.UserRole) == key:
                item.setSelected(True)
                self.tree.setCurrentItem(item)
                return
        # Fall back to "All episodes" if the previously-selected show
        # disappeared.
        if self.tree.topLevelItemCount():
            first = self.tree.topLevelItem(0)
            first.setSelected(True)
            self.tree.setCurrentItem(first)
            self._selected_show = _ALL_KEY

    def _on_tree_select(self) -> None:
        items = self.tree.selectedItems()
        if not items:
            return
        key = items[0].data(0, Qt.ItemDataRole.UserRole) or _ALL_KEY
        self._selected_show = str(key)
        self._apply_filter()

    # ── Filter / table population ────────────────────────────────
    def _on_filter_text(self, _txt: str) -> None:
        self._filter_debounce.start()

    def _apply_filter(self) -> None:
        needle = self.filter_edit.text().strip().lower()
        rows = []
        for r in self._rows:
            if self._selected_show != _ALL_KEY and r["show_slug"] != self._selected_show:
                continue
            if needle and needle not in (r.get("title") or "").lower():
                continue
            rows.append(r)
        self._filtered = rows
        self._populate_table()

    def _populate_table(self) -> None:
        # Sorting must be off during repopulation — Qt re-sorts on every
        # setItem when enabled, scrambling row indices and leaving cells
        # past column 0 empty. Restore at the end.
        was_sorting = self.table.isSortingEnabled()
        self.table.setSortingEnabled(False)
        self.table.setRowCount(0)
        # Hide the Show column when a specific show is selected — same
        # info would just repeat per row.
        self.table.setColumnHidden(3, self._selected_show != _ALL_KEY)
        for r in self._filtered:
            row = self.table.rowCount()
            self.table.insertRow(row)
            date_item = QTableWidgetItem((r.get("pub_date") or "")[:10])
            title_item = QTableWidgetItem(r.get("title") or "")
            show_title, source = self._show_meta(r["show_slug"])
            source_item = QTableWidgetItem(self._source_glyph(source))
            source_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            show_item = QTableWidgetItem(show_title)
            # Stash the guid on the date cell — handy for context-menu lookup.
            date_item.setData(Qt.ItemDataRole.UserRole, r["guid"])
            for col, item in enumerate((date_item, title_item, source_item, show_item)):
                self.table.setItem(row, col, item)
        # Clear preview if the previously-selected guid is gone.
        guids_visible = {r["guid"] for r in self._filtered}
        if self._current_guid and self._current_guid not in guids_visible:
            self._current_guid = None
            self._set_empty_preview()
            self._set_action_buttons_enabled(False)
        # Restore click-to-sort after the bulk insertion completes.
        self.table.setSortingEnabled(was_sorting)
        empty = self.table.rowCount() == 0
        self.empty_state.setVisible(empty)
        self.table.setVisible(not empty)
        # Auto-select the top row (most recent episode by pub_date DESC)
        # when nothing is currently selected. Gives the user an immediate
        # preview when they switch shows, instead of an empty right pane.
        if self.table.rowCount() > 0 and not self.table.selectedItems():
            self.table.selectRow(0)

    # ── Selection → preview ──────────────────────────────────────
    def _on_row_select(self) -> None:
        guid = self._current_row_guid()
        if guid is None:
            self._current_guid = None
            self._set_empty_preview()
            self._set_action_buttons_enabled(False)
            self.current_episode_changed.emit(None)
            return
        self._current_guid = guid
        self._render_preview(guid)
        self._set_action_buttons_enabled(True)
        self.current_episode_changed.emit(guid)

    def _current_row_guid(self) -> Optional[str]:
        sel = self.table.selectionModel()
        if sel is None:
            return None
        rows = sel.selectedRows()
        if not rows:
            return None
        item = self.table.item(rows[0].row(), 0)
        if item is None:
            return None
        return item.data(Qt.ItemDataRole.UserRole)

    def _row_for_guid(self, guid: str) -> Optional[dict]:
        for r in self._rows:
            if r["guid"] == guid:
                return r
        return None

    def _render_preview(self, guid: str) -> None:
        r = self._row_for_guid(guid)
        if r is None:
            self._set_empty_preview()
            return
        show_title, source = self._show_meta(r["show_slug"])
        self.preview_title.setText(r.get("title") or "")
        pill = "📺 YouTube" if source == "youtube" else "🎙 Podcast"
        self.preview_subtitle.setText(f"{show_title} · {(r.get('pub_date') or '')[:10]} · {pill}")
        md_path: Path = r["md_path"]
        try:
            size = md_path.stat().st_size
        except OSError:
            size = 0
        truncated = False
        try:
            if size > _PREVIEW_HARD_LIMIT_BYTES:
                with md_path.open("r", encoding="utf-8", errors="ignore") as fh:
                    text = fh.read(_PREVIEW_SOFT_LIMIT_BYTES)
                truncated = True
            else:
                text = md_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            text = ""
        if truncated:
            text = "> _Transcript is large — preview truncated._\n\n" + text
        self.preview.setMarkdown(text)

    def _set_empty_preview(self) -> None:
        self.preview_title.setText("")
        self.preview_subtitle.setText("")
        self.preview.setMarkdown("*Select an episode on the left.*")

    def _set_action_buttons_enabled(self, enabled: bool) -> None:
        for b in (self.btn_open_md, self.btn_reveal, self.btn_open_with):
            b.setEnabled(enabled)

    # ── Action button handlers ───────────────────────────────────
    def _current_md(self) -> Optional[Path]:
        if self._current_guid is None:
            return None
        r = self._row_for_guid(self._current_guid)
        return r["md_path"] if r else None

    def _action_open_md(self) -> None:
        p = self._current_md()
        if p is not None:
            macopen.open_default(p)

    def _action_reveal(self) -> None:
        p = self._current_md()
        if p is not None:
            macopen.reveal_in_finder(p)

    def _action_open_with(self) -> None:
        p = self._current_md()
        if p is not None:
            macopen.open_with_chooser(p)

    # ── Row interactions ─────────────────────────────────────────
    def _on_row_double_click(self, _item: QTableWidgetItem) -> None:
        p = self._current_md()
        if p is not None:
            macopen.open_default(p)

    def _on_row_context_menu(self, pos) -> None:
        guid = self._current_row_guid()
        if guid is None:
            return
        r = self._row_for_guid(guid)
        if r is None:
            return
        md: Path = r["md_path"]
        srt = md.with_suffix(".srt")
        srt_exists = srt.exists()

        menu = QMenu(self)
        a_open_md = QAction("Open transcript (.md)", self)
        a_open_md.triggered.connect(lambda: macopen.open_default(md))
        menu.addAction(a_open_md)

        a_open_srt = QAction("Open subtitles (.srt)", self)
        a_open_srt.setEnabled(srt_exists)
        if srt_exists:
            a_open_srt.triggered.connect(lambda: macopen.open_default(srt))
        menu.addAction(a_open_srt)

        a_reveal = QAction("Reveal in Finder", self)
        a_reveal.triggered.connect(lambda: macopen.reveal_in_finder(md))
        menu.addAction(a_reveal)

        a_with = QAction("Open With…", self)
        a_with.triggered.connect(lambda: macopen.open_with_chooser(md))
        menu.addAction(a_with)

        menu.addSeparator()

        a_copy_path = QAction("Copy file path", self)
        a_copy_path.triggered.connect(lambda: self._copy_to_clipboard(str(md)))
        menu.addAction(a_copy_path)

        a_copy_slug = QAction("Copy show slug", self)
        a_copy_slug.triggered.connect(lambda: self._copy_to_clipboard(r["show_slug"]))
        menu.addAction(a_copy_slug)

        menu.addSeparator()

        a_retr = QAction("Re-transcribe this episode", self)
        a_retr.triggered.connect(lambda: self._do_retranscribe(guid))
        menu.addAction(a_retr)

        a_timeline = QAction("Show timeline…", self)
        a_timeline.triggered.connect(lambda: self._show_timeline(guid))
        menu.addAction(a_timeline)

        menu.addSeparator()
        a_del = QAction("Delete transcript…", self)
        a_del.triggered.connect(lambda: self._delete_transcript(guid))
        menu.addAction(a_del)

        menu.exec(self.table.viewport().mapToGlobal(pos))

    def _do_retranscribe(self, guid: str) -> None:
        from ui.retranscribe import retranscribe_episode

        retranscribe_episode(self.ctx, guid)
        self.refresh()

    def _show_timeline(self, guid: str) -> None:
        """Read-only per-episode phase timeline from the events table (7.2)."""
        from core.timeline import format_timeline

        events = self.ctx.state.query_events(guid=guid)
        QMessageBox.information(self, "Episode timeline", format_timeline(events))

    # --- Tree (folder) context menu + deletions --------------------------

    def _on_tree_context_menu(self, pos) -> None:
        item = self.tree.itemAt(pos)
        if item is None:
            return
        slug = item.data(0, Qt.ItemDataRole.UserRole)
        if not slug or slug == _ALL_KEY:
            return  # the "All episodes" node has no folder of its own
        folder = Path(self.ctx.settings.output_root).expanduser() / slug
        menu = QMenu(self)
        a_reveal = QAction("Reveal folder in Finder", self)
        a_reveal.setEnabled(folder.is_dir())
        a_reveal.triggered.connect(lambda: macopen.reveal_in_finder(folder))
        menu.addAction(a_reveal)
        menu.addSeparator()
        a_del = QAction("Delete folder (all transcripts)…", self)
        a_del.setEnabled(folder.is_dir())
        # NB: QAction.triggered emits a `checked` bool — capture slug via the
        # enclosing scope (no default arg) so the bool can't shadow it.
        a_del.triggered.connect(lambda: self._delete_show_folder(slug))
        menu.addAction(a_del)
        menu.exec(self.tree.viewport().mapToGlobal(pos))

    def _confirm_once(self, title: str, text: str) -> bool:
        """A single Abort/Confirm prompt — Abort is the default (pre-selected)
        button, so a stray Return/Escape cancels rather than deletes."""
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Warning)
        box.setWindowTitle(title)
        box.setText(text)
        abort = box.addButton("Abort", QMessageBox.ButtonRole.RejectRole)
        confirm = box.addButton("Confirm", QMessageBox.ButtonRole.AcceptRole)
        box.setDefaultButton(abort)
        box.setEscapeButton(abort)
        box.exec()
        return box.clickedButton() is confirm

    def _confirm_delete(self, title: str, body: str, second: str) -> bool:
        """Two-step confirmation — a deliberate guard for irreversible deletes:
        proceeds only when the user clicks Confirm on BOTH prompts."""
        return self._confirm_once(title, body) and self._confirm_once("Final confirmation", second)

    def _delete_transcript(self, guid: str) -> None:
        r = self._row_for_guid(guid)
        if r is None:
            return
        md: Path = r["md_path"]
        files = [p for p in (md, md.with_suffix(".srt")) if p.exists()]
        if not files:
            return
        names = "\n".join(f"  • {p.name}" for p in files)
        if not self._confirm_delete(
            "Delete transcript",
            f"Permanently delete this episode's transcript file(s)?\n\n{names}\n\n"
            "This cannot be undone.",
            f"Really delete {len(files)} file(s)? This is final.",
        ):
            return
        # Soft-delete: move to trash so the action is undoable (9.5) rather than
        # an irreversible unlink. Each file's restore is captured for undo.
        from ui.undo import manager as undo_manager
        from ui.undo import trash_file

        restores = []
        for p in files:
            try:
                restores.append(trash_file(p, data_dir=self.ctx.data_dir))
            except OSError:
                pass

        def _undo() -> None:
            for restore in restores:
                try:
                    restore()
                except OSError:
                    pass
            self.refresh()

        undo_manager.push(f"Deleted transcript: {md.name}", _undo)
        from ui.activity_log import log as log_activity

        log_activity(f"Deleted transcript: {md.name} — Undo available (⌘Z, 60s)")
        self.refresh()

    def _delete_show_folder(self, slug: str) -> None:
        import shutil

        output_root = Path(self.ctx.settings.output_root).expanduser().resolve()
        folder = (output_root / slug).resolve()
        # Safety: refuse to delete the output root itself or anything outside it.
        if not slug or folder == output_root or output_root not in folder.parents:
            return
        if not folder.is_dir():
            return
        n_md = len(list(folder.glob("*.md")))
        if not self._confirm_delete(
            "Delete folder",
            f"Permanently delete the entire transcript folder for {slug!r}?\n\n"
            f"{folder}\n\n"
            f"This removes {n_md} transcript(s) and everything else inside it. "
            "This cannot be undone.",
            f"Really delete the folder and its {n_md} transcript(s)? This is final.",
        ):
            return
        try:
            shutil.rmtree(folder)
        except OSError as e:
            QMessageBox.warning(self, "Delete failed", str(e))
            return
        from ui.activity_log import log as log_activity

        log_activity(f"Deleted folder '{slug}' ({n_md} transcript(s))")
        self.refresh()

    @staticmethod
    def _copy_to_clipboard(text: str) -> None:
        cb = QGuiApplication.clipboard()
        if cb is not None:
            cb.setText(text)

    # ── Splitter persistence ─────────────────────────────────────
    def _qsettings(self) -> QSettings:
        return QSettings("madevmuc", "Paragraphos")

    def _restore_splitter(self) -> None:
        sizes = self._qsettings().value("library/splitter")
        applied = False
        if isinstance(sizes, list) and sizes:
            try:
                ints = [int(x) for x in sizes]
                if len(ints) == self._splitter.count() and all(v >= 0 for v in ints):
                    self._splitter.setSizes(ints)
                    applied = True
            except (TypeError, ValueError):
                applied = False
        if not applied:
            self._splitter.setSizes([200, 420, 600])

    def _save_splitter(self, *_args) -> None:
        self._qsettings().setValue("library/splitter", self._splitter.sizes())

    def _on_handle_context(self, handle) -> None:
        menu = QMenu(self)
        act = QAction("Reset panel widths", self)
        act.triggered.connect(self._reset_splitter)
        menu.addAction(act)
        menu.exec(handle.mapToGlobal(handle.rect().center()))

    def _reset_splitter(self) -> None:
        self._splitter.setSizes([200, 420, 600])
        self._save_splitter()
