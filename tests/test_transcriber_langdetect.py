"""Per-episode language auto-detect parsing + frontmatter (1.1)."""

from __future__ import annotations

from core import events, transcriber
from core.state import EpisodeStatus, StateStore


def test_parse_detected_language_extracts_code():
    stderr = (
        "whisper_init_state: ...\n"
        "whisper_full_with_state: auto-detected language: de (p = 0.98)\n"
        "whisper_print_timings: ...\n"
    )
    assert transcriber.parse_detected_language(stderr) == "de"


def test_parse_detected_language_three_letter():
    assert transcriber.parse_detected_language("auto-detected language: yue (p = 0.5)") == "yue"


def test_parse_detected_language_absent_returns_none():
    assert transcriber.parse_detected_language("no language line here") is None
    assert transcriber.parse_detected_language("") is None


def test_frontmatter_includes_detected_language():
    fm = transcriber._fmt_frontmatter(
        {"guid": "g", "show_slug": "s", "title": "t", "pub_date": "2026-01-01", "mp3_url": "u"},
        None,
        detected_language="de",
    )
    assert 'detected_language: "de"' in fm


def test_frontmatter_omits_detected_language_when_none():
    fm = transcriber._fmt_frontmatter(
        {"guid": "g", "show_slug": "s", "title": "t", "pub_date": "2026-01-01", "mp3_url": "u"},
        None,
        detected_language=None,
    )
    assert "detected_language" not in fm


def test_state_persists_and_transcribed_event_carries_language(tmp_path):
    s = StateStore(tmp_path / "state.sqlite")
    s.init_schema()
    s.upsert_episode(show_slug="sh", guid="g1", title="T", pub_date="2026-01-01", mp3_url="u")
    s.set_detected_language("g1", "fr")
    events.reset()
    seen = []
    events.subscribe(events.EventType.EPISODE_TRANSCRIBED, seen.append)
    s.set_status("g1", EpisodeStatus.DONE)
    assert len(seen) == 1
    assert seen[0].payload.get("detected_language") == "fr"
