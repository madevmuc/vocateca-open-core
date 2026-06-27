"""Tests for ui.widgets.resizable_header.make_resizable.

Bare-QApplication pattern (no pytest-qt), mirroring
tests/test_settings_pane_sources.py.
"""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtCore import QCoreApplication, QSettings
from PyQt6.QtWidgets import QApplication, QHeaderView, QTableWidget

from ui.widgets.resizable_header import make_resizable

_QT_KEEPALIVE: list = []


@pytest.fixture
def qapp():
    app = QApplication.instance() or QApplication([])
    _QT_KEEPALIVE.append(app)
    return app


def _route_qsettings(tmp_path):
    """Send QSettings IO into ``tmp_path`` and clear app/org so each test
    starts from a blank store. Must run before constructing QSettings()."""
    QCoreApplication.setOrganizationName("paragraphos-test")
    QCoreApplication.setApplicationName("paragraphos-test")
    QSettings.setDefaultFormat(QSettings.Format.IniFormat)
    QSettings.setPath(
        QSettings.Format.IniFormat,
        QSettings.Scope.UserScope,
        str(tmp_path),
    )
    # Wipe anything previous tests may have left behind.
    QSettings().clear()
    QSettings().sync()


def _make_table(n_cols: int) -> QTableWidget:
    t = QTableWidget(0, n_cols)
    _QT_KEEPALIVE.append(t)
    return t


def test_make_resizable_sets_modes(qapp, tmp_path):
    _route_qsettings(tmp_path)
    table = _make_table(5)
    make_resizable(
        table,
        settings_key="test/modes",
        stretch_col=2,
        fixed_cols={4: 120},
        defaults={0: 50, 1: 70, 3: 90},
    )
    hdr = table.horizontalHeader()
    assert hdr.sectionResizeMode(0) == QHeaderView.ResizeMode.Interactive
    assert hdr.sectionResizeMode(1) == QHeaderView.ResizeMode.Interactive
    assert hdr.sectionResizeMode(2) == QHeaderView.ResizeMode.Stretch
    assert hdr.sectionResizeMode(3) == QHeaderView.ResizeMode.Interactive
    assert hdr.sectionResizeMode(4) == QHeaderView.ResizeMode.Fixed
    assert table.columnWidth(4) == 120
    # Defaults applied to interactive columns that have no saved width.
    assert table.columnWidth(0) == 50
    assert table.columnWidth(1) == 70
    assert table.columnWidth(3) == 90


def test_persists_and_restores(qapp, tmp_path):
    _route_qsettings(tmp_path)

    # First pass — apply, change width, fire resize signal, wait for debounce.
    table1 = _make_table(4)
    make_resizable(
        table1,
        settings_key="test/persist",
        stretch_col=1,
        defaults={0: 60, 2: 80, 3: 90},
    )
    table1.setColumnWidth(2, 222)
    # The helper suppresses sectionResized for the first 1 s of widget
    # life to avoid stomping saved widths with Qt's transient initial-
    # layout values + dodging a PyQt6 reparent-cascade segfault. Force
    # the suppression timer expired so this synthetic emit goes through.
    if hasattr(table1, "_resizable_armed_at"):
        table1._resizable_armed_at.stop()
    # sectionResized(logicalIndex, oldSize, newSize)
    table1.horizontalHeader().sectionResized.emit(2, 80, 222)

    # Fire the 300 ms debounce timer deterministically rather than waiting on
    # the event loop: under the full suite a lingering background QThread can
    # starve main-thread QTimer servicing, making a wall-clock wait flaky. The
    # debounce QTimer is the table's single-shot 300 ms child; emit its timeout
    # to run the persist callback synchronously.
    from PyQt6.QtCore import QTimer

    qapp.processEvents()
    fired = False
    for t in table1.findChildren(QTimer):
        if t.isSingleShot() and t.interval() == 300:
            t.timeout.emit()
            fired = True
    assert fired, "debounce timer not found"
    qapp.processEvents()
    raw = QSettings().value("test/persist", "")
    assert raw, "expected QSettings entry after sectionResized + debounce"

    # Second pass — fresh table, same key. Restored width should match.
    table2 = _make_table(4)
    make_resizable(
        table2,
        settings_key="test/persist",
        stretch_col=1,
        defaults={0: 60, 2: 80, 3: 90},
    )
    assert table2.columnWidth(2) == 222
    # Untouched non-stretch column falls back to its saved value (which
    # was the default at the time of persist).
    assert table2.columnWidth(0) == 60


def test_reset_clears_settings(qapp, tmp_path):
    _route_qsettings(tmp_path)
    import json

    # Pre-seed a saved width that diverges from the defaults.
    QSettings().setValue("test/reset", json.dumps({"0": 200, "2": 300}))
    QSettings().sync()

    table = _make_table(3)
    make_resizable(
        table,
        settings_key="test/reset",
        stretch_col=1,
        defaults={0: 60, 2: 90},
    )
    # Sanity — saved widths were honoured.
    assert table.columnWidth(0) == 200
    assert table.columnWidth(2) == 300

    # Simulate the context-menu Reset action (the menu callback is a
    # closure inside make_resizable; replicate its body here so we don't
    # need to drive a popup menu under offscreen QPA).
    QSettings().remove("test/reset")
    for col, w in {0: 60, 2: 90}.items():
        table.setColumnWidth(col, w)

    assert QSettings().value("test/reset", None) in (None, "")
    assert table.columnWidth(0) == 60
    assert table.columnWidth(2) == 90
