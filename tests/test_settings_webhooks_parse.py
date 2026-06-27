"""Webhook GUI editor text<->list parsing (10.1 GUI parity)."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from ui.settings_pane import SettingsPane


def test_text_to_webhooks_parses_lines():
    text = (
        "episode.transcribed,episode.failed|post|https://example.com/hook\n"
        "run.finished|command|/path/script.sh\n"
        "   \n"  # blank line ignored
        "garbline"  # too few fields ignored
    )
    out = SettingsPane._text_to_webhooks(text)
    assert len(out) == 2
    assert out[0] == {
        "events": ["episode.transcribed", "episode.failed"],
        "kind": "post",
        "target": "https://example.com/hook",
        "enabled": True,
    }
    assert out[1]["kind"] == "command"


def test_roundtrip_text_list_text():
    hooks = [
        {"events": ["run.finished"], "kind": "post", "target": "https://x/y", "enabled": True},
    ]
    text = SettingsPane._webhooks_to_text(hooks)
    assert SettingsPane._text_to_webhooks(text) == hooks


def test_empty_events_means_all():
    out = SettingsPane._text_to_webhooks("|post|https://x/y")
    assert out[0]["events"] == []
