"""Tests for SQLite persistence of events (roadmap 0.1)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core import events
from core.events import Event, EventType
from core.state import StateStore


def _store(tmp_path):
    s = StateStore(tmp_path / "state.sqlite")
    s.init_schema()
    return s


def _iso(dt):
    return dt.isoformat(timespec="seconds")


def test_append_and_query_by_prefix(tmp_path):
    s = _store(tmp_path)
    s.append_event(Event(type=EventType.EPISODE_FAILED, ts=events.now_iso(), guid="g1"))
    s.append_event(Event(type=EventType.RUN_STARTED, ts=events.now_iso()))
    rows = s.query_events(type_prefix="episode.")
    assert [r["type"] for r in rows] == [EventType.EPISODE_FAILED]
    assert rows[0]["guid"] == "g1"


def test_query_by_guid_and_payload_roundtrip(tmp_path):
    s = _store(tmp_path)
    s.append_event(
        Event(
            type=EventType.EPISODE_TRANSCRIBED,
            ts=events.now_iso(),
            guid="g2",
            show_slug="show-a",
            payload={"detected_language": "de"},
        )
    )
    rows = s.query_events(guid="g2")
    assert len(rows) == 1
    assert rows[0]["show_slug"] == "show-a"
    assert rows[0]["payload"]["detected_language"] == "de"


def test_query_since(tmp_path):
    s = _store(tmp_path)
    old = _iso(datetime.now(timezone.utc) - timedelta(days=10))
    new = _iso(datetime.now(timezone.utc))
    s.append_event(Event(type="x", ts=old))
    s.append_event(Event(type="x", ts=new))
    cutoff = _iso(datetime.now(timezone.utc) - timedelta(days=1))
    rows = s.query_events(since=cutoff)
    assert len(rows) == 1 and rows[0]["ts"] == new


def test_prune_drops_old_keeps_recent(tmp_path):
    s = _store(tmp_path)
    old = _iso(datetime.now(timezone.utc) - timedelta(days=100))
    recent = _iso(datetime.now(timezone.utc) - timedelta(days=1))
    s.append_event(Event(type="x", ts=old))
    s.append_event(Event(type="x", ts=recent))
    deleted = s.prune_events(retention_days=90)
    assert deleted == 1
    rows = s.query_events()
    assert [r["ts"] for r in rows] == [recent]


def test_install_persistence_persists_emitted_events(tmp_path):
    s = _store(tmp_path)
    events.reset()
    events.install_persistence(s)
    events.emit(Event(type=EventType.SHOW_ADDED, ts=events.now_iso(), show_slug="zzz"))
    rows = s.query_events(type_prefix="show.")
    assert len(rows) == 1 and rows[0]["show_slug"] == "zzz"
