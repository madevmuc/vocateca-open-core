"""CLI set / set-setting for the roadmap schema additions (0.2)."""

from __future__ import annotations

import argparse

import cli
from core.models import Settings, Show, Watchlist


def _wire(tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    Watchlist(shows=[Show(slug="ch", title="C", rss="r")]).save(tmp_path / "watchlist.yaml")


def test_set_show_auto_vocab(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    rc = cli.cmd_set(argparse.Namespace(slug="ch", assignment="auto_vocab=true"))
    assert rc == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    assert wl.shows[0].auto_vocab is True


def test_set_show_min_duration(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    rc = cli.cmd_set(argparse.Namespace(slug="ch", assignment="min_duration_sec=600"))
    assert rc == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    assert wl.shows[0].min_duration_sec == 600


def test_set_setting_queue_order(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    rc = cli.cmd_set_setting(argparse.Namespace(key="queue_order", value="newest_first"))
    assert rc == 0
    assert Settings.load(tmp_path / "settings.yaml").queue_order == "newest_first"


def test_set_setting_disk_guard_min_free_gb(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    rc = cli.cmd_set_setting(argparse.Namespace(key="disk_guard_min_free_gb", value="15"))
    assert rc == 0
    assert Settings.load(tmp_path / "settings.yaml").disk_guard_min_free_gb == 15
