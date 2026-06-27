from pathlib import Path

import httpx
import pytest
import respx

from core.rss import FeedHealth, build_manifest, build_manifest_with_url

FIX = Path(__file__).parent / "fixtures" / "sample_feed.xml"
YT_FIX = Path(__file__).parent / "fixtures" / "youtube_channel_feed.xml"


@respx.mock
def test_build_manifest_parses_items():
    respx.get("https://a.test/rss").respond(200, text=FIX.read_text())
    episodes = build_manifest("https://a.test/rss")
    assert len(episodes) == 2
    first = episodes[0]
    for key in (
        "guid",
        "title",
        "pubDate",
        "duration",
        "episode_number",
        "mp3_url",
        "description",
        "url",
    ):
        assert key in first
    assert first["mp3_url"].startswith("https://")
    assert first["episode_number"].isdigit()


@respx.mock
def test_build_manifest_parses_youtube_channel_feed():
    """YouTube channel feeds are Atom with no audio enclosure. The manifest
    must still surface every video — keyed by the bare 11-char video id and
    pointing at the watch URL — so feed-poll dedup matches the rows the Add
    dialog seeds and new uploads get auto-downloaded."""
    respx.get("https://yt.test/feed").respond(200, text=YT_FIX.read_text())
    episodes = build_manifest("https://yt.test/feed")
    assert len(episodes) == 2
    # Sorted oldest → newest by pubDate.
    assert [e["guid"] for e in episodes] == ["VID11111111", "VID22222222"]
    for e in episodes:
        assert e["mp3_url"] == f"https://www.youtube.com/watch?v={e['guid']}"
        assert e["pubDate"].startswith("2026-06-")


def test_build_manifest_rejects_non_http():
    with pytest.raises(Exception):
        build_manifest("file:///etc/passwd")


@respx.mock
def test_feed_health_ok_on_200():
    respx.head("https://ok.test/rss").respond(200)
    h = FeedHealth.check("https://ok.test/rss")
    assert h.ok is True


@respx.mock
def test_feed_health_reports_failure_on_4xx():
    respx.head("https://dead.test/rss").respond(404)
    h = FeedHealth.check("https://dead.test/rss")
    assert h.ok is False
    assert "404" in h.reason


@respx.mock
def test_build_manifest_with_url_returns_canonical_after_redirect():
    """Feed 301-redirects; build_manifest_with_url exposes the final URL
    so the caller can persist it in watchlist.yaml."""
    respx.get("https://old.test/rss").respond(301, headers={"location": "https://new.test/rss"})
    respx.get("https://new.test/rss").respond(200, text=FIX.read_text())
    canonical, episodes, _etag, _mod = build_manifest_with_url("https://old.test/rss")
    assert canonical == "https://new.test/rss"
    assert len(episodes) == 2


@respx.mock
def test_build_manifest_with_url_same_url_when_no_redirect():
    respx.get("https://stable.test/rss").respond(200, text=FIX.read_text())
    canonical, _, _, _ = build_manifest_with_url("https://stable.test/rss")
    assert canonical == "https://stable.test/rss"


@respx.mock
def test_build_manifest_with_url_returns_304_sentinel_when_unchanged():
    """First fetch returns 200 + etag; second fetch sends If-None-Match and
    the server answers 304 — we expect episodes=None so the caller can
    skip manifest parsing for this show."""
    route = respx.get("https://cond.test/rss")
    route.respond(200, headers={"etag": '"abc"'}, text=FIX.read_text())
    canonical, episodes, etag, modified = build_manifest_with_url("https://cond.test/rss")
    assert canonical == "https://cond.test/rss"
    assert episodes is not None and len(episodes) == 2
    assert etag == '"abc"'

    # Now replace the route with a 304 response and verify we send the
    # If-None-Match header.
    respx.reset()
    route2 = respx.get("https://cond.test/rss")
    route2.respond(304)
    canonical2, episodes2, etag2, modified2 = build_manifest_with_url(
        "https://cond.test/rss", etag=etag, modified=modified
    )
    assert episodes2 is None
    assert etag2 is None and modified2 is None
    # Verify the request carried the conditional header.
    sent = route2.calls.last.request
    assert sent.headers.get("if-none-match") == '"abc"'
