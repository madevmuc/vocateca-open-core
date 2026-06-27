"""Shared language picker for YouTube shows.

A single source of truth for the transcript-language combo so the Add-show
dialog and any other caller stay in sync.
"""

from __future__ import annotations

# (display label, code) — curated picker for YouTube shows. "auto" = accept
# the channel's default manual caption track (and per-episode whisper detect).
YOUTUBE_LANGUAGES: list[tuple[str, str]] = [
    ("German (de)", "de"),
    ("English (en)", "en"),
    ("Spanish (es)", "es"),
    ("French (fr)", "fr"),
    ("Italian (it)", "it"),
    ("Dutch (nl)", "nl"),
    ("Portuguese (pt)", "pt"),
    ("Polish (pl)", "pl"),
    ("Czech (cs)", "cs"),
    ("Russian (ru)", "ru"),
    ("Japanese (ja)", "ja"),
    ("Chinese (zh)", "zh"),
    ("Auto (channel default / detect)", "auto"),
]
