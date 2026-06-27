"""Cmd-K command palette (9.2)."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication

from ui.command_palette import Command, CommandPalette, fuzzy_filter

_KEEP: list = []


@pytest.fixture
def qapp():
    app = QApplication.instance() or QApplication([])
    _KEEP.append(app)
    return app


def _cmds():
    return [
        Command("Add show", lambda: None),
        Command("Remove show", lambda: None),
        Command("Open settings", lambda: None),
        Command("Start queue", lambda: None),
    ]


def test_fuzzy_filter_subsequence():
    out = fuzzy_filter(_cmds(), "adds")
    assert out and out[0].label == "Add show"


def test_fuzzy_filter_empty_returns_all():
    assert len(fuzzy_filter(_cmds(), "")) == 4


def test_fuzzy_filter_no_match():
    assert fuzzy_filter(_cmds(), "zzzzz") == []


def test_fuzzy_filter_ranks_contiguous_first():
    cmds = [Command("Stop all running", lambda: None), Command("Start queue", lambda: None)]
    out = fuzzy_filter(cmds, "start")
    assert out[0].label == "Start queue"


def test_palette_filters_and_runs(qapp):
    ran = []
    cmds = [
        Command("Add show", lambda: ran.append("add")),
        Command("Open settings", lambda: ran.append("settings")),
    ]
    pal = CommandPalette(cmds)
    _KEEP.append(pal)
    pal.set_query("settings")
    assert pal.visible_labels() == ["Open settings"]
    pal.run_selected()
    assert ran == ["settings"]
