"""Processing-window gating (roadmap 2.3).

The worker only claims episodes when the current time falls inside one of the
configured ``processing_windows`` (``"HH:MM-HH:MM"`` strings, midnight-wrap
allowed). An empty list means "always allowed". Pure + defensive — a malformed
window is skipped, never raised.
"""

from __future__ import annotations


def within_windows(now_hhmm: str, windows: list[str]) -> bool:
    """True if ``now_hhmm`` is inside any window (or no windows are set)."""
    from core.timewindow import in_window

    if not windows:
        return True
    for win in windows:
        try:
            start, end = win.split("-", 1)
            start, end = start.strip(), end.strip()
            if not start or not end:
                continue
            if in_window(now_hhmm, start, end):
                return True
        except (ValueError, AttributeError):
            continue
    return False
