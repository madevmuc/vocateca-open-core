"""Startup health self-check (6.2)."""

from __future__ import annotations

from core import health


def test_disk_space_check_below_threshold(tmp_path, monkeypatch):
    import shutil

    class _Usage:
        free = 1 * 1024**3  # 1 GB

    monkeypatch.setattr(shutil, "disk_usage", lambda p: _Usage())
    ok, detail = health.check_disk_space(tmp_path, min_gb=5)
    assert ok is False
    assert "GB" in detail


def test_disk_space_check_ok(tmp_path, monkeypatch):
    import shutil

    class _Usage:
        free = 50 * 1024**3

    monkeypatch.setattr(shutil, "disk_usage", lambda p: _Usage())
    ok, _ = health.check_disk_space(tmp_path, min_gb=5)
    assert ok is True


def test_data_dir_writable_ok(tmp_path):
    ok, _ = health.check_data_dir_writable(tmp_path)
    assert ok is True


def test_data_dir_writable_missing(tmp_path):
    ok, _ = health.check_data_dir_writable(tmp_path / "does" / "not" / "exist")
    assert ok is False


def test_run_health_check_returns_rows(tmp_path, monkeypatch):
    class _Settings:
        disk_guard_min_free_gb = 5
        whisper_model = "large-v3-turbo"

    class _Ctx:
        data_dir = tmp_path
        settings = _Settings()

    rows = health.run_health_check(_Ctx())
    assert isinstance(rows, list) and rows
    for r in rows:
        assert "check" in r and "ok" in r and "detail" in r
    # there should be a disk + data-dir check among them
    names = {r["check"] for r in rows}
    assert "disk_space" in names
    assert "data_dir_writable" in names
