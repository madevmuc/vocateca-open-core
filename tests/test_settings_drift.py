"""Engine/model drift detection (Settings) — a missing fingerprint field must
not be reported as drift."""

from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

_QT_KEEPALIVE: list = []


class _State:
    def __init__(self):
        self._meta = {}

    def get_meta(self, k):
        return self._meta.get(k)

    def set_meta(self, k, v):
        self._meta[k] = v


class _Ctx:
    def __init__(self, tmp_path: Path):
        from core.models import Settings

        self.settings = Settings()
        self.data_dir = tmp_path
        self.state = _State()
        self.watchlist = None

    def reload_library(self):
        pass


def _pane(tmp_path):
    app = QApplication.instance() or QApplication([])
    _QT_KEEPALIVE.append(app)
    from ui.settings_pane import SettingsPane

    pane = SettingsPane(_Ctx(tmp_path))
    _QT_KEEPALIVE.append(pane)
    pane._count_done_transcripts = lambda: 7  # avoid real DB
    return pane


def test_missing_model_hash_is_not_drift(tmp_path):
    """The reported bug: last batch predates model-hash pinning (no model_sha256),
    model + engine unchanged → must show 'match', not a false drift warning."""
    pane = _pane(tmp_path)
    pane._current_engine_fingerprint = lambda: {
        "whisper_model": "large-v3-turbo",
        "whisper_version": "ggml-x",
        "model_sha256": "abc123def456",
    }
    pane._last_transcribed_fingerprint = lambda: {
        "whisper_model": "large-v3-turbo",
        "whisper_version": "ggml-x",
        # no model_sha256 — older transcript
    }
    pane._refresh_drift_row()
    assert "match" in pane._drift_label.text().lower()
    assert pane._drift_button.isHidden() is True


def test_model_change_is_drift_with_button(tmp_path):
    pane = _pane(tmp_path)
    pane._current_engine_fingerprint = lambda: {
        "whisper_model": "small",
        "whisper_version": "ggml-x",
    }
    pane._last_transcribed_fingerprint = lambda: {
        "whisper_model": "large-v3-turbo",
        "whisper_version": "ggml-x",
    }
    pane._refresh_drift_row()
    assert "large-v3-turbo → small" in pane._drift_label.text()
    assert pane._drift_button.isHidden() is False
    assert "Re-transcribe all" in pane._drift_button.text()


def test_engine_change_is_drift(tmp_path):
    pane = _pane(tmp_path)
    pane._current_engine_fingerprint = lambda: {
        "whisper_model": "large-v3-turbo",
        "whisper_version": "ggml-NEW",
    }
    pane._last_transcribed_fingerprint = lambda: {
        "whisper_model": "large-v3-turbo",
        "whisper_version": "ggml-OLD",
    }
    pane._refresh_drift_row()
    assert "engine updated" in pane._drift_label.text().lower()
    assert pane._drift_button.isHidden() is False
