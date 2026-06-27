"""Speaker diarization: no-op gating + label alignment (1.5)."""

from __future__ import annotations

import pytest

from core.diarize import (
    DiarizationUnavailable,
    SpeakerSegment,
    diarize_segments,
    relabel_srt,
    speaker_at,
)

_SEGS = [
    SpeakerSegment(0.0, 5.0, "A"),
    SpeakerSegment(5.0, 10.0, "B"),
]


def test_disabled_is_noop():
    assert diarize_segments("/tmp/whatever.wav", enabled=False) == []


def test_enabled_without_backend_raises():
    with pytest.raises(DiarizationUnavailable):
        diarize_segments("/tmp/whatever.wav", enabled=True)


def test_enabled_uses_injected_backend():
    out = diarize_segments("/tmp/x.wav", enabled=True, backend=lambda p: _SEGS)
    assert out == _SEGS


def test_speaker_at():
    assert speaker_at(1.0, _SEGS) == "A"
    assert speaker_at(7.0, _SEGS) == "B"
    # gap/past-end → nearest segment
    assert speaker_at(100.0, _SEGS) == "B"
    assert speaker_at(0.0, []) == ""


def test_relabel_srt_prefixes_speaker():
    srt = (
        "1\n00:00:01,000 --> 00:00:03,000\nHello there\n\n"
        "2\n00:00:06,000 --> 00:00:08,000\nGoodbye now\n"
    )
    out = relabel_srt(srt, _SEGS)
    assert "A: Hello there" in out
    assert "B: Goodbye now" in out


def test_relabel_srt_noop_without_segments():
    srt = "1\n00:00:01,000 --> 00:00:03,000\nHello\n"
    assert relabel_srt(srt, []) == srt


class _Ctx:
    def __init__(self, enabled, model_dir=""):
        self.diarization_enabled = enabled
        self.diarization_model_dir = model_dir


def test_maybe_diarize_disabled(tmp_path):
    from core.pipeline import _maybe_diarize

    srt = tmp_path / "x.srt"
    srt.write_text("1\n00:00:01,000 --> 00:00:03,000\nHi\n", encoding="utf-8")
    assert _maybe_diarize(_Ctx(False), tmp_path / "a.wav", srt) is False


def test_maybe_diarize_relabels_srt(tmp_path, monkeypatch):
    from core.pipeline import _maybe_diarize

    srt = tmp_path / "x.srt"
    srt.write_text("1\n00:00:01,000 --> 00:00:03,000\nHello\n", encoding="utf-8")
    monkeypatch.setattr(
        "core.diarize.diarize_audio",
        lambda p, model_dir: [SpeakerSegment(0.0, 5.0, "A")],
    )
    assert _maybe_diarize(_Ctx(True, "/models"), tmp_path / "a.wav", srt) is True
    assert "A: Hello" in srt.read_text(encoding="utf-8")


def test_maybe_diarize_unavailable_is_swallowed(tmp_path):
    from core.pipeline import _maybe_diarize

    srt = tmp_path / "x.srt"
    srt.write_text("1\n00:00:01,000 --> 00:00:03,000\nHi\n", encoding="utf-8")
    # No sherpa-onnx / no models → DiarizationUnavailable, swallowed → False.
    assert _maybe_diarize(_Ctx(True, "/nonexistent"), tmp_path / "a.wav", srt) is False


def test_label_speakers_stable_ordering():
    from core.diarize import _label_speakers

    segs = _label_speakers([(5.0, 6.0, 9), (0.0, 1.0, 4), (1.0, 2.0, 9)])
    # earliest-start speaker id 4 → 'A', next distinct id 9 → 'B'
    by_start = {s.start: s.speaker for s in segs}
    assert by_start[0.0] == "A"
    assert by_start[1.0] == "B"
    assert by_start[5.0] == "B"
