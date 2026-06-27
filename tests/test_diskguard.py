"""Disk guard pre-flight + auto-pause decision (6.3)."""

from __future__ import annotations

import shutil

from core import diskguard
from core.models import Settings


def _mock_free(monkeypatch, gb):
    class _Usage:
        free = int(gb * 1024**3)

    monkeypatch.setattr(shutil, "disk_usage", lambda p: _Usage())


def test_free_gb(monkeypatch, tmp_path):
    _mock_free(monkeypatch, 12.5)
    assert abs(diskguard.free_gb(tmp_path) - 12.5) < 1e-6


def test_estimate_needed_includes_overhead():
    audio = 100 * 1024**2  # 100 MB
    est = diskguard.estimate_needed(audio)
    assert est > audio  # transcript + temp overhead added
    # sane upper bound: shouldn't balloon beyond ~2x
    assert est < audio * 2


def test_should_pause_below_threshold(monkeypatch, tmp_path):
    _mock_free(monkeypatch, 2)
    s = Settings()
    s.disk_guard_enabled = True
    s.disk_guard_min_free_gb = 5
    assert diskguard.should_pause(s, tmp_path) is True


def test_should_not_pause_above_threshold(monkeypatch, tmp_path):
    _mock_free(monkeypatch, 50)
    s = Settings()
    s.disk_guard_enabled = True
    s.disk_guard_min_free_gb = 5
    assert diskguard.should_pause(s, tmp_path) is False


def test_disabled_never_pauses(monkeypatch, tmp_path):
    _mock_free(monkeypatch, 0.1)
    s = Settings()
    s.disk_guard_enabled = False
    s.disk_guard_min_free_gb = 5
    assert diskguard.should_pause(s, tmp_path) is False
