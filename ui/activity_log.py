"""App-wide activity log.

A single place for user-facing actions — adding/removing a show, starting,
pausing or stopping the queue, deleting transcripts, queue edits, … — to
surface in the GUI Log dock + Logs pane AND the on-disk log file.

The GUI sink is installed once by ``MainWindow`` (it fans into the dock and the
sidebar pane). Every message is also written to the ``paragraphos.activity``
logger so it lands in the rotating log file even when no window is attached
(headless / tests). Call :func:`log` from any GUI-thread handler.
"""

from __future__ import annotations

import logging
from typing import Callable, Optional

_logger = logging.getLogger("paragraphos.activity")
_sink: Optional[Callable[[str], None]] = None


def set_sink(fn: Optional[Callable[[str], None]]) -> None:
    """Install (or clear) the GUI sink. Called once by ``MainWindow``."""
    global _sink
    _sink = fn


def log(msg: str) -> None:
    """Record a user-facing action — to the log file and (if attached) the dock."""
    _logger.info(msg)
    if _sink is not None:
        try:
            _sink(msg)
        except Exception:  # noqa: BLE001 — the log must never break an action
            pass


# Curated event → activity-line renderers. Events not listed are not surfaced
# in the dock (they still persist + drive notifications/stats).
def _render_event(ev) -> Optional[str]:
    from core.events import EventType

    title = (ev.payload or {}).get("title") or ev.guid or "episode"
    where = f" — {ev.show_slug}" if ev.show_slug else ""
    table = {
        EventType.EPISODE_TRANSCRIBED: f"✓ Transcribed: {title}{where}",
        EventType.EPISODE_FAILED: (
            f"✗ Failed: {title}{where}"
            + (f" ({ev.payload['error_text']})" if (ev.payload or {}).get("error_text") else "")
        ),
        EventType.EPISODE_SKIPPED: f"– Skipped: {title}{where}",
        EventType.RUN_STARTED: "▶ Check started",
        EventType.RUN_FINISHED: "■ Check finished",
        EventType.FEED_ERROR: f"⚠ Feed error{where}",
        EventType.SHOW_ADDED: f"+ Show added: {ev.show_slug or ''}".rstrip(),
        EventType.SHOW_REMOVED: f"− Show removed: {ev.show_slug or ''}".rstrip(),
    }
    return table.get(ev.type)


def _event_bridge(ev) -> None:
    line = _render_event(ev)
    if line:
        log(line)


def install_event_bridge() -> None:
    """Subscribe a translator that renders a curated subset of events to the
    activity dock. Idempotent. Keeps existing direct ``log()`` calls working."""
    from core import events

    events.subscribe_once("", _event_bridge)
