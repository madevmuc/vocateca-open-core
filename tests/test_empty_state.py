"""Reusable empty-state widget (9.3)."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication

from ui.widgets.empty_state import EmptyState

_KEEP: list = []


@pytest.fixture
def qapp():
    app = QApplication.instance() or QApplication([])
    _KEEP.append(app)
    return app


def test_renders_title_and_hint(qapp):
    w = EmptyState(title="No shows yet", hint="Add a podcast to start.")
    _KEEP.append(w)
    assert "No shows yet" in w.title_label.text()
    assert "Add a podcast" in w.hint_label.text()


def test_no_action_button_without_callback(qapp):
    w = EmptyState(title="t", hint="h")
    _KEEP.append(w)
    assert w.action_btn is None


def test_action_button_invokes_callback(qapp):
    clicked = []
    w = EmptyState(title="t", hint="h", action_text="Add show", on_action=lambda: clicked.append(1))
    _KEEP.append(w)
    assert w.action_btn is not None
    assert w.action_btn.text() == "Add show"
    w.action_btn.click()
    assert clicked == [1]
