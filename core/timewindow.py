"""Shared HH:MM time-window membership (quiet hours 7.4 + scheduling 2.3).

One implementation so the two callers can't drift on the tricky bits: the
midnight wrap and inclusive/exclusive bounds. Inputs are normalised to
zero-padded ``HH:MM`` first, so user-typed ``8:00`` compares correctly against
``08:30`` (a plain lexicographic compare would not).
"""

from __future__ import annotations


def _norm(t: str) -> str:
    """Zero-pad ``H:MM``/``HH:MM`` so string comparison matches clock order."""
    parts = (t or "").split(":")
    if len(parts) == 2 and parts[0].strip().isdigit() and parts[1].strip().isdigit():
        return f"{int(parts[0]):02d}:{int(parts[1]):02d}"
    return t or ""


def in_window(now_hhmm: str, start: str, end: str) -> bool:
    """True if ``now_hhmm`` is within [start, end). Equal bounds → never;
    handles windows that wrap past midnight (start > end)."""
    now, start, end = _norm(now_hhmm), _norm(start), _norm(end)
    if start == end:
        return False
    if start < end:
        return start <= now < end
    return now >= start or now < end  # wraps midnight
