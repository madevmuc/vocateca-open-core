"""Stats dashboard computations (7.1)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.stats import success_rate, throughput_per_day


def _ev(t, days_ago):
    ts = (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat()
    return {"type": t, "ts": ts}


def test_throughput_per_day():
    events = [
        _ev("episode.transcribed", 0),
        _ev("episode.transcribed", 1),
        _ev("episode.transcribed", 2),
        _ev("episode.transcribed", 30),  # outside a 7-day window
        _ev("episode.failed", 0),  # not counted as throughput
    ]
    tp = throughput_per_day(events, days=7)
    # 3 transcribed within 7 days → 3/7
    assert abs(tp - 3 / 7) < 1e-6


def test_throughput_empty():
    assert throughput_per_day([], days=7) == 0.0


def test_success_rate():
    events = [
        {"type": "episode.transcribed", "ts": "2026-01-01T00:00:00+00:00"},
        {"type": "episode.transcribed", "ts": "2026-01-01T00:00:00+00:00"},
        {"type": "episode.transcribed", "ts": "2026-01-01T00:00:00+00:00"},
        {"type": "episode.failed", "ts": "2026-01-01T00:00:00+00:00"},
    ]
    assert success_rate(events) == 0.75


def test_success_rate_no_data():
    assert success_rate([]) == 0.0
