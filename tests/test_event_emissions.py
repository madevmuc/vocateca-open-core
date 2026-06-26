"""Lifecycle event emission from set_status + the activity-log bridge (0.1)."""

from __future__ import annotations

from core import events
from core.events import EventType
from core.state import EpisodeStatus, StateStore


def _store(tmp_path):
    s = StateStore(tmp_path / "state.sqlite")
    s.init_schema()
    s.upsert_episode(
        show_slug="show-a",
        guid="g1",
        title="Ep 1",
        pub_date="2026-01-01",
        mp3_url="http://x/a.mp3",
    )
    return s


def setup_function():
    events.reset()


def test_set_status_emits_mapped_event_with_slug_and_guid(tmp_path):
    s = _store(tmp_path)
    seen = []
    events.subscribe("episode.", seen.append)
    s.set_status("g1", EpisodeStatus.DONE)
    assert len(seen) == 1
    assert seen[0].type == EventType.EPISODE_TRANSCRIBED
    assert seen[0].guid == "g1"
    assert seen[0].show_slug == "show-a"


def test_failed_status_carries_error_text(tmp_path):
    s = _store(tmp_path)
    seen = []
    events.subscribe(EventType.EPISODE_FAILED, seen.append)
    s.set_status("g1", EpisodeStatus.FAILED, error_text="boom")
    assert len(seen) == 1
    assert seen[0].payload.get("error_text") == "boom"


def test_pending_status_emits_no_event(tmp_path):
    s = _store(tmp_path)
    seen = []
    events.subscribe("", seen.append)
    s.set_status("g1", EpisodeStatus.PENDING)
    assert seen == []


def test_status_mapping_covers_lifecycle(tmp_path):
    s = _store(tmp_path)
    seen = []
    events.subscribe("episode.", seen.append)
    for status, expected in [
        (EpisodeStatus.DOWNLOADING, EventType.EPISODE_DOWNLOAD_STARTED),
        (EpisodeStatus.DOWNLOADED, EventType.EPISODE_DOWNLOADED),
        (EpisodeStatus.TRANSCRIBING, EventType.EPISODE_TRANSCRIBE_STARTED),
        (EpisodeStatus.SKIPPED, EventType.EPISODE_SKIPPED),
        (EpisodeStatus.DEFERRED, EventType.EPISODE_DEFERRED),
    ]:
        seen.clear()
        s.set_status("g1", status)
        assert [e.type for e in seen] == [expected], status


def test_activity_log_bridge_renders_failed(tmp_path):
    s = _store(tmp_path)
    from ui import activity_log

    lines = []
    activity_log.set_sink(lines.append)
    try:
        activity_log.install_event_bridge()
        s.set_status("g1", EpisodeStatus.FAILED, error_text="network down")
        assert any("g1" in ln or "Ep" in ln or "fail" in ln.lower() for ln in lines)
    finally:
        activity_log.set_sink(None)
