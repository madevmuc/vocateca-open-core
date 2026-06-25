import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication, QWidget


@pytest.fixture(autouse=True)
def _stub_heavy_panes(monkeypatch):
    """Stub SettingsPane + AboutPane to keep MainWindow construction
    hermetic — avoids SettingsPane's (potentially in-progress) attribute
    wiring and AboutPane's background network thread hitting GitHub.
    """
    import ui.main_window as mw

    class _StubPane(QWidget):
        def __init__(self, *a, **kw):
            super().__init__()

    monkeypatch.setattr(mw, "SettingsPane", _StubPane, raising=True)
    monkeypatch.setattr(mw, "AboutPane", _StubPane, raising=True)
    yield


def test_newshow_banner_shows_for_undecided_and_clears_when_decided(tmp_path, monkeypatch):
    _ = QApplication.instance() or QApplication([])
    import ui.main_window as mw
    from core.models import Show
    from core.watchlist_guard import mark_decided
    from ui.main_window import MainWindow

    # Isolate the data dir so this test uses a throwaway state.sqlite rather
    # than the user's real one — otherwise the mark_decided() below would
    # persist backlog_decided:new1 and make the test order-dependent / flaky.
    monkeypatch.setattr(mw, "DATA_DIR", tmp_path, raising=True)

    w = MainWindow()
    # Qt only reports isVisible() == True on a child once its top-level window
    # has been shown; show the (offscreen) window so the banner visibility
    # assertion below is meaningful.
    w.show()
    w.ctx.settings.obsidian_vault_path = ""  # keep compile/offline banners out of the way
    # an externally-added, undecided show
    w.ctx.watchlist.shows.append(Show(slug="new1", title="New One", rss="http://h/new1"))
    w._refresh_banner()
    assert w._banner_state == "newshow"
    assert w.banner.isVisible()
    assert "1" in w.banner_label.text()

    # once decided, the banner clears on next refresh
    mark_decided(w.ctx.state, "new1")
    w._refresh_banner()
    assert w._banner_state != "newshow"
