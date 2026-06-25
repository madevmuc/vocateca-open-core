"""GUI Add-show must mark the show backlog-decided.

A show without the ``backlog_decided:<slug>`` marker is gated/skipped by the
worker (defense-in-depth gate). The GUI Add-show dialog makes a backlog
decision in ``_do_save`` (seeds episodes + applies the backlog strategy), so it
must also set the marker — otherwise a GUI-added show would be wrongly skipped.
"""

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

_app_ref = None
_dialog_refs: list = []


def _make_dialog(tmp_path):
    global _app_ref
    _app_ref = QApplication.instance() or QApplication([])
    from ui.add_show_dialog import AddShowDialog
    from ui.app_context import AppContext

    ctx = AppContext.load(tmp_path)
    dlg = AddShowDialog(ctx, None)
    _dialog_refs.append(dlg)
    return dlg


def test_gui_add_marks_show_decided(tmp_path):
    dlg = _make_dialog(tmp_path)
    show = {
        "slug": "gui-x",
        "title": "GUI X",
        "rss": "http://h/x",
        "whisper_prompt": "",
        "manifest": [
            {
                "guid": "g1",
                "title": "t1",
                "pubDate": "2026-01-01T00:00:00",
                "mp3_url": "http://h/1.mp3",
            }
        ],
        "backlog": "All",
        "source": "podcast",
    }
    dlg._do_save(show)

    from core.watchlist_guard import is_decided

    assert is_decided(dlg.ctx.state, "gui-x")
