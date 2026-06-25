"""The queue's temporal columns must sort by real time, not text.

Display strings like ``Fri 09:00`` / ``Mon 14:30`` (Finish) or ``10:00`` /
``9:00`` (durations) order wrongly under Qt's text sort. ``_SortKeyItem``
carries a numeric key (seconds / epoch) so Pub Date, Audio, Whisper and
Finish ≈ order chronologically. Bare-QApplication pattern, mirroring
tests/test_resizable_header.py.
"""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QApplication, QTableWidget

from ui.queue_tab import _pub_date_sort_key, _SortKeyItem

_QT_KEEPALIVE: list = []


@pytest.fixture
def qapp():
    app = QApplication.instance() or QApplication([])
    _QT_KEEPALIVE.append(app)
    return app


def _sorted_texts(rows: list[tuple[str, float]]) -> list[str]:
    table = QTableWidget(len(rows), 1)
    _QT_KEEPALIVE.append(table)
    for r, (text, key) in enumerate(rows):
        table.setItem(r, 0, _SortKeyItem(text, key))
    table.setSortingEnabled(True)
    table.sortItems(0, Qt.SortOrder.AscendingOrder)
    return [table.item(r, 0).text() for r in range(table.rowCount())]


def test_finish_sorts_by_time_not_text(qapp):
    # 'Fri' < 'Mon' < 'Tue' as text, but the keys order them differently.
    rows = [("Mon 14:30", 3600), ("Fri 09:00", 9000), ("Tue 08:00", 60)]
    assert _sorted_texts(rows) == ["Tue 08:00", "Mon 14:30", "Fri 09:00"]


def test_durations_sort_numerically(qapp):
    # As text '10:00' < '9:00' < '1:30:00'; numerically 9:00 < 10:00 < 1h30.
    rows = [("10:00", 600), ("9:00", 540), ("1:30:00", 5400)]
    assert _sorted_texts(rows) == ["9:00", "10:00", "1:30:00"]


def test_dash_rows_sink_to_bottom_ascending(qapp):
    rows = [
        ("—", float("inf")),
        ("Mon 14:30", 3600),
        ("—", float("inf")),
        ("Tue 08:00", 60),
    ]
    assert _sorted_texts(rows) == ["Tue 08:00", "Mon 14:30", "—", "—"]


def test_pub_date_key_orders_iso_chronologically():
    a = _pub_date_sort_key("2026-06-25T14:30:00")
    b = _pub_date_sort_key("2026-06-26")  # date-only, next day
    c = _pub_date_sort_key("2026-06-25T09:00:00")
    assert c < a < b


def test_pub_date_key_unparseable_sinks():
    assert _pub_date_sort_key("") == float("inf")
    assert _pub_date_sort_key("not a date") == float("inf")
