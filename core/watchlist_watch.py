"""Watchdog observer that fires a callback when watchlist.yaml changes on disk.

Pairs with ParagraphosApp._maybe_reload_watchlist (hash-suppressed + idempotent),
so no debounce is needed here: own-writes are ignored by the hash baseline and
half-written files are tolerated by reload_watchlist.
"""

from __future__ import annotations

from pathlib import Path
from typing import Callable

WATCHLIST_NAME = "watchlist.yaml"


def _affects_watchlist(event) -> bool:
    # Cover modified/created/moved; check both src and (for moves) dest.
    for attr in ("src_path", "dest_path"):
        p = getattr(event, attr, None)
        if p and Path(p).name == WATCHLIST_NAME:
            return True
    return False


class WatchlistEventHandler:
    """watchdog FileSystemEventHandler that calls ``on_change`` when
    watchlist.yaml is touched. (Defined via composition so it's import-safe
    and unit-testable without an Observer.)

    watchdog routes every event through ``dispatch(event)``, so overriding
    ``dispatch`` catches modify/create/move uniformly without enumerating
    per-event hooks. ``obs.schedule`` only requires an object with a
    ``dispatch(event)`` method, so no base class is needed.
    """

    def __init__(self, on_change: Callable[[], None]):
        self._on_change = on_change

    def dispatch(self, event) -> None:
        if _affects_watchlist(event):
            self._on_change()


def start_watchlist_watching(data_dir: Path, on_change: Callable[[], None]):
    from watchdog.observers import Observer

    handler = WatchlistEventHandler(on_change)
    obs = Observer()
    obs.schedule(handler, str(Path(data_dir)), recursive=False)
    obs.start()
    return obs
