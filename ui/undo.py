"""Time-boxed undo for destructive actions (roadmap 9.5).

A small LIFO stack of reversible actions, each with a TTL. After a destructive
action (remove-show, delete-transcript, clear-queue, dequeue/deactivate) the
caller pushes an undo callable and surfaces a "X — Undo" banner; the entry
expires after ``ttl_sec`` so stale undos never fire. Out of scope (YAGNI): a
persistent "Recently deleted" view — this is time-boxed undo only.
"""

from __future__ import annotations

import shutil
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from core.paths import trash_dir


@dataclass
class UndoAction:
    label: str
    undo: Callable[[], None]
    expires_at: float


class UndoManager:
    """A short LIFO stack of reversible actions with per-entry expiry."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._stack: list[UndoAction] = []

    def push(self, label: str, undo: Callable[[], None], ttl_sec: float = 60.0) -> None:
        self._stack.append(UndoAction(label, undo, self._clock() + ttl_sec))

    def _drop_expired(self) -> None:
        now = self._clock()
        self._stack = [a for a in self._stack if a.expires_at > now]

    def peek(self) -> UndoAction | None:
        """Most recent unexpired action, or None."""
        now = self._clock()
        for action in reversed(self._stack):
            if action.expires_at > now:
                return action
        return None

    def undo_last(self) -> str | None:
        """Run the most recent unexpired action and return its label, or None.

        Expired entries on top are discarded (and not run)."""
        while self._stack:
            action = self._stack.pop()
            if action.expires_at <= self._clock():
                continue  # expired — discard, do not run
            action.undo()
            return action.label
        return None


# App-wide singleton — destructive UI actions push here; MainWindow's Undo
# action (Cmd+Z) pops the most recent.
manager = UndoManager()


def trash_file(path: Path, *, data_dir: Path | None = None) -> Callable[[], None]:
    """Move ``path`` into the trash dir instead of hard-deleting; return a
    callable that restores it to its original location (undo)."""
    path = Path(path)
    original = path
    dest = trash_dir(data_dir) / f"{uuid.uuid4().hex}-{path.name}"
    shutil.move(str(path), str(dest))

    def _restore() -> None:
        original.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(dest), str(original))

    return _restore
