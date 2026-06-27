"""Pure notification gating logic (roadmap 7.4).

Decides whether a given event should fire a desktop notification, honouring the
per-event ``notify_events`` map, a per-show opt-out, and a quiet-hours window
(which may wrap past midnight). Kept dependency-free + side-effect-free so it's
fully unit-testable without real notifications.
"""

from __future__ import annotations

from datetime import datetime


def in_quiet_hours(now_hhmm: str, start: str, end: str) -> bool:
    """True if ``now_hhmm`` (``"HH:MM"``) falls within [start, end).

    Handles windows that wrap past midnight (e.g. 22:00–08:00) and non-zero-
    padded input; equal bounds mean "no quiet hours". Thin wrapper over the
    shared :func:`core.timewindow.in_window`."""
    from core.timewindow import in_window

    return in_window(now_hhmm, start, end)


def should_notify(event, settings, show=None, *, now_hhmm: str | None = None) -> bool:
    """Whether ``event`` should raise a desktop notification."""
    if not settings.notify_events.get(event.type, False):
        return False
    if show is not None and not getattr(show, "notify", True):
        return False
    if getattr(settings, "notify_quiet_hours_enabled", False):
        now = now_hhmm if now_hhmm is not None else datetime.now().strftime("%H:%M")
        if in_quiet_hours(
            now,
            getattr(settings, "notify_quiet_hours_start", "22:00"),
            getattr(settings, "notify_quiet_hours_end", "08:00"),
        ):
            return False
    return True
