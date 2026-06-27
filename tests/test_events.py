"""Tests for the in-process typed event bus (core/events.py)."""

from __future__ import annotations

import re

from core import events
from core.events import Event, EventType


def setup_function():
    events.reset()


def test_exact_match_delivery():
    seen = []
    events.subscribe(EventType.EPISODE_TRANSCRIBED, seen.append)
    events.emit(Event(type=EventType.EPISODE_TRANSCRIBED, ts=events.now_iso(), guid="g1"))
    assert len(seen) == 1 and seen[0].guid == "g1"


def test_prefix_match():
    seen = []
    events.subscribe("episode.", seen.append)
    events.emit(Event(type=EventType.EPISODE_FAILED, ts=events.now_iso()))
    events.emit(Event(type=EventType.RUN_STARTED, ts=events.now_iso()))
    assert [e.type for e in seen] == [EventType.EPISODE_FAILED]


def test_predicate_match():
    seen = []
    events.subscribe(lambda e: e.show_slug == "x", seen.append)
    events.emit(Event(type="any", ts=events.now_iso(), show_slug="x"))
    events.emit(Event(type="any", ts=events.now_iso(), show_slug="y"))
    assert len(seen) == 1


def test_callback_exception_isolated():
    seen = []
    events.subscribe("a.", lambda e: (_ for _ in ()).throw(RuntimeError("boom")))
    events.subscribe("a.", seen.append)
    events.emit(Event(type="a.x", ts=events.now_iso()))  # must not raise
    assert len(seen) == 1


def test_empty_matcher_matches_all():
    seen = []
    events.subscribe("", seen.append)
    events.emit(Event(type="episode.failed", ts=events.now_iso()))
    events.emit(Event(type="run.started", ts=events.now_iso()))
    assert len(seen) == 2


def test_now_iso_is_utc_iso8601():
    ts = events.now_iso()
    # ISO-8601 UTC, e.g. 2026-06-26T22:00:00+00:00 or ...Z
    assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(\+00:00|Z)$", ts), ts


def test_reset_clears_subscribers():
    seen = []
    events.subscribe("", seen.append)
    events.reset()
    events.emit(Event(type="x", ts=events.now_iso()))
    assert seen == []
