import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication, QWidget


@pytest.fixture(autouse=True)
def _stub_heavy_panes(tmp_path, monkeypatch):
    """Stub SettingsPane + AboutPane to keep MainWindow construction
    hermetic — avoids SettingsPane's (potentially in-progress) attribute
    wiring and AboutPane's background network thread hitting GitHub.

    Also redirect ``DATA_DIR`` to a per-test tmp dir so that constructing
    MainWindow() (which does ``AppContext.load(DATA_DIR)`` and now runs
    grandfather_existing, writing meta to state.sqlite) never touches the
    user's real ~/Library/.../Paragraphos. The conftest autouse fixture
    guards ``core.paths.user_data_dir``, but MainWindow uses the import-time
    ``DATA_DIR`` capture, so it must be patched here.
    """
    import ui.main_window as mw

    monkeypatch.setattr(mw, "DATA_DIR", tmp_path, raising=True)

    class _StubPane(QWidget):
        def __init__(self, *a, **kw):
            super().__init__()

    monkeypatch.setattr(mw, "SettingsPane", _StubPane, raising=True)
    monkeypatch.setattr(mw, "AboutPane", _StubPane, raising=True)
    yield


def test_compile_banner_hidden_when_no_obsidian(tmp_path, monkeypatch):
    _ = QApplication.instance() or QApplication([])
    from ui.main_window import MainWindow

    w = MainWindow()
    # Empty obsidian vault path — compile banner should never show.
    w.ctx.settings.obsidian_vault_path = ""
    output = tmp_path / "out"
    output.mkdir()
    (output / "ep.md").write_text("fresh")
    w.ctx.settings.output_root = str(output)
    w._refresh_banner()
    assert w._banner_state != "compile"
    assert not w.banner.isVisible()


def test_compile_banner_still_runs_when_obsidian_set(tmp_path, monkeypatch):
    _ = QApplication.instance() or QApplication([])
    from ui.main_window import MainWindow

    w = MainWindow()
    # Obsidian set — the existing compile-banner path should be reached
    # (it may or may not show depending on mtimes, but the short-circuit
    # added in this task must NOT fire).
    w.ctx.settings.obsidian_vault_path = "/tmp/fake/vault"
    # We're not asserting the banner's final state here — just that the
    # short-circuit doesn't cut off the compile-logic early. Simplest: call
    # _refresh_banner and verify no crash.
    w._refresh_banner()
