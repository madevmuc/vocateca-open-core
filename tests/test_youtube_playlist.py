"""YouTube playlist support (3.2)."""

from __future__ import annotations

from core.youtube import (
    manifest_from_videos,
    parse_youtube_url,
    rss_url_for_playlist_id,
)


def test_parse_playlist_url():
    p = parse_youtube_url("https://www.youtube.com/playlist?list=PLabc123")
    assert p.kind == "playlist"
    assert p.value == "PLabc123"


def test_parse_watch_with_list_is_still_video():
    # A /watch URL is a video even if it carries a list= param.
    p = parse_youtube_url("https://www.youtube.com/watch?v=abcdefghijk&list=PLxyz")
    assert p.kind == "video"


def test_rss_url_for_playlist():
    assert rss_url_for_playlist_id("PLabc") == (
        "https://www.youtube.com/feeds/videos.xml?playlist_id=PLabc"
    )


def test_playlist_videos_seed_like_channel():
    # The flat-playlist output feeds the same manifest builder as a channel.
    videos = [
        {"id": "v1", "title": "Ep 1", "timestamp": 1700000000},
        {"id": "v2", "title": "Ep 2", "upload_date": "20260101"},
    ]
    manifest = manifest_from_videos(videos)
    assert {m["guid"] for m in manifest} == {"v1", "v2"}
    assert all(m["mp3_url"].startswith("https://www.youtube.com/watch") for m in manifest)
