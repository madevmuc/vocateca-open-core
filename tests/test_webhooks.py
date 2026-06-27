"""Event-driven webhooks (10.1)."""

from __future__ import annotations

import json

import pytest

from core import webhooks
from core.events import Event, EventType


def _ev(t=EventType.EPISODE_TRANSCRIBED):
    return Event(type=t, ts="2026-01-01T00:00:00+00:00", show_slug="sh", guid="g1")


def test_webhook_matches():
    assert webhooks.webhook_matches({"events": ["episode.transcribed"]}, "episode.transcribed")
    assert webhooks.webhook_matches({"events": ["episode."]}, "episode.failed")
    assert webhooks.webhook_matches({"events": []}, "anything")  # empty = all
    assert not webhooks.webhook_matches({"events": ["run.finished"]}, "episode.failed")
    assert not webhooks.webhook_matches(
        {"events": ["episode.failed"], "enabled": False}, "episode.failed"
    )


def test_dispatch_fires_only_for_matching():
    calls = []
    cfg = [
        {"events": ["episode.transcribed"], "kind": "command", "target": "a"},
        {"events": ["run.finished"], "kind": "command", "target": "b"},
    ]
    webhooks.dispatch(
        _ev(EventType.EPISODE_TRANSCRIBED),
        cfg,
        run_command=lambda target, ev: calls.append(target),
        http_post=lambda target, ev: calls.append(target),
    )
    assert calls == ["a"]


def test_dispatch_swallows_failure_and_continues():
    calls = []

    def boom(target, ev):
        raise RuntimeError("nope")

    cfg = [
        {"events": [], "kind": "command", "target": "x"},
        {"events": [], "kind": "post", "target": "y"},
    ]
    # First raises; second must still run; dispatch never raises.
    webhooks.dispatch(
        _ev(),
        cfg,
        run_command=boom,
        http_post=lambda target, ev: calls.append(target),
    )
    assert calls == ["y"]


def test_event_to_json_is_serialisable():
    payload = json.loads(webhooks.event_to_json(_ev()))
    assert payload["type"] == EventType.EPISODE_TRANSCRIBED
    assert payload["guid"] == "g1"


def test_run_command_splits_arguments(monkeypatch):
    captured = {}

    def fake_run(argv, **kw):
        captured["argv"] = argv

    monkeypatch.setattr(webhooks.subprocess, "run", fake_run)
    webhooks._run_command("/path/notify.sh --tag run --quiet", _ev())
    assert captured["argv"] == ["/path/notify.sh", "--tag", "run", "--quiet"]


def test_dispatch_one_runs_matching_command():
    calls = []
    webhooks._dispatch_one(
        _ev(),
        {"events": [], "kind": "command", "target": "x"},
        run_command=lambda t, e: calls.append(t),
        http_post=lambda t, e: calls.append(t),
    )
    assert calls == ["x"]


def test_http_post_rejects_internal_url():
    from core.security import UnsafeURLError

    with pytest.raises(UnsafeURLError):
        webhooks._http_post("http://127.0.0.1:8080/hook", _ev())


def test_http_post_rejects_file_scheme():
    from core.security import UnsafeURLError

    with pytest.raises(UnsafeURLError):
        webhooks._http_post("file:///etc/passwd", _ev())
