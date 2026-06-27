"""Full macOS menu bar: File / Edit / View / Actions / Window / Help.

Bound to MainWindow methods. Actions that map to existing buttons (Check Now,
Stop, etc.) delegate to shows_tab; others live on MainWindow directly.
"""

from __future__ import annotations

import webbrowser
from pathlib import Path

from PyQt6.QtCore import Qt, QThread, pyqtSignal
from PyQt6.QtGui import QAction, QKeySequence
from PyQt6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QMenu,
    QMenuBar,
    QProgressBar,
    QProgressDialog,
    QVBoxLayout,
    QWidget,
    QWidgetAction,
)

from core.watchlist_io import save_watchlist
from ui.widgets.pill import Pill


def build_menu_bar(window) -> QMenuBar:
    mb = QMenuBar(window)
    mb.setNativeMenuBar(True)

    # ── File ──────────────────────────────────────────────────────
    f = mb.addMenu("File")
    a = QAction("Add Podcast…", window)
    a.setShortcut("Ctrl+N")
    a.triggered.connect(window.shows_tab._add)
    f.addAction(a)
    a = QAction("Add Episodes…", window)
    a.setShortcut("Ctrl+Shift+N")
    a.triggered.connect(window.shows_tab._curated)
    f.addAction(a)
    a = QAction("Import OPML…", window)
    a.setShortcut("Ctrl+Shift+I")
    a.triggered.connect(lambda: _import_opml(window))
    f.addAction(a)
    a = QAction("Import folder…", window)
    a.triggered.connect(lambda: _import_folder(window))
    f.addAction(a)
    a = QAction("Export Show…", window)
    a.setShortcut("Ctrl+Shift+E")
    a.triggered.connect(lambda: _export_show(window))
    f.addAction(a)
    f.addSeparator()
    a = QAction("Open Latest Transcript", window)
    a.setShortcut("Ctrl+O")
    a.triggered.connect(lambda: _open_latest(window))
    f.addAction(a)
    a = QAction("Reveal Output in Finder", window)
    a.setShortcut("Ctrl+Shift+F")
    a.triggered.connect(lambda: _reveal_output(window))
    f.addAction(a)
    f.addSeparator()
    a = QAction("Close", window)
    a.setShortcut("Ctrl+W")
    a.triggered.connect(window.close)
    f.addAction(a)

    # ── Edit ──────────────────────────────────────────────────────
    e = mb.addMenu("Edit")
    for label, key in (
        ("Undo", "Ctrl+Z"),
        ("Redo", "Ctrl+Shift+Z"),
        ("Cut", "Ctrl+X"),
        ("Copy", "Ctrl+C"),
        ("Paste", "Ctrl+V"),
        ("Select All", "Ctrl+A"),
    ):
        a = QAction(label, window)
        a.setShortcut(key)
        e.addAction(a)
    e.addSeparator()
    a = QAction("Settings…", window)
    a.setShortcut(QKeySequence.StandardKey.Preferences)
    # Settings is index 3 (shows/queue/failed/settings/logs/about).
    a.triggered.connect(lambda: _focus_tab(window, 3))
    e.addAction(a)

    # ── View ──────────────────────────────────────────────────────
    v = mb.addMenu("View")
    for label, key, tab_idx in (
        ("Shows Tab", "Ctrl+1", 0),
        ("Queue Tab", "Ctrl+2", 1),
        ("Failed Tab", "Ctrl+3", 2),
        ("Settings Tab", "Ctrl+4", 3),
    ):
        a = QAction(label, window)
        a.setShortcut(key)
        a.triggered.connect(lambda _=False, i=tab_idx: _focus_tab(window, i))
        v.addAction(a)
    v.addSeparator()
    a = QAction("Show/Hide Log", window)
    a.setShortcut("Ctrl+L")
    a.triggered.connect(lambda: window.log_dock.setVisible(not window.log_dock.isVisible()))
    v.addAction(a)
    a = QAction("Enter Full Screen", window)
    a.setShortcut("Ctrl+Meta+F")
    a.triggered.connect(
        lambda: window.setWindowState(
            window.windowState() ^ window.windowState().__class__.WindowFullScreen
        )
    )
    v.addAction(a)

    # ── Actions ───────────────────────────────────────────────────
    ac = mb.addMenu("Actions")
    a = QAction("Check Now", window)
    a.setShortcut("Ctrl+R")
    a.triggered.connect(lambda: window.shows_tab.start_check(force=True))
    ac.addAction(a)
    a = QAction("Check Selected Show", window)
    a.setShortcut("Ctrl+Shift+R")
    a.triggered.connect(lambda: _check_selected(window))
    ac.addAction(a)
    a = QAction("Stop", window)
    a.setShortcut("Ctrl+.")
    a.triggered.connect(window.shows_tab._stop)
    ac.addAction(a)
    a = QAction("Pause Queue", window)
    a.setShortcut("Ctrl+P")
    a.triggered.connect(lambda: window.shows_tab._pause())
    ac.addAction(a)
    a = QAction("Resume Queue", window)
    a.setShortcut("Ctrl+Shift+P")
    a.triggered.connect(lambda: window.shows_tab._resume())
    ac.addAction(a)
    ac.addSeparator()
    a = QAction("Mark Selected Show Stale", window)
    a.triggered.connect(lambda: _mark_selected_stale(window))
    ac.addAction(a)
    a = QAction("Retry Selected (Failed)", window)
    # Failed tab is index 2.
    a.triggered.connect(lambda: _focus_tab(window, 2))
    ac.addAction(a)
    a = QAction("Open Latest in Obsidian", window)
    a.triggered.connect(lambda: _open_in_obsidian(window))
    ac.addAction(a)

    # ── Tools ─────────────────────────────────────────────────────
    # GUI parity with the CLI: each action wraps the same core function the
    # corresponding `cli.py` subcommand uses.
    t = mb.addMenu("Tools")
    a = QAction("Statistics…", window)
    a.triggered.connect(lambda: _show_stats(window))
    t.addAction(a)
    a = QAction("Event Log…", window)
    a.triggered.connect(lambda: _show_event_log(window))
    t.addAction(a)
    a = QAction("Health Check…", window)
    a.triggered.connect(lambda: _show_health(window))
    t.addAction(a)
    t.addSeparator()
    a = QAction("Bulk Export Transcripts…", window)
    a.triggered.connect(lambda: _bulk_export(window))
    t.addAction(a)
    a = QAction("Publish Transcript Site…", window)
    a.triggered.connect(lambda: _publish_site(window))
    t.addAction(a)
    t.addSeparator()
    a = QAction("Backfill YouTube Dates (selected show)…", window)
    a.triggered.connect(lambda: _backfill_dates(window))
    t.addAction(a)
    a = QAction("Find Duplicate Episodes (selected show)…", window)
    a.triggered.connect(lambda: _find_duplicates(window))
    t.addAction(a)
    t.addSeparator()
    a = QAction("Start Local API…", window)
    a.triggered.connect(lambda: _start_local_api(window))
    t.addAction(a)
    a = QAction("Export Bug Report…", window)
    a.triggered.connect(lambda: _export_bug_report(window))
    t.addAction(a)

    # ── Window ────────────────────────────────────────────────────
    w = mb.addMenu("Window")
    a = QAction("Minimize", window)
    a.setShortcut("Ctrl+M")
    a.triggered.connect(window.showMinimized)
    w.addAction(a)
    a = QAction("Zoom", window)
    a.triggered.connect(window.showMaximized)
    w.addAction(a)

    # ── Help ──────────────────────────────────────────────────────
    h = mb.addMenu("Help")
    a = QAction("Paragraphos Help", window)
    a.triggered.connect(lambda: webbrowser.open("https://github.com/"))
    h.addAction(a)
    a = QAction("Keyboard Shortcuts", window)
    a.triggered.connect(lambda: _show_shortcuts(window))
    h.addAction(a)
    a = QAction("About Paragraphos", window)
    a.triggered.connect(lambda: _show_about(window))
    h.addAction(a)
    a = QAction("Changelog", window)
    a.triggered.connect(lambda: _show_changelog(window))
    h.addAction(a)
    a = QAction("Show Log Folder", window)
    a.triggered.connect(lambda: _open_log_folder(window))
    h.addAction(a)
    a = QAction("Re-run setup guide…", window)
    a.triggered.connect(lambda: rerun_setup(window))
    h.addAction(a)

    return mb


# ── helpers ───────────────────────────────────────────────────────


def _focus_tab(window, idx: int) -> None:
    key = {0: "shows", 1: "queue", 2: "failed", 3: "settings"}.get(idx, "shows")
    window._on_nav(key)


class _OPMLImportThread(QThread):
    """Worker: fetches feed metadata + manifest for each OPML entry off the UI thread.

    Emits `progress(i, total, title)` before each entry and `result(entries)`
    when done, where each `entries` item is a dict with keys:
      - ok (bool)
      - entry (original OPML dict)
      - meta (feed_metadata dict) — only when ok
      - manifest (list[dict]) — only when ok
      - error (str) — only when not ok
    The caller mutates watchlist + state on the UI thread using those results.
    Co-operative cancellation via `request_cancel()`.
    """

    progress = pyqtSignal(int, int, str)
    result = pyqtSignal(list)

    def __init__(self, entries: list[dict], parent=None):
        super().__init__(parent)
        self._entries = entries
        self._cancelled = False

    def request_cancel(self) -> None:
        self._cancelled = True

    def run(self) -> None:  # noqa: D401 — QThread entry
        from core.rss import build_manifest, feed_metadata

        out: list[dict] = []
        total = len(self._entries)
        for i, entry in enumerate(self._entries):
            if self._cancelled:
                break
            self.progress.emit(i, total, entry.get("title") or entry.get("xmlUrl") or "")
            try:
                meta = feed_metadata(entry["xmlUrl"])
                manifest = build_manifest(entry["xmlUrl"], timeout=60)
            except Exception as ex:  # noqa: BLE001 — surfaced as per-entry error
                out.append({"ok": False, "entry": entry, "error": str(ex)})
                continue
            out.append({"ok": True, "entry": entry, "meta": meta, "manifest": manifest})
        self.result.emit(out)


def _import_opml(window) -> None:
    from PyQt6.QtWidgets import QFileDialog, QMessageBox

    from core.models import Show
    from core.opml import parse_opml
    from core.sanitize import slugify

    path, _ = QFileDialog.getOpenFileName(
        window, "Select OPML", str(Path.home()), "OPML (*.opml *.xml)"
    )
    if not path:
        return
    try:
        entries = parse_opml(Path(path))
    except Exception as ex:
        QMessageBox.warning(window, "OPML error", str(ex))
        return
    if not entries:
        QMessageBox.information(window, "OPML import", "No feeds found in the OPML file.")
        return

    total = len(entries)
    dlg = QProgressDialog("Importing feeds…", "Cancel", 0, total, window)
    dlg.setWindowTitle("OPML import")
    dlg.setWindowModality(Qt.WindowModality.WindowModal)
    dlg.setMinimumDuration(0)
    dlg.setAutoClose(False)
    dlg.setAutoReset(False)
    dlg.setValue(0)

    thread = _OPMLImportThread(entries, parent=window)

    def _on_progress(i: int, tot: int, title: str) -> None:
        dlg.setLabelText(f"Importing {i + 1} of {tot}: {title}")
        dlg.setValue(i)

    def _on_result(results: list[dict]) -> None:
        # UI-thread: apply results to watchlist + state, save, report.
        existing = {s.slug for s in window.ctx.watchlist.shows}
        added = 0
        errs: list[str] = []
        for r in results:
            entry = r["entry"]
            if not r["ok"]:
                errs.append(f"{entry.get('title', '?')}: {r['error']}")
                continue
            meta = r["meta"]
            manifest = r["manifest"]
            slug = slugify(meta.get("title") or entry["title"])
            if slug in existing:
                continue
            existing.add(slug)
            window.ctx.watchlist.shows.append(
                Show(
                    slug=slug,
                    title=meta.get("title") or entry["title"],
                    rss=entry["xmlUrl"],
                    whisper_prompt="",
                )
            )
            for ep in manifest:
                window.ctx.state.upsert_episode(
                    show_slug=slug,
                    guid=ep["guid"],
                    title=ep["title"],
                    pub_date=ep["pubDate"],
                    mp3_url=ep["mp3_url"],
                )
            added += 1
        save_watchlist(window.ctx)
        window.shows_tab.refresh()
        dlg.setValue(total)
        dlg.close()
        cancelled = thread._cancelled  # noqa: SLF001 — intentional peek
        header = f"Added {added} show(s)." + (" (cancelled)" if cancelled else "")
        body = header + ("\n\nErrors:\n" + "\n".join(errs[:10]) if errs else "")
        QMessageBox.information(window, "OPML import", body)

    def _on_cancel() -> None:
        thread.request_cancel()
        dlg.setLabelText("Cancelling…")

    thread.progress.connect(_on_progress)
    thread.result.connect(_on_result)
    dlg.canceled.connect(_on_cancel)
    # Keep thread alive until Qt has a chance to deliver its last signals.
    thread.finished.connect(thread.deleteLater)
    # Stash on window so the QThread isn't GC'd mid-flight.
    window._opml_import_thread = thread
    thread.start()


def _import_folder(window) -> None:
    from core.local_source import ingest_folder
    from ui.import_folder_dialog import ImportFolderDialog

    dlg = ImportFolderDialog(window)
    if dlg.exec() != QDialog.DialogCode.Accepted:
        return
    folder = dlg.chosen_folder()
    if folder is None:
        return
    guids = ingest_folder(
        folder,
        show_slug=dlg.show_slug(),
        state=window.ctx.state,
        watchlist_path=window.ctx.data_dir / "watchlist.yaml",
        recursive=dlg.recursive(),
        max_duration_hours=window.ctx.settings.local_max_duration_hours,
    )
    window.statusBar().showMessage(
        f"Imported {len(guids)} file{'s' if len(guids) != 1 else ''}", 5000
    )


def _selected_slug(window) -> str | None:
    rows = window.shows_tab.table.selectedIndexes()
    if not rows:
        return None
    return window.shows_tab.table.item(rows[0].row(), 0).text()


def _check_selected(window) -> None:
    slug = _selected_slug(window)
    if slug:
        window.shows_tab.start_check(only_slug=slug, force=True)


# ── Tools menu helpers (GUI parity with the CLI) ──────────────────────────


def _show_stats(window) -> None:
    """Structured stats panel (7.1) — labelled metric rows, not a message box."""
    from PyQt6.QtWidgets import QDialogButtonBox, QFormLayout

    from core.stats import dashboard_summary

    s = dashboard_summary(window.ctx.state)
    dlg = QDialog(window)
    dlg.setWindowTitle("Statistics")
    dlg.setMinimumWidth(360)
    lay = QVBoxLayout(dlg)
    form = QFormLayout()
    form.addRow("Throughput (7d)", QLabel(f"{s['throughput_per_day']:.2f} episodes/day"))
    form.addRow("Success rate", QLabel(f"{s['success_rate'] * 100:.0f}%"))
    form.addRow("Realtime factor", QLabel(f"{s['realtime_factor']:.2f}×"))
    form.addRow("Done", QLabel(str(s["done"])))
    form.addRow("Pending", QLabel(str(s["pending"])))
    form.addRow("Failed", QLabel(str(s["failed"])))
    lay.addLayout(form)
    bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
    bb.rejected.connect(dlg.reject)
    bb.accepted.connect(dlg.accept)
    lay.addWidget(bb)
    dlg.exec()


def _show_health(window) -> None:
    """Health panel (6.2) — one coloured row per check."""
    from PyQt6.QtWidgets import QDialogButtonBox

    from core import health

    rows = health.run_health_check(window.ctx)
    dlg = QDialog(window)
    dlg.setWindowTitle("Health check")
    dlg.setMinimumWidth(460)
    lay = QVBoxLayout(dlg)
    for r in rows:
        ok = r["ok"]
        lbl = QLabel(f"{'✓' if ok else '✗'}  {r['check']}: {r['detail']}")
        lbl.setWordWrap(True)
        lbl.setStyleSheet(f"color: {'#2e7d32' if ok else '#c62828'};")
        lay.addWidget(lbl)
    bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
    bb.rejected.connect(dlg.reject)
    lay.addWidget(bb)
    dlg.exec()


def _show_event_log(window) -> None:
    """Filterable event-log viewer with JSON/CSV export (7.3)."""
    from PyQt6.QtWidgets import (
        QFileDialog,
        QHBoxLayout,
        QLineEdit,
        QMessageBox,
        QPlainTextEdit,
        QPushButton,
    )

    dlg = QDialog(window)
    dlg.setWindowTitle("Event log")
    dlg.resize(640, 480)
    lay = QVBoxLayout(dlg)
    row = QHBoxLayout()
    type_edit = QLineEdit()
    type_edit.setPlaceholderText("type filter, e.g. 'episode.' (blank = all)")
    row.addWidget(type_edit)
    lay.addLayout(row)
    view = QPlainTextEdit()
    view.setReadOnly(True)
    lay.addWidget(view)

    def _refresh():
        rows = window.ctx.state.query_events(
            type_prefix=type_edit.text().strip() or None, limit=500
        )
        view.setPlainText(
            "\n".join(f"{r['ts']}  {r['type']}  {r.get('show_slug') or ''}".rstrip() for r in rows)
            or "(no events)"
        )

    type_edit.textChanged.connect(lambda _=None: _refresh())

    btn_row = QHBoxLayout()
    export_btn = QPushButton("Export…")

    def _export():
        path, _ = QFileDialog.getSaveFileName(
            dlg, "Export events", "events.json", "JSON (*.json);;CSV (*.csv)"
        )
        if not path:
            return
        from core.log_export import export_events

        rows = window.ctx.state.query_events(
            type_prefix=type_edit.text().strip() or None, limit=5000
        )
        fmt = "csv" if path.lower().endswith(".csv") else "json"
        export_events(rows, fmt, path)
        QMessageBox.information(dlg, "Exported", f"Wrote {len(rows)} event(s) → {path}")

    export_btn.clicked.connect(_export)
    btn_row.addWidget(export_btn)
    btn_row.addStretch()
    lay.addLayout(btn_row)
    _refresh()
    dlg.exec()


def _bulk_export(window) -> None:
    from PyQt6.QtWidgets import QFileDialog, QInputDialog, QMessageBox

    slug = _selected_slug(window)
    if not slug:
        QMessageBox.information(window, "Select show", "Select a row in the Shows tab first.")
        return
    fmt, ok = QInputDialog.getItem(
        window, "Bulk export", "Format:", ["md", "json", "html", "pdf"], 0, False
    )
    if not ok:
        return
    path, _ = QFileDialog.getSaveFileName(window, "Export to", f"{slug}-export.{fmt}")
    if not path:
        return
    show_dir = Path(window.ctx.settings.output_root).expanduser() / slug
    items = [
        {"title": md.stem, "text": md.read_text(encoding="utf-8", errors="replace")}
        for md in sorted(show_dir.glob("*.md"))
        if md.name != "index.md"
    ]
    if not items:
        QMessageBox.information(window, "Nothing to export", "No transcripts for that show.")
        return
    from core.bulk_export import BulkExportError, export

    try:
        export(items, fmt, path)
    except BulkExportError as e:
        QMessageBox.warning(window, "Export failed", str(e))
        return
    QMessageBox.information(window, "Exported", f"Wrote {len(items)} transcript(s) → {path}")


def _publish_site(window) -> None:
    from PyQt6.QtWidgets import QFileDialog, QMessageBox

    dest = QFileDialog.getExistingDirectory(window, "Publish site into folder")
    if not dest:
        return
    root = Path(window.ctx.settings.output_root).expanduser()
    items = []
    for show_dir in (p for p in root.iterdir() if p.is_dir()):
        for md in sorted(show_dir.glob("*.md")):
            if md.name == "index.md":
                continue
            items.append(
                {
                    "slug": f"{show_dir.name}--{md.stem}",
                    "title": md.stem,
                    "date": md.stem[:10],
                    "text": md.read_text(encoding="utf-8", errors="replace"),
                }
            )
    if not items:
        QMessageBox.information(window, "Nothing to publish", "No transcripts found.")
        return
    from core.publish import publish_site

    out = publish_site(items, dest)
    QMessageBox.information(window, "Published", f"Wrote {len(items)} page(s) → {out}/index.html")


class _BackfillThread(QThread):
    """Off-thread YouTube date backfill so the GUI never freezes on the
    (potentially minutes-long) yt-dlp full enumeration."""

    done = pyqtSignal(int)
    error = pyqtSignal(str)

    def __init__(self, state, channel_id: str, parent=None):
        super().__init__(parent)
        self._state = state
        self._cid = channel_id

    def run(self) -> None:
        try:
            from core.backcat_dates import backfill_show_dates
            from core.youtube_meta import enumerate_channel_videos

            changed = backfill_show_dates(
                self._state,
                self._cid,
                enumerate_fn=lambda c, *, full: enumerate_channel_videos(
                    c, include_shorts=True, full=full
                ),
            )
            self.done.emit(changed)
        except Exception as e:  # noqa: BLE001
            self.error.emit(str(e))


def _backfill_dates(window) -> None:
    from PyQt6.QtWidgets import QMessageBox, QProgressDialog

    slug = _selected_slug(window)
    if not slug:
        QMessageBox.information(window, "Select show", "Select a YouTube show first.")
        return
    show = next((s for s in window.ctx.watchlist.shows if s.slug == slug), None)
    if not show or getattr(show, "source", "podcast") != "youtube":
        QMessageBox.information(window, "YouTube only", "Date backfill applies to YouTube shows.")
        return
    from core.youtube import channel_id_from_feed_url

    cid = channel_id_from_feed_url(show.rss)
    if not cid:
        QMessageBox.warning(window, "Backfill", "Couldn't resolve the channel id.")
        return

    prog = QProgressDialog("Re-resolving upload dates…", None, 0, 0, window)
    prog.setWindowTitle("Backfill dates")
    prog.setMinimumDuration(0)
    prog.setCancelButton(None)
    th = _BackfillThread(window.ctx.state, cid, window)
    window._backfill_thread = th  # keep a reference for the thread's lifetime

    def _on_done(n: int) -> None:
        prog.close()
        QMessageBox.information(window, "Backfill", f"Updated {n} episode date(s).")

    def _on_error(msg: str) -> None:
        prog.close()
        QMessageBox.warning(window, "Backfill", f"Backfill failed: {msg}")

    th.done.connect(_on_done)
    th.error.connect(_on_error)
    th.finished.connect(lambda: setattr(window, "_backfill_thread", None))
    th.start()
    prog.show()


def _find_duplicates(window) -> None:
    from PyQt6.QtWidgets import QMessageBox

    from core.dedupe import find_near_duplicates
    from core.state import EpisodeStatus

    slug = _selected_slug(window)
    if not slug:
        QMessageBox.information(window, "Select show", "Select a show first.")
        return
    rows = window.ctx.state.list_by_status(slug, EpisodeStatus.PENDING)
    rows += window.ctx.state.list_by_status(slug, EpisodeStatus.DONE)
    titles = {r["guid"]: r["title"] for r in rows}
    pairs = find_near_duplicates([(r["guid"], r["title"]) for r in rows])
    body = (
        "\n".join(f"• {titles.get(a)!r}\n  ≈ {titles.get(b)!r}" for a, b in pairs)
        or "No likely duplicates found."
    )
    QMessageBox.information(window, "Duplicate episodes", body)


def _start_local_api(window) -> None:
    """Start the localhost JSON API in a background thread (10.2)."""
    import secrets
    import threading

    from PyQt6.QtWidgets import QMessageBox

    if getattr(window, "_api_server", None) is not None:
        QMessageBox.information(window, "Local API", "The local API is already running.")
        return
    from core.api_server import serve

    token = window.ctx.state.get_meta("api_token") or secrets.token_urlsafe(16)
    window.ctx.state.set_meta("api_token", token)
    try:
        server = serve(window.ctx, token=token, host="127.0.0.1", port=8723)
    except OSError as e:
        QMessageBox.warning(window, "Local API", f"Couldn't start the API: {e}")
        return
    window._api_server = server
    threading.Thread(target=server.serve_forever, name="api-server", daemon=True).start()
    QMessageBox.information(
        window,
        "Local API",
        f"Running at http://127.0.0.1:8723\n\nToken:\n{token}\n\n"
        "Send it as `Authorization: Bearer <token>` or `?token=`.",
    )


def _export_bug_report(window) -> None:
    from PyQt6.QtWidgets import QFileDialog, QMessageBox

    path, _ = QFileDialog.getSaveFileName(window, "Export bug report", "paragraphos-bug-report.zip")
    if not path:
        return
    from core.bugbundle import build_bundle

    build_bundle(
        settings=window.ctx.settings,
        state=window.ctx.state,
        dest=path,
        log_dir=window.ctx.data_dir / "logs",
    )
    QMessageBox.information(window, "Bug report", f"Wrote {path}")


def _mark_selected_stale(window) -> None:
    slug = _selected_slug(window)
    if slug:
        window.shows_tab._mark_stale(slug)


def _export_show(window) -> None:
    from PyQt6.QtWidgets import QMessageBox

    from core.export import export_show

    slug = _selected_slug(window)
    if not slug:
        QMessageBox.information(window, "Select show", "Select a row in the Shows tab first.")
        return
    output_root = Path(window.ctx.settings.output_root).expanduser()
    export_dir = Path(window.ctx.settings.export_root).expanduser()
    zip_path = export_show(slug, output_root, export_dir)
    QMessageBox.information(window, "Exported", f"Wrote {zip_path}")


def _open_latest(window) -> None:
    import subprocess

    slug = _selected_slug(window)
    if not slug:
        return
    show_dir = Path(window.ctx.settings.output_root).expanduser() / slug
    mds = sorted(show_dir.glob("*.md"))
    if not mds:
        return
    subprocess.run(["open", str(mds[-1])])


def _reveal_output(window) -> None:
    import subprocess

    subprocess.run(["open", str(Path(window.ctx.settings.output_root).expanduser())])


def _open_in_obsidian(window) -> None:
    slug = _selected_slug(window)
    if not slug:
        return
    vault = Path(window.ctx.settings.obsidian_vault_path).expanduser()
    output_root = Path(window.ctx.settings.output_root).expanduser()
    show_dir = output_root / slug
    mds = sorted(show_dir.glob("*.md"))
    if not mds:
        return
    try:
        rel = mds[-1].relative_to(vault)
    except ValueError:
        # Not inside the vault → open in default macOS app instead.
        import subprocess

        subprocess.run(["open", str(mds[-1])])
        return
    import urllib.parse

    url = (
        f"obsidian://open?vault={urllib.parse.quote(window.ctx.settings.obsidian_vault_name)}"
        f"&file={urllib.parse.quote(str(rel))}"
    )
    webbrowser.open(url)


def _show_about(window) -> None:
    from ui.about_dialog import AboutDialog

    AboutDialog(window).exec()


def _show_changelog(window) -> None:
    from ui.about_dialog import ChangelogDialog

    ChangelogDialog(window).exec()


def _show_shortcuts(window) -> None:
    from PyQt6.QtWidgets import QMessageBox

    QMessageBox.information(
        window,
        "Shortcuts",
        "⌘N     Add Podcast\n"
        "⌘⇧N    Add Episodes\n"
        "⌘⇧I    Import OPML\n"
        "⌘,     Settings\n"
        "⌘R     Check Now\n"
        "⌘⇧R    Check Selected Show\n"
        "⌘.     Stop\n"
        "⌘P/⌘⇧P Pause / Resume\n"
        "⌘1–4   Jump between tabs\n"
        "⌘L     Toggle Log\n"
        "⌘O     Open Latest Transcript\n"
        "⌘⇧F    Reveal Output in Finder\n",
    )


def rerun_setup(window) -> None:
    """Re-open the guided setup dialog on user request.

    The dialog's Finish button flips ``setup_completed`` back to True;
    we force-clear the flag here first so SetupDialog is willing to show
    even though the user has long finished their initial onboarding.
    Persist to disk afterwards using the same idiom as Settings pane.
    """
    from ui.setup_dialog import SetupDialog

    window.ctx.settings.setup_completed = False
    dlg = SetupDialog(window.ctx.settings, window)
    dlg.exec()
    window.ctx.settings.save(window.ctx.data_dir / "settings.yaml")


def _open_log_folder(window) -> None:
    import subprocess

    logs = window.ctx.data_dir / "logs"
    logs.mkdir(exist_ok=True)
    subprocess.run(["open", str(logs)])


# ── tray context menu ─────────────────────────────────────────────
#
# Builder for the QSystemTrayIcon context menu. When a queue run is
# active, the top of the menu gets a rich status block (pill, fraction,
# ETA, thin progress bar, "Now: …" line) rendered via a QWidgetAction.
# When idle, the menu is the plain Open / Check Now / Import OPML /
# Quit shape (kept close to what `app.py` used to build inline).


def _fmt_eta(sec: int | None) -> str:
    if sec is None or sec <= 0:
        return ""
    if sec < 60:
        return f"{int(sec)}s"
    mins = int(sec // 60)
    if mins < 60:
        return f"{mins}m"
    hrs = mins // 60
    rem = mins % 60
    return f"{hrs}h {rem}m" if rem else f"{hrs}h"


def _build_status_block(
    done: int, total: int, current_title: str, eta_sec: int | None, pausing: bool = False
) -> QWidget:
    w = QWidget()
    w.setFixedWidth(280)
    v = QVBoxLayout(w)
    v.setContentsMargins(10, 8, 10, 8)
    v.setSpacing(4)

    # Row 1: pill · fraction · stretch · ETA
    h1 = QHBoxLayout()
    h1.setSpacing(6)
    if pausing:
        h1.addWidget(Pill("Pausing", kind="pausing"))
        frac_lbl = QLabel("Finishing current episode…")
    else:
        h1.addWidget(Pill("running", kind="running"))
        frac_lbl = QLabel(f"{done}/{total}")
    frac_lbl.setStyleSheet("font-weight: 600;")
    h1.addWidget(frac_lbl)
    h1.addStretch()
    eta_text = f"ETA {_fmt_eta(eta_sec)}" if eta_sec else ""
    eta_lbl = QLabel(eta_text)
    eta_lbl.setStyleSheet("color: palette(mid);")
    h1.addWidget(eta_lbl)
    v.addLayout(h1)

    # Row 2: thin progress bar styled with accent token.
    pb = QProgressBar()
    pb.setRange(0, max(total, 1))
    pb.setValue(max(0, min(done, total)))
    pb.setTextVisible(False)
    pb.setFixedHeight(6)
    # Picks up track + accent colors from the global QSS (see
    # ui/themes/app.qss.tmpl → QProgressBar#TrayProgress).
    pb.setObjectName("TrayProgress")
    v.addWidget(pb)

    # Row 3: "Now: <truncated title>"
    trunc = (current_title[:67] + "…") if len(current_title) > 70 else current_title
    nw = QLabel(f"Now: {trunc}" if trunc else "Now: —")
    nw.setStyleSheet("color: palette(mid); font-size: 11px;")
    v.addWidget(nw)
    return w


def build_tray_menu(
    *,
    running: bool,
    done: int = 0,
    total: int = 0,
    current_title: str = "",
    eta_sec: int | None = None,
    pausing: bool = False,
    on_open=None,
    on_check_now=None,
    on_import_opml=None,
    on_quit=None,
) -> QMenu:
    """Build the QSystemTrayIcon context menu.

    When `running=True` and `total>0`, the top of the menu is a
    QWidgetAction with a rich status block (pill / fraction / ETA /
    progress bar / Now title). Otherwise the menu is the plain idle
    shape. All callbacks are optional; missing ones render the action
    disabled.
    """
    menu = QMenu()
    if running and total > 0:
        wa = QWidgetAction(menu)
        wa.setDefaultWidget(
            _build_status_block(done, total, current_title, eta_sec, pausing=pausing)
        )
        menu.addAction(wa)
        menu.addSeparator()

    def _add(label: str, cb) -> None:
        act = menu.addAction(label)
        if cb is None:
            act.setEnabled(False)
        else:
            act.triggered.connect(cb)

    _add("Open Paragraphos", on_open)
    _add("Check Now", on_check_now)
    menu.addSeparator()
    _add("Import OPML…", on_import_opml)
    menu.addSeparator()
    _add("Quit", on_quit)
    return menu
