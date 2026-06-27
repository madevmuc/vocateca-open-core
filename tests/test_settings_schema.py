"""Settings + Show schema expansion for roadmap features (0.2)."""

from __future__ import annotations

from core import events
from core.models import Settings, Show, Watchlist


def test_legacy_yaml_loads_with_defaults(tmp_path):
    # A settings.yaml lacking all the new keys must load with defaults applied.
    p = tmp_path / "settings.yaml"
    p.write_text("output_root: ~/x\ndaily_check_time: '08:00'\n", encoding="utf-8")
    s = Settings.load(p)
    assert s.event_retention_days == 90
    assert s.queue_order == "oldest_first"
    assert s.caption_fallback_mode == "manual_whisper"
    assert s.confidence_marking_enabled is True
    assert s.confidence_threshold == 0.5
    assert s.disk_guard_enabled is True
    assert s.disk_guard_min_free_gb == 5
    assert s.transcribe_concurrency == 1
    assert s.notify_events["episode.transcribed"] is True
    assert s.notify_quiet_hours_start == "22:00"
    assert s.webhooks == []
    assert s.processing_windows == []


def test_new_values_roundtrip(tmp_path):
    p = tmp_path / "settings.yaml"
    s = Settings()
    s.queue_order = "newest_first"
    s.confidence_threshold = 0.7
    s.disk_guard_min_free_gb = 12
    s.processing_windows = ["22:00-08:00"]
    s.webhooks = [{"events": ["episode.failed"], "kind": "post", "target": "x", "enabled": True}]
    s.save(p)
    again = Settings.load(p)
    assert again.queue_order == "newest_first"
    assert again.confidence_threshold == 0.7
    assert again.disk_guard_min_free_gb == 12
    assert again.processing_windows == ["22:00-08:00"]
    assert again.webhooks[0]["kind"] == "post"


def test_notify_events_default_is_independent_per_instance():
    a = Settings()
    b = Settings()
    a.notify_events["episode.failed"] = False
    assert b.notify_events["episode.failed"] is True


def test_show_new_fields_default(tmp_path):
    sh = Show(slug="s", title="t", rss="r")
    assert sh.auto_vocab is False
    assert sh.min_duration_sec == 0
    assert sh.max_duration_sec == 0
    assert sh.notify is True
    # round-trips through watchlist yaml
    wl = Watchlist(shows=[sh])
    p = tmp_path / "watchlist.yaml"
    wl.save(p)
    again = Watchlist.load(p)
    assert again.shows[0].notify is True


def test_legacy_watchlist_loads_without_new_show_fields(tmp_path):
    p = tmp_path / "watchlist.yaml"
    p.write_text("shows:\n  - slug: s\n    title: t\n    rss: r\n", encoding="utf-8")
    wl = Watchlist.load(p)
    assert wl.shows[0].auto_vocab is False
    assert wl.shows[0].min_duration_sec == 0


def test_save_emits_settings_changed(tmp_path):
    events.reset()
    seen = []
    events.subscribe(events.EventType.SETTINGS_CHANGED, seen.append)
    Settings().save(tmp_path / "settings.yaml")
    assert len(seen) == 1
