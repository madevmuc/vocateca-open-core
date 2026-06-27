"""Pre-transcribe integrity checks (6.5)."""

from __future__ import annotations

import pytest

from core import integrity


def test_zero_byte_audio_rejected(tmp_path):
    p = tmp_path / "a.mp3"
    p.write_bytes(b"")
    assert integrity.check_audio_integrity(p) == integrity.AUDIO_TRUNCATED


def test_missing_audio_rejected(tmp_path):
    assert integrity.check_audio_integrity(tmp_path / "nope.mp3") == integrity.AUDIO_MISSING


def test_garbage_audio_rejected(tmp_path):
    p = tmp_path / "a.mp3"
    p.write_bytes(b"<html>not audio</html>")
    assert integrity.check_audio_integrity(p) == integrity.AUDIO_TRUNCATED


def test_valid_audio_passes(tmp_path):
    p = tmp_path / "a.mp3"
    p.write_bytes(b"ID3\x04\x00\x00\x00\x00\x00\x00rest of file")
    assert integrity.check_audio_integrity(p) is None


def test_wav_audio_passes(tmp_path):
    p = tmp_path / "a.wav"
    p.write_bytes(b"RIFF\x00\x00\x00\x00WAVEfmt ")
    assert integrity.check_audio_integrity(p) is None


def test_model_hash_mismatch_surfaced(tmp_path, monkeypatch):
    model = tmp_path / "ggml-x.bin"
    model.write_bytes(b"model-bytes")

    def _raise(path, name):
        raise ValueError("sha256 changed")

    monkeypatch.setattr("core.security.verify_model", _raise)
    assert integrity.check_model_integrity(model, "x") == integrity.MODEL_HASH_MISMATCH


def test_model_first_use_passes(tmp_path, monkeypatch):
    model = tmp_path / "ggml-x.bin"
    model.write_bytes(b"model-bytes")
    monkeypatch.setattr("core.security.verify_model", lambda path, name: None)
    assert integrity.check_model_integrity(model, "x") is None
