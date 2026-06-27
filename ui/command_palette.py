"""Cmd-K command palette + fuzzy action search (roadmap 9.2).

A lightweight fuzzy-filtered action list. ``fuzzy_filter`` is a pure
subsequence matcher (testable without Qt); ``CommandPalette`` is a modal dialog
that filters as you type and runs the chosen action on Enter.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QDialog,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QVBoxLayout,
)


@dataclass
class Command:
    label: str
    callback: Callable[[], None]


def _score(query: str, text: str) -> int | None:
    """Subsequence match score (lower = better), or None if no match.

    Score rewards a contiguous run (substring) and an early first-match index."""
    q = query.lower()
    t = text.lower()
    if not q:
        return 0
    if q in t:
        return t.index(q)  # contiguous substring — best, ranked by position
    # fall back to subsequence
    i = 0
    first = -1
    for ch in q:
        j = t.find(ch, i)
        if j < 0:
            return None
        if first < 0:
            first = j
        i = j + 1
    return 1000 + first  # subsequence matches rank after substring matches


def fuzzy_filter(commands: list[Command], query: str) -> list[Command]:
    """Return commands matching ``query``, best matches first."""
    scored = []
    for cmd in commands:
        s = _score(query, cmd.label)
        if s is not None:
            scored.append((s, cmd))
    scored.sort(key=lambda pair: (pair[0], pair[1].label))
    return [cmd for _s, cmd in scored]


class CommandPalette(QDialog):
    def __init__(self, commands: list[Command], parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Commands")
        self._commands = commands
        layout = QVBoxLayout(self)
        self._edit = QLineEdit()
        self._edit.setPlaceholderText("Type a command…")
        self._edit.textChanged.connect(self.set_query)
        self._edit.returnPressed.connect(self.run_selected)
        layout.addWidget(self._edit)
        self._list = QListWidget()
        layout.addWidget(self._list)
        self.set_query("")

    def set_query(self, query: str) -> None:
        self._list.clear()
        self._filtered = fuzzy_filter(self._commands, query)
        for cmd in self._filtered:
            self._list.addItem(QListWidgetItem(cmd.label))
        if self._filtered:
            self._list.setCurrentRow(0)

    def visible_labels(self) -> list[str]:
        return [self._list.item(i).text() for i in range(self._list.count())]

    def run_selected(self) -> None:
        row = self._list.currentRow()
        if 0 <= row < len(self._filtered):
            cmd = self._filtered[row]
            self.accept()
            cmd.callback()

    def keyPressEvent(self, event) -> None:  # noqa: N802 (Qt override)
        if event.key() == Qt.Key.Key_Escape:
            self.reject()
            return
        super().keyPressEvent(event)
