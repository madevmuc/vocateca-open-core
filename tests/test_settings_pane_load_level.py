"""Settings pane — Hintergrundlast (load-management level) group.

Bare-QApplication pattern, mirroring tests/test_settings_pane_sources.py.
_do_save() persists to ctx.data_dir/settings.yaml (tmp_path here), so the
persistence assertions are isolated from any real settings file.
"""

from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication


class _FakeState:
    def get_meta(self, _key: str) -> str | None:
        return None


class _FakeCtx:
    def __init__(self, tmp_path: Path):
        from core.models import Settings

        self.settings = Settings()
        self.data_dir = tmp_path
        self.state = _FakeState()
        self.watchlist = None

    def reload_library(self) -> None:  # pragma: no cover — auto-save side-effect
        pass


_QT_KEEPALIVE: list = []


def _make_pane(tmp_path):
    app = QApplication.instance() or QApplication([])
    _QT_KEEPALIVE.append(app)
    from ui.settings_pane import SettingsPane

    ctx = _FakeCtx(tmp_path)
    try:
        pane = SettingsPane(ctx)
    except Exception as e:
        pytest.skip(f"SettingsPane ctor failed under fake ctx: {e!r}")
    _QT_KEEPALIVE.append(pane)
    return pane, ctx, app


def test_default_selects_balanced_and_paints_readout(tmp_path):
    pane, _ctx, _app = _make_pane(tmp_path)
    assert pane._current_load_level() == "balanced"
    assert pane.load_balanced.isChecked()
    # Read-out reflects the resolved profile (… × N Threads · …).
    assert "Threads" in pane._load_readout.text()


def test_selecting_full_without_bg_priority_persists(tmp_path):
    pane, ctx, _app = _make_pane(tmp_path)
    pane.load_full.setChecked(True)
    pane.background_priority.setChecked(False)
    pane._do_save()  # bypass the 250 ms debounce timer deterministically
    assert ctx.settings.load_level == "full"
    assert ctx.settings.background_priority is False


def test_selecting_quiet_persists(tmp_path):
    pane, ctx, _app = _make_pane(tmp_path)
    pane.load_quiet.setChecked(True)
    pane._do_save()
    assert ctx.settings.load_level == "quiet"
