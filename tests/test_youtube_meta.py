import json
from unittest.mock import MagicMock, patch

from core.youtube_meta import (
    YoutubeMetaError,
    _pick_avatar,
    enumerate_channel_videos,
    fetch_channel_first_video_date,
    fetch_channel_preview,
    resolve_channel_url_to_id,
    resolve_handle_to_channel_id,
    resolve_video_to_channel_id,
)


def _setup_fake_ytdlp(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.APP_SUPPORT", tmp_path)
    (tmp_path / "bin").mkdir(parents=True)
    (tmp_path / "bin" / "yt-dlp").write_text("#!/bin/sh\n")
    (tmp_path / "bin" / "yt-dlp").chmod(0o755)


def test_resolve_handle_uses_http_fast_path(monkeypatch):
    """Happy path: scrape the @handle page for the canonical channel URL."""
    fake_html = (
        "<html><head>"
        '<link rel="canonical" href="https://www.youtube.com/channel/UCabc1234567890123456789">'
        "</head></html>"
    )
    monkeypatch.setattr("core.youtube_meta._http_get_text", lambda url, timeout=10.0: fake_html)
    cid = resolve_handle_to_channel_id("MrBeast")
    assert cid == "UCabc1234567890123456789"


def test_resolve_handle_falls_back_to_ytdlp_when_http_fails(tmp_path, monkeypatch):
    """If the HTTP scrape fails or returns no canonical link, fall back to yt-dlp."""
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    monkeypatch.setattr(
        "core.youtube_meta._http_get_text",
        lambda url, timeout=10.0: (_ for _ in ()).throw(RuntimeError("network down")),
    )
    # yt-dlp now prints the bare id via `%(channel_id)s` (plain, not JSON).
    fake_proc = MagicMock(returncode=0, stdout="UCabc1234567890123456789\n", stderr="")
    with patch("subprocess.run", return_value=fake_proc) as run:
        cid = resolve_handle_to_channel_id("MrBeast")
        assert cid == "UCabc1234567890123456789"
        args = run.call_args[0][0]
        assert "https://www.youtube.com/@MrBeast" in args


def test_resolve_channel_url_scrapes_canonical(monkeypatch):
    html = '<link rel="canonical" href="https://www.youtube.com/channel/UCabc1234567890123456789">'
    monkeypatch.setattr("core.youtube_meta._http_get_text", lambda url, timeout=10.0: html)
    assert resolve_channel_url_to_id("https://www.youtube.com/c/X") == "UCabc1234567890123456789"


def test_resolve_video_to_channel_id(monkeypatch):
    seen = {}

    def fake(args, timeout=120):
        seen["args"] = args
        return "UCabc1234567890123456789\n"

    monkeypatch.setattr("core.youtube_meta._run_ytdlp", fake)
    assert resolve_video_to_channel_id("dQw4w9WgXcQ") == "UCabc1234567890123456789"
    # Behaviour, not mock identity: it must query the watch URL with the
    # plain channel-id print template.
    assert "https://www.youtube.com/watch?v=dQw4w9WgXcQ" in seen["args"]
    assert "%(channel_id)s" in seen["args"]


def test_resolve_video_returns_empty_when_channel_missing(monkeypatch):
    # yt-dlp prints the literal "NA" when channel_id can't be extracted —
    # that must collapse to "" rather than propagate a fake id.
    monkeypatch.setattr("core.youtube_meta._run_ytdlp", lambda args, timeout=120: "NA\n")
    assert resolve_video_to_channel_id("badid") == ""


def test_resolve_channel_url_falls_back_to_ytdlp(monkeypatch):
    # No canonical link in the HTML → yt-dlp fallback prints the id.
    monkeypatch.setattr(
        "core.youtube_meta._http_get_text", lambda url, timeout=10.0: "<html></html>"
    )
    seen = {}

    def fake(args, timeout=120):
        seen["args"] = args
        return "UCabc1234567890123456789\n"

    monkeypatch.setattr("core.youtube_meta._run_ytdlp", fake)
    assert resolve_channel_url_to_id("https://www.youtube.com/c/X") == "UCabc1234567890123456789"
    assert "https://www.youtube.com/c/X" in seen["args"]


def test_resolve_channel_url_returns_empty_on_na(monkeypatch):
    monkeypatch.setattr("core.youtube_meta._http_get_text", lambda url, timeout=10.0: "")
    monkeypatch.setattr("core.youtube_meta._run_ytdlp", lambda args, timeout=120: "NA\n")
    assert resolve_channel_url_to_id("https://www.youtube.com/c/Nope") == ""


def test_enumerate_channel_videos_parses_flat_playlist(tmp_path, monkeypatch):
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    output = "\n".join(
        [
            json.dumps({"id": "vid1", "title": "First", "timestamp": 1700000000}),
            json.dumps({"id": "vid2", "title": "Second", "timestamp": 1700001000}),
        ]
    )
    fake_proc = MagicMock(returncode=0, stdout=output, stderr="")
    with patch("subprocess.run", return_value=fake_proc):
        vids = enumerate_channel_videos("UCabc")
        assert [v["id"] for v in vids] == ["vid1", "vid2"]
        assert vids[0]["title"] == "First"


def test_enumerate_dateafter_arg(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta._run_ytdlp",
        lambda args, timeout=300: (seen.setdefault("a", args), "")[1],
    )
    enumerate_channel_videos("UCabc", date_after="2020-01-01")
    assert "--dateafter" in seen["a"] and "20200101" in seen["a"]


def test_enumerate_excludes_shorts_via_videos_tab(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta._run_ytdlp",
        lambda args, timeout=300: (seen.setdefault("a", args), "")[1],
    )
    enumerate_channel_videos("UCabc", include_shorts=False)
    assert any(a.endswith("/videos") for a in seen["a"])


def test_enumerate_include_shorts_uses_channel_root(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta._run_ytdlp",
        lambda args, timeout=300: (seen.setdefault("a", args), "")[1],
    )
    enumerate_channel_videos("UCabc", include_shorts=True)
    assert any(a.endswith("/channel/UCabc") for a in seen["a"])
    assert not any(a.endswith("/videos") for a in seen["a"])


def test_enumerate_full_drops_flat_playlist(monkeypatch):
    """``full=True`` fully extracts each entry (no --flat-playlist) so yt-dlp
    returns real upload_date/duration; ``full=False`` keeps the fast flat path."""
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta._run_ytdlp",
        lambda args, timeout=300: (seen.update(a=args), "")[1],
    )
    enumerate_channel_videos("UCabc", full=True)
    assert "--flat-playlist" not in seen["a"]

    enumerate_channel_videos("UCabc", full=False)
    assert "--flat-playlist" in seen["a"]


def test_enumerate_full_dateafter_still_passed(monkeypatch):
    """With ``full=True`` the --dateafter filter is still forwarded (and now
    actually bites because dates are extracted)."""
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta._run_ytdlp",
        lambda args, timeout=300: (seen.update(a=args), "")[1],
    )
    enumerate_channel_videos("UCabc", date_after="2020-01-01", full=True)
    assert "--flat-playlist" not in seen["a"]
    assert "--dateafter" in seen["a"] and "20200101" in seen["a"]


def test_default_timeouts_are_generous():
    """Smoke: each public meta call must allow at least 90s for yt-dlp."""
    import inspect

    import core.youtube_meta as ym

    src = inspect.getsource(ym)
    # Bumped per-call timeouts: 120/180/300.
    assert "timeout=120" in src
    assert "timeout=180" in src
    assert "timeout=300" in src


def test_fetch_channel_preview_uses_rss_fast_path(monkeypatch):
    """Happy path: read the channel's hidden RSS feed (no yt-dlp)."""
    rss = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<feed xmlns="http://www.w3.org/2005/Atom">'
        "<title>Mr Beast</title>"
        "<entry><title>vid 1</title></entry>"
        "<entry><title>vid 2</title></entry>"
        "</feed>"
    )
    monkeypatch.setattr("core.youtube_meta._http_get_text", lambda url, timeout=10.0: rss)
    prev = fetch_channel_preview("UCabc")
    assert prev["title"] == "Mr Beast"
    assert prev["video_count"] == 2
    assert prev["video_count_is_lower_bound"] is True


def test_fetch_channel_preview_surfaces_latest_video_thumbnail(monkeypatch):
    """The fast path has no avatar, but should expose the latest video's
    <media:thumbnail> so the Add dialog can show an image without yt-dlp."""
    rss = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<feed xmlns="http://www.w3.org/2005/Atom" '
        'xmlns:media="http://search.yahoo.com/mrss/">'
        "<title>Mr Beast</title>"
        "<entry><title>vid 1</title><media:group>"
        '<media:thumbnail url="https://i.ytimg.com/vi/abc/hqdefault.jpg"/>'
        "</media:group></entry>"
        "</feed>"
    )
    monkeypatch.setattr("core.youtube_meta._http_get_text", lambda url, timeout=10.0: rss)
    prev = fetch_channel_preview("UCabc")
    assert prev["artwork_url"] == "https://i.ytimg.com/vi/abc/hqdefault.jpg"


def test_pick_avatar_prefers_og_then_ytdlp_then_rss():
    """First non-empty wins: og:image → yt-dlp thumb → latest-video frame → ""."""
    assert _pick_avatar("og", "y", "r") == "og"
    assert _pick_avatar("", "y", "r") == "y"
    assert _pick_avatar("", "", "r") == "r"
    assert _pick_avatar("", "", "") == ""


def _feed_with_thumb():
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<feed xmlns="http://www.w3.org/2005/Atom" '
        'xmlns:media="http://search.yahoo.com/mrss/">'
        "<title>Mr Beast</title>"
        "<entry><title>vid 1</title><media:group>"
        '<media:thumbnail url="https://i.ytimg.com/vi/abc/hqdefault.jpg"/>'
        "</media:group></entry>"
        "</feed>"
    )


def test_fetch_preview_uses_og_image_when_present(monkeypatch):
    """Fast path: the channel page's og:image (the real avatar) wins over the
    latest-video frame from the RSS feed."""
    feed = _feed_with_thumb()
    channel_html = (
        '<html><head><meta property="og:image" content="https://yt3/avatar.jpg"></head></html>'
    )

    def fake_get(url, timeout=10.0):
        if "/feeds/videos.xml" in url:
            return feed
        if "/channel/" in url:
            return channel_html
        return ""

    monkeypatch.setattr("core.youtube_meta._http_get_text", fake_get)
    prev = fetch_channel_preview("UCabc")
    assert prev["artwork_url"] == "https://yt3/avatar.jpg"


def test_fetch_preview_falls_back_to_rss_thumb_when_no_og(monkeypatch):
    """Fast path: with no og:image on the channel page, the latest-video frame
    from the RSS feed is preserved (existing behaviour)."""
    feed = _feed_with_thumb()

    def fake_get(url, timeout=10.0):
        if "/feeds/videos.xml" in url:
            return feed
        if "/channel/" in url:
            return "<html><head></head></html>"
        return ""

    monkeypatch.setattr("core.youtube_meta._http_get_text", fake_get)
    prev = fetch_channel_preview("UCabc")
    assert prev["artwork_url"] == "https://i.ytimg.com/vi/abc/hqdefault.jpg"


def test_fetch_channel_first_video_date_parses_oldest_upload(tmp_path, monkeypatch):
    """yt-dlp prints 'playlist_count|YYYYMMDD'; we normalise the date to ISO and
    surface the total count together."""
    from core.youtube_meta import fetch_channel_first_video_and_count

    _setup_fake_ytdlp(tmp_path, monkeypatch)
    fake_proc = MagicMock(returncode=0, stdout="287|20120504\n", stderr="")
    with patch("subprocess.run", return_value=fake_proc):
        assert fetch_channel_first_video_date("UCabc") == "2012-05-04"
        assert fetch_channel_first_video_and_count("UCabc") == ("2012-05-04", 287)


def test_fetch_channel_first_video_date_empty_on_failure(tmp_path, monkeypatch):
    """A yt-dlp error must not raise — the caller falls back to its default."""
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    fake_proc = MagicMock(returncode=1, stdout="", stderr="boom")
    with patch("subprocess.run", return_value=fake_proc):
        assert fetch_channel_first_video_date("UCabc") == ""


def test_fetch_channel_preview_falls_back_to_ytdlp(tmp_path, monkeypatch):
    """If the RSS scrape fails, fall back to yt-dlp for the exact count."""
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    monkeypatch.setattr(
        "core.youtube_meta._http_get_text",
        lambda url, timeout=10.0: (_ for _ in ()).throw(RuntimeError("network down")),
    )
    payload = {
        "channel_id": "UCabc",
        "channel": "Mr Beast",
        "playlist_count": 700,
        "thumbnails": [{"url": "https://yt3/.../mqdefault.jpg", "width": 320}],
    }
    fake_proc = MagicMock(returncode=0, stdout=json.dumps(payload), stderr="")
    with patch("subprocess.run", return_value=fake_proc):
        prev = fetch_channel_preview("UCabc")
        assert prev["title"] == "Mr Beast"
        assert prev["video_count"] == 700
        assert prev["artwork_url"].startswith("https://")
        assert prev["video_count_is_lower_bound"] is False
