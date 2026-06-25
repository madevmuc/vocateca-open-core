# tests/test_cli_add_backlog.py
import argparse

import cli
import core.paths
from core.watchlist_guard import is_decided


def _run_add(tmp_path, monkeypatch, backlog):
    monkeypatch.setattr(core.paths, "user_data_dir", lambda: tmp_path)
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    monkeypatch.setattr(cli, "find_rss_from_url", lambda u: "http://h/rss")
    monkeypatch.setattr(cli, "feed_metadata", lambda rss: {"title": "Pod X", "author": "A"})
    manifest = [
        {
            "guid": f"g{i}",
            "title": f"t{i}",
            "pubDate": f"2026-01-{i + 1:02d}T00:00:00",
            "mp3_url": f"http://h/{i}.mp3",
            "description": "",
        }
        for i in range(10)
    ]
    monkeypatch.setattr(cli, "build_manifest", lambda rss: manifest)
    monkeypatch.setattr(cli, "suggest_whisper_prompt", lambda **k: "prompt")
    ns = argparse.Namespace(
        name_or_url="http://h/rss", backlog=backlog, slug="pod-x", lang="de", yes=True
    )
    return cli.cmd_add(ns)


def _pending(tmp_path):
    from core.state import StateStore

    st = StateStore(tmp_path / "state.sqlite")
    with st._conn() as c:
        return c.execute(
            "SELECT COUNT(*) n FROM episodes WHERE show_slug='pod-x' AND status='pending'"
        ).fetchone()["n"]


def test_add_last5_seeds_5_pending_and_marks_decided(tmp_path, monkeypatch):
    rc = _run_add(tmp_path, monkeypatch, "last:5")
    assert rc == 0
    assert _pending(tmp_path) == 5
    from core.state import StateStore

    assert is_decided(StateStore(tmp_path / "state.sqlite"), "pod-x")


def test_add_all_seeds_everything_pending(tmp_path, monkeypatch):
    rc = _run_add(tmp_path, monkeypatch, "all")
    assert rc == 0
    assert _pending(tmp_path) == 10
