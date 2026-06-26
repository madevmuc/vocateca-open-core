"""The Shows tab exposes a dedicated 'Add YouTube Channel…' button that opens
the Add dialog focused on the YouTube flow — visible only when YouTube
ingestion is enabled."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.models import Settings

_app_ref = QApplication.instance() or QApplication([])
_keepalive: list = []


def _make_tab(tmp_path, settings):
    from ui.app_context import AppContext
    from ui.shows_tab import ShowsTab

    ctx = AppContext.load(tmp_path)
    ctx.settings = settings
    tab = ShowsTab(ctx)
    _keepalive.append(tab)
    return tab


def test_button_visible_when_youtube_enabled(tmp_path):
    # isVisible() is False until the window is shown; assert the explicit
    # hidden flag instead (matches the dialog tests' convention).
    tab = _make_tab(tmp_path, Settings(sources_youtube=True))
    assert not tab.add_youtube_btn.isHidden()


def test_button_hidden_when_youtube_disabled(tmp_path):
    tab = _make_tab(tmp_path, Settings(sources_youtube=False))
    assert tab.add_youtube_btn.isHidden()


def test_button_opens_dialog_in_youtube_mode(tmp_path, monkeypatch):
    tab = _make_tab(tmp_path, Settings(sources_youtube=True))
    captured = {}

    import ui.add_show_dialog as mod

    real_init = mod.AddShowDialog.__init__

    def _spy_init(self, ctx, parent=None, *, initial_mode=None):
        captured["initial_mode"] = initial_mode
        real_init(self, ctx, parent, initial_mode=initial_mode)

    monkeypatch.setattr(mod.AddShowDialog, "__init__", _spy_init)
    # Don't actually run the modal loop.
    monkeypatch.setattr(mod.AddShowDialog, "exec", lambda self: 0)

    tab._add_youtube()
    assert captured.get("initial_mode") == "youtube"
