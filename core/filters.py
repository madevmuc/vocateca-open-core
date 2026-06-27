"""Episode content filters (roadmap 3.3).

Pure helpers for the per-show duration filter: resolve effective min/max bounds
(show overrides settings defaults; 0 = no limit) and decide whether an episode's
known duration falls outside the allowed range. Unknown duration never filters —
we only skip when we positively know the length is out of range.
"""

from __future__ import annotations

DURATION_OUT_OF_RANGE = "duration-out-of-range"


def resolve_duration_bounds(
    *, show_min: int, show_max: int, def_min: int, def_max: int
) -> tuple[int, int]:
    """Effective (min, max) seconds for a show. A non-zero show value wins;
    a zero show value falls back to the settings default (which may also be 0 =
    no limit)."""
    eff_min = show_min if show_min else def_min
    eff_max = show_max if show_max else def_max
    return int(eff_min or 0), int(eff_max or 0)


def duration_filter_reason(duration_sec, min_sec: int, max_sec: int) -> str | None:
    """Return a skip reason if ``duration_sec`` is positively out of [min, max],
    else None. 0/None duration (unknown) and 0 bounds (no limit) never filter."""
    if not duration_sec or duration_sec <= 0:
        return None
    if min_sec and duration_sec < min_sec:
        return DURATION_OUT_OF_RANGE
    if max_sec and duration_sec > max_sec:
        return DURATION_OUT_OF_RANGE
    return None
