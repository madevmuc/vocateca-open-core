from pathlib import Path

import pytest

from core.models import Settings, Show, Watchlist


def test_show_defaults():
    s = Show(slug="test", title="Test", rss="https://example.com/feed.xml")
    assert s.enabled is True
    assert s.whisper_prompt == ""
    assert s.output_override is None


def test_watchlist_roundtrip(tmp_path: Path):
    wl = Watchlist(
        shows=[
            Show(slug="foo", title="Foo", rss="https://foo.test/rss", whisper_prompt="Host Alice"),
        ]
    )
    p = tmp_path / "wl.yaml"
    wl.save(p)
    loaded = Watchlist.load(p)
    assert loaded == wl


def test_settings_defaults_match_design(tmp_path: Path):
    # Settings() gives the generic defaults. Load management uses a named
    # level (load_level) that defaults to the responsive "balanced".
    s = Settings()
    assert s.daily_check_time == "09:00"
    assert s.catch_up_missed is True
    assert s.notify_on_success is True
    assert s.mp3_retention_days == 7
    assert s.delete_mp3_after_transcribe is True
    assert s.bandwidth_limit_mbps == 0
    assert s.load_level == "balanced"
    assert s.background_priority is True


def test_settings_time_validation():
    with pytest.raises(ValueError):
        Settings(daily_check_time="25:99")
    with pytest.raises(ValueError):
        Settings(daily_check_time="9am")


def test_show_source_defaults_to_podcast():
    from core.models import Show

    s = Show(slug="x", title="X", rss="https://x/feed.xml")
    assert s.source == "podcast"


def test_show_source_accepts_youtube():
    from core.models import Show

    s = Show(
        slug="x",
        title="X",
        rss="https://youtube.com/feeds/videos.xml?channel_id=UC...",
        source="youtube",
    )
    assert s.source == "youtube"


def test_show_source_accepts_local_variants():
    from core.models import Show

    for src in ("local-folder", "local-drop", "url"):
        s = Show(slug="x", title="X", rss="", source=src)
        assert s.source == src


def test_settings_has_local_source_defaults():
    from core.models import Settings

    s = Settings()
    assert s.watch_folder_enabled is False
    assert s.watch_folder_root == "~/Paragraphos/to-be-transcribed"
    assert s.watch_folder_post == "keep"  # keep | move | delete
    assert s.local_max_duration_hours == 4


def test_youtube_skip_shorts_default_is_true():
    assert Settings().youtube_skip_shorts_default is True


def test_youtube_skip_shorts_default_round_trips(tmp_path: Path):
    import yaml

    s = Settings()
    s.youtube_skip_shorts_default = False
    p = tmp_path / "settings.yaml"
    s.save(p)
    raw = yaml.safe_load(p.read_text(encoding="utf-8"))
    assert raw["youtube_skip_shorts_default"] is False
    reloaded = Settings.model_validate(raw)
    assert reloaded.youtube_skip_shorts_default is False


def test_youtube_skip_shorts_default_migration_safe():
    # An existing settings.yaml predating the field must load and default True.
    data = Settings().model_dump()
    data.pop("youtube_skip_shorts_default", None)
    assert "youtube_skip_shorts_default" not in data
    s = Settings.model_validate(data)
    assert s.youtube_skip_shorts_default is True


def test_legacy_auto_captions_pref_still_loads():
    # auto-captions is no longer user-selectable, but a watchlist that
    # already stored it must still load (pydantic accepts the free string)
    # and the pipeline keeps routing it down the captions path.
    s = Show(
        slug="ch",
        title="Channel",
        rss="https://www.youtube.com/feeds/videos.xml?channel_id=UCabc",
        source="youtube",
        youtube_transcript_pref="auto-captions",
    )
    assert s.youtube_transcript_pref == "auto-captions"
    # The captions branch in core.pipeline is keyed on this membership test.
    assert s.youtube_transcript_pref in ("captions", "auto-captions")
