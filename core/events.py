"""In-process typed event bus.

A single place for the pipeline, worker and UI to publish lifecycle events
(episode discovered/downloaded/transcribed/failed, run started/finished, feed
checked, show added/removed, settings changed). Subscribers react synchronously;
a built-in persister (see :func:`install_persistence`) records every event to
SQLite, and an activity-log bridge translates a curated subset to the GUI dock.

Design mirrors ``ui.activity_log``: a module-level singleton, no Qt import (lives
in ``core/`` so it is import-safe headless), and **callback failures are
swallowed + logged, never propagated** — emitting an event must never break the
action that emitted it. Dispatch is synchronous; subscribers that need async
(webhooks) spawn their own thread.
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Union

_logger = logging.getLogger("paragraphos.events")

# matcher: exact type string, a prefix ending in "." , "" (match-all), or a predicate
Matcher = Union[str, Callable[["Event"], bool]]


@dataclass
class Event:
    """A single lifecycle event. ``payload`` must be JSON-serialisable."""

    type: str
    ts: str  # ISO-8601 UTC
    show_slug: str | None = None
    guid: str | None = None
    payload: dict = field(default_factory=dict)


class EventType:
    """String constants for event types, grouped by domain."""

    # episode lifecycle
    EPISODE_DISCOVERED = "episode.discovered"
    EPISODE_DOWNLOAD_STARTED = "episode.download_started"
    EPISODE_DOWNLOADED = "episode.downloaded"
    EPISODE_TRANSCRIBE_STARTED = "episode.transcribe_started"
    EPISODE_TRANSCRIBED = "episode.transcribed"
    EPISODE_FAILED = "episode.failed"
    EPISODE_SKIPPED = "episode.skipped"
    EPISODE_DEFERRED = "episode.deferred"
    # run / queue
    RUN_STARTED = "run.started"
    RUN_FINISHED = "run.finished"
    QUEUE_SIZED = "queue.sized"
    QUEUE_PAUSED = "queue.paused"
    QUEUE_RESUMED = "queue.resumed"
    # feed
    FEED_CHECKED = "feed.checked"
    FEED_UNCHANGED = "feed.unchanged"
    FEED_ERROR = "feed.error"
    # show
    SHOW_ADDED = "show.added"
    SHOW_REMOVED = "show.removed"
    SHOW_ENABLED = "show.enabled"
    SHOW_DISABLED = "show.disabled"
    # settings
    SETTINGS_CHANGED = "settings.changed"


_lock = threading.Lock()
_subscribers: list[tuple[Matcher, Callable[[Event], None]]] = []


def now_iso() -> str:
    """Current time as an ISO-8601 UTC string (``...+00:00``)."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _matches(matcher: Matcher, event: Event) -> bool:
    if callable(matcher):
        try:
            return bool(matcher(event))
        except Exception:  # noqa: BLE001 — a broken predicate must not break dispatch
            _logger.exception("event matcher raised")
            return False
    if matcher == "":
        return True
    if matcher.endswith("."):
        return event.type.startswith(matcher)
    return event.type == matcher


def subscribe(matcher: Matcher, callback: Callable[[Event], None]) -> None:
    """Register ``callback`` for events matching ``matcher``.

    ``matcher`` is an exact type string, a prefix ending in ``"."`` (e.g.
    ``"episode."``), ``""`` (match everything), or a predicate
    ``Callable[[Event], bool]``.
    """
    with _lock:
        _subscribers.append((matcher, callback))


def emit(event: Event) -> None:
    """Dispatch ``event`` synchronously to every matching subscriber.

    Each callback is wrapped in try/except — failures are logged, never raised.
    Safe to call from worker threads.
    """
    with _lock:
        snapshot = list(_subscribers)
    for matcher, callback in snapshot:
        if not _matches(matcher, event):
            continue
        try:
            callback(event)
        except Exception:  # noqa: BLE001 — a subscriber must never break the emitter
            _logger.exception("event subscriber raised for %s", event.type)


def reset() -> None:
    """Clear all subscribers (test helper / app teardown)."""
    with _lock:
        _subscribers.clear()


def install_persistence(store) -> None:
    """Subscribe a persister that records every emitted event to ``store``.

    ``store`` is a ``core.state.StateStore`` (or anything with
    ``append_event(Event)``). Persistence failures are swallowed by ``emit``'s
    subscriber-isolation contract, so a transient DB error never breaks the
    pipeline. Idempotent per store — calling it twice for the same store does
    not double-persist.
    """
    cb = store.append_event
    with _lock:
        for matcher, existing in _subscribers:
            if matcher == "" and existing == cb:
                return
    subscribe("", cb)
