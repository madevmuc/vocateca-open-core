"""Caption fallback mode → source chain (3.4)."""

from __future__ import annotations

from core.pipeline import caption_source_chain


def test_per_show_whisper_override_wins_regardless_of_mode():
    assert caption_source_chain("whisper", "manual_whisper") == ["whisper"]
    assert caption_source_chain("whisper", "manual_auto_whisper") == ["whisper"]


def test_manual_whisper_mode():
    assert caption_source_chain("captions", "manual_whisper") == ["manual", "whisper"]
    # empty pref falls back to the mode (default captions behaviour)
    assert caption_source_chain("", "manual_whisper") == ["manual", "whisper"]


def test_manual_auto_whisper_mode():
    assert caption_source_chain("captions", "manual_auto_whisper") == ["manual", "auto", "whisper"]
    assert caption_source_chain("", "manual_auto_whisper") == ["manual", "auto", "whisper"]


def test_unknown_mode_falls_back_to_manual_whisper():
    assert caption_source_chain("captions", "nonsense") == ["manual", "whisper"]


def test_legacy_auto_captions_pref_in_helper():
    # The legacy per-show pref must be honoured by the helper itself (single
    # source of truth), regardless of the settings fallback mode.
    assert caption_source_chain("auto-captions", "manual_whisper") == [
        "manual",
        "auto",
        "whisper",
    ]
