"""Regression: the About pane must not force the main window wider than a
laptop screen. A non-word-wrapped QLabel reports its full one-line text width as
its minimum, which propagates through the QStackedWidget and grows the whole
window beyond the display (observed: 1753 px from a long unwrapped paragraph)."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

_QT_KEEPALIVE: list = []

# Comfortably below the smallest built-in Apple-Silicon laptop logical width.
_MAX_MIN_WIDTH = 700


def _app() -> QApplication:
    app = QApplication.instance() or QApplication([])
    _QT_KEEPALIVE.append(app)
    return app


def test_about_tabs_min_width_fit_screen():
    """Each static About tab must stay narrow. (AboutPane itself is not built
    here because its Changelog tab spawns a GitHub-fetch QThread that would leak
    into test teardown; the tab builders below hold the at-risk labels.)"""
    _app()
    from PyQt6.QtWidgets import QWidget

    from ui.about_dialog import _about_tab, _licenses_tab, _security_tab

    parent = QWidget()
    _QT_KEEPALIVE.append(parent)  # keep the parent alive so the tab isn't GC'd
    for fn in (_about_tab, _licenses_tab, _security_tab):
        tab = fn(parent)
        assert tab.minimumSizeHint().width() <= _MAX_MIN_WIDTH, fn.__name__
