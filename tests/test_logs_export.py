"""Event log filtering + export (7.3)."""

from __future__ import annotations

import csv
import json

from core import events
from core.events import Event, EventType
from core.log_export import export_events
from core.state import StateStore


def _store(tmp_path):
    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    for t, slug in [
        (EventType.EPISODE_TRANSCRIBED, "a"),
        (EventType.EPISODE_FAILED, "a"),
        (EventType.FEED_CHECKED, "b"),
    ]:
        s.append_event(Event(type=t, ts=events.now_iso(), show_slug=slug, payload={"k": "v"}))
    return s


def test_filter_by_type_prefix(tmp_path):
    s = _store(tmp_path)
    rows = s.query_events(type_prefix="episode.")
    assert {r["type"] for r in rows} == {
        EventType.EPISODE_TRANSCRIBED,
        EventType.EPISODE_FAILED,
    }


def test_filter_by_show(tmp_path):
    s = _store(tmp_path)
    rows = s.query_events(show_slug="b")
    assert len(rows) == 1 and rows[0]["type"] == EventType.FEED_CHECKED


def test_export_json(tmp_path):
    s = _store(tmp_path)
    rows = s.query_events()
    dest = tmp_path / "out.json"
    export_events(rows, "json", dest)
    data = json.loads(dest.read_text(encoding="utf-8"))
    assert len(data) == 3
    assert data[0]["type"]


def test_export_csv(tmp_path):
    s = _store(tmp_path)
    rows = s.query_events()
    dest = tmp_path / "out.csv"
    export_events(rows, "csv", dest)
    with open(dest, newline="", encoding="utf-8") as f:
        read = list(csv.DictReader(f))
    assert len(read) == 3
    assert "type" in read[0] and "ts" in read[0]


def test_export_unknown_format_raises(tmp_path):
    import pytest

    with pytest.raises(ValueError):
        export_events([], "xml", tmp_path / "x.xml")


def test_cli_logs_export(tmp_path, monkeypatch):
    import argparse

    import cli

    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    s = cli._state()
    s.append_event(Event(type=EventType.RUN_FINISHED, ts=events.now_iso()))
    dest = tmp_path / "log.json"
    rc = cli.cmd_logs(
        argparse.Namespace(
            type=None, show=None, since=None, limit=200, export=str(dest), json=False
        )
    )
    assert rc == 0
    assert json.loads(dest.read_text(encoding="utf-8"))
