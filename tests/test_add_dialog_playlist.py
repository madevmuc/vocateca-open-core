"""Add-dialog playlist enumeration path (3.2 GUI parity)."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication

import ui.add_show_dialog as asd

_KEEP: list = []


@pytest.fixture
def qapp():
    app = QApplication.instance() or QApplication([])
    _KEEP.append(app)
    return app


def test_enumerate_thread_uses_playlist_source(qapp, monkeypatch):
    calls = {}

    def fake_enum_playlist(pid, *, limit=None, date_after=None, full=False):
        calls["playlist_id"] = pid
        calls["full"] = full
        return [
            {"id": "v1", "title": "One", "upload_date": "20260101"},
            {"id": "v2", "title": "Two", "upload_date": "20260102"},
        ]

    monkeypatch.setattr(asd._youtube_meta, "enumerate_playlist_videos", fake_enum_playlist)
    monkeypatch.setattr(asd._rss, "build_manifest", lambda url: [])

    thread = asd._YoutubeEnumerateThread("", limit=10, playlist_id="PLabc", parent=None)
    _KEEP.append(thread)
    got = {}
    thread.done.connect(lambda m: got.update({"manifest": m}))
    thread.run()  # synchronous — runs the body in-thread and emits done

    assert calls["playlist_id"] == "PLabc"
    assert calls["full"] is True
    guids = {ep["guid"] for ep in got["manifest"]}
    assert guids == {"v1", "v2"}
