"""Granular notification gating + quiet hours (7.4)."""

from __future__ import annotations

from core.events import Event, EventType
from core.models import Settings, Show
from core.notify_rules import in_quiet_hours, should_notify


def _ev(t=EventType.EPISODE_TRANSCRIBED, slug="sh"):
    return Event(type=t, ts="2026-01-01T00:00:00+00:00", show_slug=slug)


def test_in_quiet_hours_same_day_window():
    assert in_quiet_hours("13:00", "12:00", "14:00") is True
    assert in_quiet_hours("11:00", "12:00", "14:00") is False


def test_in_quiet_hours_wraps_midnight():
    assert in_quiet_hours("23:30", "22:00", "08:00") is True
    assert in_quiet_hours("02:00", "22:00", "08:00") is True
    assert in_quiet_hours("12:00", "22:00", "08:00") is False


def test_in_quiet_hours_equal_bounds_is_never():
    assert in_quiet_hours("05:00", "08:00", "08:00") is False


def test_should_notify_respects_event_toggle():
    s = Settings()
    s.notify_events = {EventType.EPISODE_TRANSCRIBED: True, EventType.EPISODE_FAILED: False}
    assert should_notify(_ev(EventType.EPISODE_TRANSCRIBED), s) is True
    assert should_notify(_ev(EventType.EPISODE_FAILED), s) is False
    # unknown event type → default off
    assert should_notify(_ev("episode.discovered"), s) is False


def test_should_notify_per_show_optout():
    s = Settings()
    s.notify_events = {EventType.EPISODE_TRANSCRIBED: True}
    show = Show(slug="sh", title="t", rss="r", notify=False)
    assert should_notify(_ev(), s, show) is False
    show.notify = True
    assert should_notify(_ev(), s, show) is True


def test_should_notify_quiet_hours_suppresses():
    s = Settings()
    s.notify_events = {EventType.EPISODE_TRANSCRIBED: True}
    s.notify_quiet_hours_enabled = True
    s.notify_quiet_hours_start = "22:00"
    s.notify_quiet_hours_end = "08:00"
    assert should_notify(_ev(), s, now_hhmm="23:30") is False
    assert should_notify(_ev(), s, now_hhmm="12:00") is True
