"""Confidence marking from whisper json-full (1.3)."""

from __future__ import annotations

import json

from core import confidence


def _write_json_full(path):
    data = {
        "transcription": [
            {
                "text": " Hello world",
                "tokens": [
                    {"text": " Hello", "p": 0.95},
                    {"text": " world", "p": 0.20},
                ],
            },
            {
                "text": " again",
                "tokens": [
                    {"text": " again", "p": 0.80},
                    {"text": "[_TT_50]", "p": 0.99},  # special token — ignored
                ],
            },
        ]
    }
    path.write_text(json.dumps(data), encoding="utf-8")


def test_parse_json_full_returns_text_tokens(tmp_path):
    p = tmp_path / "x.json"
    _write_json_full(p)
    toks = confidence.parse_json_full(p)
    texts = [t["text"] for t in toks]
    assert "Hello" in " ".join(texts)
    # special/timestamp tokens like [_TT_..] are dropped
    assert all("_TT_" not in t["text"] for t in toks)


def test_mean_confidence(tmp_path):
    p = tmp_path / "x.json"
    _write_json_full(p)
    toks = confidence.parse_json_full(p)
    m = confidence.mean_confidence(toks)
    # mean of 0.95, 0.20, 0.80
    assert 0.6 < m < 0.7


def test_mean_confidence_empty():
    assert confidence.mean_confidence([]) == 0.0


def test_mark_low_confidence_wraps_only_subthreshold(tmp_path):
    p = tmp_path / "x.json"
    _write_json_full(p)
    toks = confidence.parse_json_full(p)
    out = confidence.mark_low_confidence(toks, threshold=0.5)
    assert "==world==" in out
    assert "==Hello==" not in out
    assert "Hello" in out
    assert "again" in out


def test_transcribe_command_no_json_full_when_disabled():
    # The transcriber must NOT add the json-full flag when marking is disabled.
    from core.transcriber import _build_whisper_cmd

    cmd = _build_whisper_cmd(
        whisper_bin="whisper-cli",
        model_path="m.bin",
        whisper_input="a.wav",
        language="de",
        threads=4,
        stem="out",
        fast_mode=False,
        processors=1,
        whisper_prompt="",
        confidence_json=False,
    )
    assert "-oj" not in cmd and "--output-json-full" not in cmd


def test_transcribe_command_adds_json_full_when_enabled():
    from core.transcriber import _build_whisper_cmd

    cmd = _build_whisper_cmd(
        whisper_bin="whisper-cli",
        model_path="m.bin",
        whisper_input="a.wav",
        language="de",
        threads=4,
        stem="out",
        fast_mode=False,
        processors=1,
        whisper_prompt="",
        confidence_json=True,
    )
    assert "-oj" in cmd or "--output-json-full" in cmd
