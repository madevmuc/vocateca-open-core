"""Tools menu exposes the CLI features in the GUI (feature parity)."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication, QWidget

from ui.menu_bar import build_menu_bar

_KEEP: list = []


@pytest.fixture
def qapp():
    app = QApplication.instance() or QApplication([])
    _KEEP.append(app)
    return app


def test_tools_menu_has_parity_actions(qapp):
    # build_menu_bar binds some shows_tab/log_dock methods at build time; provide
    # a minimal stub. The Tools callbacks are lambdas (not invoked at build).
    from types import SimpleNamespace

    w = QWidget()
    _KEEP.append(w)
    w.shows_tab = SimpleNamespace(
        _add=lambda *a: None,
        _curated=lambda *a: None,
        _stop=lambda *a: None,
        _pause=lambda *a: None,
        _resume=lambda *a: None,
        start_check=lambda *a, **k: None,
        table=None,
    )
    w.log_dock = SimpleNamespace(isVisible=lambda: False, setVisible=lambda v: None)
    mb = build_menu_bar(w)
    _KEEP.append(mb)
    tools = next((m for m in mb.findChildren(type(mb.addMenu("x"))) if m.title() == "Tools"), None)
    assert tools is not None, "Tools menu missing"
    labels = {a.text() for a in tools.actions() if a.text()}
    for expected in (
        "Statistics…",
        "Event Log…",
        "Health Check…",
        "Bulk Export Transcripts…",
        "Publish Transcript Site…",
        "Export Bug Report…",
    ):
        assert expected in labels, f"missing Tools action: {expected}"
