"""Styled badge — `Pill(text, kind='ok'|'running'|'fail'|'idle'|'pausing')`.

Object-name / property-based QSS so the shared `app.qss.tmpl` stylesheet
picks the variant. Size, radius, and text-styling come from the
stylesheet (rendered with the active theme's pill_* tokens); this class
just binds data.

When the theme flips (macOS Appearance → Dark/Light), Qt re-applies the
global stylesheet but does **not** automatically re-polish already-painted
widgets — so we subscribe to `ThemeManager.themeChanged` and unpolish/
polish ourselves to force a re-read of the QSS variant.
"""

from __future__ import annotations

from PyQt6.QtWidgets import QLabel


class Pill(QLabel):
    ALLOWED_KINDS = ("ok", "fail", "running", "idle", "pausing")

    def __init__(self, text: str = "", kind: str = "idle", parent=None):
        super().__init__(text, parent)
        self.setObjectName("Pill")
        self.set_kind(kind)

        # Subscribe to theme changes. Safe if ThemeManager isn't installed
        # yet (e.g. in a test that imports Pill in isolation).
        from ui.themes import manager

        tm = manager()
        if tm is not None:
            tm.themeChanged.connect(self._on_theme_changed)

    def set_kind(self, kind: str) -> None:
        if kind not in self.ALLOWED_KINDS:
            kind = "idle"
        self.setProperty("kind", kind)
        self._repolish()

    def _on_theme_changed(self, _mode: str) -> None:
        # QSS has already been re-applied by ThemeManager; we just need
        # Qt to re-read it for this specific widget.
        self._repolish()

    def _repolish(self) -> None:
        self.style().unpolish(self)
        self.style().polish(self)
        self.update()
