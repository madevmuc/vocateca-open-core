"""Reconcile dialog for externally-added shows awaiting a backlog decision.

When a show appears in watchlist.yaml without a backlog decision (a raw edit,
not the blessed CLI/GUI path), the worker gates it and the Shows-tab banner
offers "Choose…". This dialog lets the user pick how much history to transcribe
per show; the default is the full archive (consistent with the 24h auto-accept).

``apply_reconcile_choice`` is the Qt-free workhorse — fetch the feed, seed the
episodes, apply the backlog strategy, and mark the show decided — and is unit
tested directly.
"""
from __future__ import annotations

import logging

from PyQt6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QVBoxLayout,
)

from core.backlog import apply_backlog, parse_backlog
from core.rss import build_manifest
from core.stats import _parse_duration as _pd
from core.watchlist_guard import mark_decided, undecided_slugs

# (label shown in the dropdown, canonical backlog mode). "all" is first so it
# is the default — matching the 24h full-history auto-accept default.
BACKLOG_CHOICES = [
    ("Full history — every episode", "all"),
    ("Most recent only", "recent"),
    ("Last 5", "last:5"),
    ("Last 10", "last:10"),
    ("Last 20", "last:20"),
    ("Last 50", "last:50"),
]


def apply_reconcile_choice(ctx, slug: str, backlog_str: str) -> int:
    """Seed a freshly-detected show's episodes, apply the chosen backlog
    strategy, and mark it decided (so the worker gate releases it). Returns
    the number of episodes seeded. Raises if the feed can't be fetched —
    the caller leaves the show undecided so it stays gated + re-offered."""
    mode = parse_backlog(backlog_str)
    show = next((s for s in ctx.watchlist.shows if s.slug == slug), None)
    if show is None:
        return 0
    manifest = build_manifest(show.rss)
    for ep in manifest:
        ctx.state.upsert_episode(
            show_slug=slug,
            guid=ep["guid"],
            title=ep["title"],
            pub_date=ep["pubDate"],
            mp3_url=ep["mp3_url"],
            duration_sec=_pd(ep.get("duration", "")),
        )
    apply_backlog(ctx.state, slug, mode, manifest)
    mark_decided(ctx.state, slug)
    return len(manifest)


class ReconcileDialog(QDialog):
    """Per-show backlog chooser for the undecided shows in the watchlist."""

    def __init__(self, ctx, parent=None):
        super().__init__(parent)
        self.ctx = ctx
        self.setWindowTitle("New shows detected")
        self._slugs = undecided_slugs(ctx.watchlist, ctx.state)
        title_by_slug = {s.slug: s.title for s in ctx.watchlist.shows}

        layout = QVBoxLayout(self)
        intro = QLabel(
            "These shows were added outside Paragraphos. Choose how much history "
            "to transcribe for each — the default is the full archive "
            "(auto-applied if you don't choose within 24h)."
        )
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        self._combos: dict[str, QComboBox] = {}
        for slug in self._slugs:
            combo = QComboBox()
            for label, _mode in BACKLOG_CHOICES:
                combo.addItem(label)
            combo.setCurrentIndex(0)  # full history default
            self._combos[slug] = combo
            form.addRow(title_by_slug.get(slug, slug), combo)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self._apply)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _apply(self) -> None:
        for slug, combo in self._combos.items():
            backlog_str = BACKLOG_CHOICES[combo.currentIndex()][1]
            try:
                apply_reconcile_choice(self.ctx, slug, backlog_str)
            except Exception as e:  # noqa: BLE001 — feed error: leave gated + re-offer
                logging.warning("reconcile failed for %s: %s", slug, e)
        self.accept()
