"""Crash logging excepthook + bug-report bundle (6.4)."""

from __future__ import annotations

import json
import zipfile

from core import bugbundle
from core.models import Settings
from core.state import StateStore


def test_redact_strips_paths_and_secrets():
    raw = {
        "output_root": "/Users/alice/Desktop/transcripts",
        "obsidian_vault_path": "/Users/alice/vault",
        "knowledge_hub_root": "/Users/alice/kb",
        "github_repo": "me/fork",
        "load_level": "balanced",
        "disk_guard_min_free_gb": 5,
    }
    red = bugbundle.redact_settings(raw)
    assert "alice" not in json.dumps(red)
    assert red["output_root"] == "<redacted-path>"
    assert red["obsidian_vault_path"] == "<redacted-path>"
    # non-sensitive values pass through
    assert red["load_level"] == "balanced"
    assert red["disk_guard_min_free_gb"] == 5


def test_build_bundle_contains_expected_files(tmp_path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    from core import events
    from core.events import Event, EventType

    state.append_event(Event(type=EventType.RUN_FINISHED, ts=events.now_iso()))

    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    (log_dir / "paragraphos.log").write_text("hello log\n", encoding="utf-8")

    dest = tmp_path / "bundle.zip"
    out = bugbundle.build_bundle(settings=Settings(), state=state, dest=dest, log_dir=log_dir)
    assert out.exists()
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        assert any(n.endswith("settings.json") for n in names)
        assert any(n.endswith("events.json") for n in names)
        assert any(n.endswith("versions.txt") for n in names)
        assert any("paragraphos.log" in n for n in names)
        # redaction: the settings in the zip must not leak the real home path
        settings_blob = z.read(next(n for n in names if n.endswith("settings.json"))).decode()
        assert "<redacted-path>" in settings_blob


def test_install_excepthook_logs(monkeypatch):
    logged = []
    bugbundle.install_excepthook(log=lambda msg: logged.append(msg))
    try:
        raise RuntimeError("synthetic boom")
    except RuntimeError:
        import sys

        # Invoke the installed hook directly with this exception.
        sys.excepthook(*sys.exc_info())
    assert any("synthetic boom" in m for m in logged)
