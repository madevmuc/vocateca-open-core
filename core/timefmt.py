"""Time-of-day display-format helpers for the daily-check time field.

The stored value is always canonical 24h ``HH:mm``; only the *display* in the
QTimeEdit follows the OS locale (12h AM/PM vs 24h "military"). Pure functions so
the locale logic is unit-tested without Qt.
"""

from __future__ import annotations


def uses_ampm(locale_time_format: str) -> bool:
    """Whether a Qt locale time-format string is 12-hour (AM/PM).

    Qt encodes the AM/PM marker as ``AP``/``ap`` and the 12-hour hour as a
    lowercase ``h``. We treat the presence of an AM/PM marker as authoritative."""
    return "a" in (locale_time_format or "").lower()


def display_format(ampm: bool) -> str:
    """The QTimeEdit display format for the detected clock style.

    12h → ``h:mm AP`` (editable AM/PM); 24h → ``HH:mm``."""
    return "h:mm AP" if ampm else "HH:mm"
