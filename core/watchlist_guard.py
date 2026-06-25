# core/watchlist_guard.py
"""Qt-free guard logic: detect external watchlist.yaml edits, track which
shows have had a backlog decision, and drive the 24h full-history auto-accept.

Meta keys (in state.sqlite ``meta`` table, same pattern as show_paused:<slug>):
    backlog_decided:<slug>      "1" once a backlog choice was made
    backlog_detected_at:<slug>  ISO8601 UTC when first seen undecided
    backlog_grandfathered       "1" after the one-time existing-shows migration
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List

AUTO_ACCEPT_HOURS = 24
GRANDFATHERED = "backlog_grandfathered"


def DECIDED(slug: str) -> str:
    return f"backlog_decided:{slug}"


def DETECTED_AT(slug: str) -> str:
    return f"backlog_detected_at:{slug}"


def file_digest(path: Path) -> str:
    """sha256 hex of the file bytes; "" if the file is missing."""
    try:
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    except OSError:
        return ""


def is_external_change(path: Path, baseline: str) -> bool:
    """True iff the file differs from a *non-empty* baseline digest."""
    if not baseline:
        return False
    return file_digest(path) != baseline


def is_decided(state, slug: str) -> bool:
    return state.get_meta(DECIDED(slug)) == "1"


def mark_decided(state, slug: str) -> None:
    state.set_meta(DECIDED(slug), "1")


def mark_detected_now(state, slug: str, *, now: datetime) -> None:
    """Stamp first-seen time, only if not already stamped (idempotent)."""
    if not state.get_meta(DETECTED_AT(slug)):
        state.set_meta(DETECTED_AT(slug), now.astimezone(timezone.utc).isoformat())


def undecided_slugs(watchlist, state) -> List[str]:
    return [s.slug for s in watchlist.shows if not is_decided(state, s.slug)]


def auto_accept_due(state, slug: str, *, now: datetime) -> bool:
    raw = state.get_meta(DETECTED_AT(slug))
    if not raw:
        return False
    try:
        detected = datetime.fromisoformat(raw)
    except ValueError:
        return False
    if detected.tzinfo is None:
        detected = detected.replace(tzinfo=timezone.utc)
    return now.astimezone(timezone.utc) - detected >= timedelta(hours=AUTO_ACCEPT_HOURS)


def grandfather_existing(watchlist, state) -> bool:
    """One-time: mark every show currently in the watchlist as decided so the
    new gate doesn't ambush pre-existing shows. Returns True if it ran."""
    if state.get_meta(GRANDFATHERED) == "1":
        return False
    for s in watchlist.shows:
        mark_decided(state, s.slug)
    state.set_meta(GRANDFATHERED, "1")
    return True
