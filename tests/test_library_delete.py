"""Library delete actions: transcript files + a show's folder.

Every delete requires a TWO-step confirmation, and the folder delete refuses
to touch the output root itself or anything outside it.
"""

from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

_app = QApplication.instance() or QApplication([])
_keep: list = []


def _make_lib(tmp_path):
    from ui.app_context import AppContext
    from ui.library_tab import LibraryTab

    ctx = AppContext.load(tmp_path)
    out = tmp_path / "out"
    out.mkdir(parents=True, exist_ok=True)
    ctx.settings.output_root = str(out)
    lt = LibraryTab(ctx)
    _keep.append(lt)
    return lt, ctx, out


def _confirm_yes(lt):
    # Bypass the modal dialog — pretend the user clicked Confirm on both prompts.
    lt._confirm_delete = lambda *a, **k: True


def test_delete_transcript_unlinks_md_and_srt(tmp_path, monkeypatch):
    lt, ctx, out = _make_lib(tmp_path)
    md = out / "ep.md"
    md.write_text("x")
    srt = md.with_suffix(".srt")
    srt.write_text("y")
    monkeypatch.setattr(lt, "_row_for_guid", lambda g: {"md_path": md})
    _confirm_yes(lt)
    lt._delete_transcript("g1")
    assert not md.exists() and not srt.exists()


def test_delete_needs_both_confirmations(tmp_path, monkeypatch):
    lt, ctx, out = _make_lib(tmp_path)
    md = out / "keep.md"
    md.write_text("x")
    monkeypatch.setattr(lt, "_row_for_guid", lambda g: {"md_path": md})
    # First Confirm, second Abort → must NOT delete (two-step AND).
    calls = {"n": 0}

    def once(*a, **k):
        calls["n"] += 1
        return calls["n"] == 1

    lt._confirm_once = once
    lt._delete_transcript("g1")
    assert md.exists()
    assert calls["n"] == 2  # both prompts were shown


def test_delete_folder_removes_subfolder(tmp_path, monkeypatch):
    lt, ctx, out = _make_lib(tmp_path)
    folder = out / "myshow"
    folder.mkdir()
    (folder / "a.md").write_text("x")
    _confirm_yes(lt)
    lt._delete_show_folder("myshow")
    assert not folder.exists()


def test_delete_folder_refuses_root_and_escapes(tmp_path, monkeypatch):
    lt, ctx, out = _make_lib(tmp_path)
    _confirm_yes(lt)
    # Empty slug would resolve to the output root → refused.
    lt._delete_show_folder("")
    assert out.exists()
    # A traversal escaping the root → refused.
    outside = tmp_path / "outside"
    outside.mkdir()
    lt._delete_show_folder("../outside")
    assert outside.exists()
    assert out.exists()
