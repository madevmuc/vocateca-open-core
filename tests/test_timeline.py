"""Per-episode phase timeline from events (7.2)."""

from __future__ import annotations

from core.timeline import format_timeline, phase_durations


def _events():
    # (type, ts) — a normal lifecycle, 1-min discover→download, 2-min download,
    # 1-min wait, 5-min transcribe.
    return [
        {"type": "episode.discovered", "ts": "2026-01-01T00:00:00+00:00"},
        {"type": "episode.download_started", "ts": "2026-01-01T00:01:00+00:00"},
        {"type": "episode.downloaded", "ts": "2026-01-01T00:03:00+00:00"},
        {"type": "episode.transcribe_started", "ts": "2026-01-01T00:04:00+00:00"},
        {"type": "episode.transcribed", "ts": "2026-01-01T00:09:00+00:00"},
    ]


def test_phase_durations_basic():
    d = phase_durations(_events())
    assert d["download_sec"] == 120
    assert d["transcribe_sec"] == 300
    assert d["total_sec"] == 540


def test_phase_durations_partial_sequence():
    d = phase_durations(
        [
            {"type": "episode.download_started", "ts": "2026-01-01T00:00:00+00:00"},
            {"type": "episode.downloaded", "ts": "2026-01-01T00:00:30+00:00"},
        ]
    )
    assert d["download_sec"] == 30
    assert d.get("transcribe_sec") is None


def test_phase_durations_empty():
    assert phase_durations([]) == {}


def test_format_timeline_is_readable():
    text = format_timeline(_events())
    assert "Download" in text
    assert "Transcribe" in text
