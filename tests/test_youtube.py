import pytest

from core.youtube import (
    YoutubeUrl,
    YoutubeUrlError,
    parse_youtube_url,
    rss_url_for_channel_id,
)


@pytest.mark.parametrize(
    "url,expected_kind,expected_value",
    [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "video", "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ", "video", "dQw4w9WgXcQ"),
        (
            "https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw",
            "channel_id",
            "UCuAXFkgsw1L7xaCfnd5JJOw",
        ),
        ("https://www.youtube.com/@MrBeast", "handle", "MrBeast"),
        ("https://youtube.com/@MrBeast/videos", "handle", "MrBeast"),
    ],
)
def test_parse_known_forms(url, expected_kind, expected_value):
    p = parse_youtube_url(url)
    assert p.kind == expected_kind
    assert p.value == expected_value


def test_parse_rejects_unknown():
    with pytest.raises(YoutubeUrlError):
        parse_youtube_url("https://example.com/x")


def test_rss_url_for_channel_id():
    assert (
        rss_url_for_channel_id("UC123")
        == "https://www.youtube.com/feeds/videos.xml?channel_id=UC123"
    )


def test_parse_c_custom_url():
    u = parse_youtube_url("https://www.youtube.com/c/Veritasium")
    assert u.kind == "channel_url" and u.value == "https://www.youtube.com/c/Veritasium"


def test_parse_user_legacy_url():
    u = parse_youtube_url("https://www.youtube.com/user/Vsauce")
    assert u.kind == "channel_url"


def test_parse_bare_handle():
    u = parse_youtube_url("@veritasium")
    assert u.kind == "channel_url" and "veritasium" in u.value


def test_parse_handle_still_works():
    assert parse_youtube_url("https://www.youtube.com/@veritasium").kind == "handle"


@pytest.mark.parametrize("bad", ["", "@", "foo/bar", "foo bar", "@foo bar", "   "])
def test_parse_bare_handle_rejects_garbage(bad):
    # The bare-name branch must not swallow empty/slash/whitespace tokens —
    # those still raise so the caller can report a real error.
    with pytest.raises(YoutubeUrlError):
        parse_youtube_url(bad)


def test_channel_id_from_feed_url_extracts_id():
    from core.youtube import channel_id_from_feed_url

    assert (
        channel_id_from_feed_url("https://www.youtube.com/feeds/videos.xml?channel_id=UCx") == "UCx"
    )


def test_channel_id_from_feed_url_empty_for_non_channel_feed():
    from core.youtube import channel_id_from_feed_url

    assert channel_id_from_feed_url("https://example.com/podcast.rss") == ""
