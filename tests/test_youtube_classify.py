"""Routing rules for ``core.youtube_classify.classify_video``.

A YouTube video reaches the pipeline either as yt-dlp metadata (a dict
from ``--dump-json`` / ``--flat-playlist``) or — when the download fails
— as a yt-dlp stderr line. Both must collapse to the same small set of
processing categories so the queue/UI can decide whether to skip, retry,
or surface a friendly reason. This test pins that category set plus both
dispatch paths.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from core.youtube_classify import classify_video

_FIXTURES = Path(__file__).parent / "fixtures" / "ytdlp"


@pytest.mark.parametrize(
    "filename, expected",
    [
        ("members_only.txt", "members_only"),
        ("age_restricted.txt", "age_restricted"),
        ("region_locked.txt", "region_locked"),
        ("live_upcoming.txt", "live"),
    ],
)
def test_error_fixture_classification(filename: str, expected: str):
    text = (_FIXTURES / filename).read_text(encoding="utf-8")
    category, message = classify_video(text)
    assert category == expected
    assert message  # every non-"ok" category is user-facing


def test_unrecognised_error_is_ok():
    category, message = classify_video(
        "ERROR: [youtube] dQw4w9WgXcQ: HTTP Error 500: Internal Server Error"
    )
    assert (category, message) == ("ok", "")


# --- dict (metadata) path ---------------------------------------------------


def test_dict_live_upcoming():
    assert classify_video({"live_status": "is_upcoming"})[0] == "live"


def test_dict_is_live_truthy():
    assert classify_video({"is_live": True})[0] == "live"


def test_dict_short_via_shorts_url():
    cat, msg = classify_video({"url": "https://www.youtube.com/shorts/abc123"})
    assert cat == "short"
    assert msg


def test_dict_short_via_short_duration():
    cat, msg = classify_video({"duration": 42})
    assert cat == "short"
    assert msg


def test_dict_members_only_via_availability():
    cat, msg = classify_video({"availability": "subscriber_only"})
    assert cat == "members_only"
    assert msg


def test_dict_age_restricted_via_age_limit():
    cat, msg = classify_video({"age_limit": 18})
    assert cat == "age_restricted"
    assert msg


def test_dict_age_restricted_via_needs_auth():
    cat, msg = classify_video({"availability": "needs_auth"})
    assert cat == "age_restricted"
    assert msg


def test_dict_normal_video_is_ok():
    assert classify_video({"duration": 600, "live_status": "not_live"}) == ("ok", "")


def test_dict_missing_duration_is_not_short():
    # A None/absent duration must not be mistaken for a 0-length short.
    assert classify_video({"live_status": "not_live"}) == ("ok", "")
