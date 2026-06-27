"""Route a YouTube video into a processing category.

A video reaches the pipeline two ways: as yt-dlp metadata (a dict from
``--dump-json`` / ``--flat-playlist``) when enumeration succeeds, or as a
yt-dlp stderr line when the download itself fails. Both need to collapse
to the same small bucket so the queue can decide whether to skip the
video, retry it later (live/premiere), or surface a friendly reason to
the user (members-only, age-restricted, region-locked).

This is a single pure function — no network, no subprocess. An
unrecognised error string is deliberately *not* classified here
(returns ``"ok"``) so the caller treats it as an ordinary failure.
"""

from __future__ import annotations

# Stable category strings. Keep these in sync with any caller that
# persists or branches on the result.
OK = "ok"
SHORT = "short"
LIVE = "live"
MEMBERS_ONLY = "members_only"
AGE_RESTRICTED = "age_restricted"
REGION_LOCKED = "region_locked"

ALL_CATEGORIES = (
    OK,
    SHORT,
    LIVE,
    MEMBERS_ONLY,
    AGE_RESTRICTED,
    REGION_LOCKED,
)

# Short, friendly, user-facing explanations. "ok" has no message.
_MESSAGES: dict[str, str] = {
    SHORT: "YouTube Short.",
    LIVE: "Live/premiere — will retry once it finishes.",
    MEMBERS_ONLY: "Members-only video — can't be downloaded.",
    AGE_RESTRICTED: "Age-restricted — needs sign-in, can't be downloaded.",
    REGION_LOCKED: "Blocked in this region.",
}


def classify_video(meta_or_error: dict | str) -> tuple[str, str]:
    """Return ``(category, message)`` for a YouTube video.

    ``category`` is one of:
      ``"ok"``             — normal downloadable video, ``message`` ``""``
      ``"short"``          — a YouTube Short
      ``"live"``           — live stream / premiere not finished (retry later)
      ``"members_only"``   — channel-members-only content
      ``"age_restricted"`` — requires sign-in / age confirmation
      ``"region_locked"``  — blocked in the current region

    ``meta_or_error`` is either yt-dlp metadata (a dict) or a yt-dlp
    stderr/error string. ``message`` is a short user-facing explanation
    (``""`` for ``"ok"``).
    """
    if isinstance(meta_or_error, dict):
        return _classify_meta(meta_or_error)
    return _classify_error(str(meta_or_error))


def _result(category: str) -> tuple[str, str]:
    return category, _MESSAGES.get(category, "")


def _classify_meta(meta: dict) -> tuple[str, str]:
    """Inspect yt-dlp metadata fields. Tolerant of missing keys."""
    # Live / premiere first — these are retry-later, not skip.
    live_status = meta.get("live_status")
    if live_status in ("is_live", "is_upcoming", "post_live") or meta.get("is_live"):
        return _result(LIVE)

    # Short — either an explicit /shorts/ URL or a <=60s duration. A
    # missing/None duration is NOT a short.
    url = meta.get("url") or meta.get("webpage_url") or ""
    if "/shorts/" in url:
        return _result(SHORT)
    duration = meta.get("duration")
    if duration is not None and duration <= 60:
        return _result(SHORT)

    # Availability / age gates.
    availability = meta.get("availability")
    if availability == "subscriber_only":
        return _result(MEMBERS_ONLY)
    age_limit = meta.get("age_limit") or 0
    if availability == "needs_auth" or age_limit >= 18:
        return _result(AGE_RESTRICTED)

    return OK, ""


# Known yt-dlp error phrases, matched case-insensitively as substrings.
# Ordered by priority: a members-only gate is reported before the more
# generic age/region/live phrases.
_ERROR_PHRASES: tuple[tuple[str, str], ...] = (
    ("join this channel to get access", MEMBERS_ONLY),
    ("members-only", MEMBERS_ONLY),
    ("members only", MEMBERS_ONLY),
    ("sign in to confirm your age", AGE_RESTRICTED),
    ("confirm your age", AGE_RESTRICTED),
    ("age-restricted", AGE_RESTRICTED),
    ("inappropriate for some users", AGE_RESTRICTED),
    ("not made this video available in your country", REGION_LOCKED),
    ("not available in your country", REGION_LOCKED),
    ("in your country", REGION_LOCKED),
    ("geo restrict", REGION_LOCKED),
    ("this live event will begin", LIVE),
    ("live event will begin", LIVE),
    ("premiere will begin", LIVE),
    ("premieres in", LIVE),
    ("is live and", LIVE),
)


def _classify_error(text: str) -> tuple[str, str]:
    """Match a yt-dlp stderr line against known error phrases."""
    lowered = text.lower()
    for phrase, category in _ERROR_PHRASES:
        if phrase in lowered:
            return _result(category)
    return OK, ""
