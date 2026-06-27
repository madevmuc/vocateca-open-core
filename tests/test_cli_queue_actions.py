"""CLI per-episode queue actions: deactivate / activate / dequeue.

Mirror the GUI Queue context-menu actions for the headless / LLM-operator path.
"""

import argparse

import cli
import core.paths
from core.state import EpisodeStatus, StateStore


def _wire(tmp_path, monkeypatch):
    monkeypatch.setattr(core.paths, "user_data_dir", lambda: tmp_path)
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    st = StateStore(tmp_path / "state.sqlite")
    st.init_schema()
    st.upsert_episode(
        show_slug="s",
        guid="g1",
        title="Ep",
        pub_date="2026-06-01",
        mp3_url="https://www.youtube.com/watch?v=g1",
    )
    return st


def _status(st, guid="g1"):
    return st.get_episode(guid)["status"]


def test_deactivate_sets_paused(tmp_path, monkeypatch):
    st = _wire(tmp_path, monkeypatch)
    assert cli.cmd_deactivate(argparse.Namespace(guid="g1")) == 0
    assert _status(st) == "paused"


def test_activate_sets_pending(tmp_path, monkeypatch):
    st = _wire(tmp_path, monkeypatch)
    st.set_status("g1", EpisodeStatus.PAUSED)
    assert cli.cmd_activate(argparse.Namespace(guid="g1")) == 0
    assert _status(st) == "pending"


def test_dequeue_sets_skipped(tmp_path, monkeypatch):
    st = _wire(tmp_path, monkeypatch)
    assert cli.cmd_dequeue(argparse.Namespace(guid="g1")) == 0
    assert _status(st) == "skipped"


def test_unknown_guid_exits_2(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    for fn in (cli.cmd_deactivate, cli.cmd_activate, cli.cmd_dequeue):
        assert fn(argparse.Namespace(guid="nope")) == 2
