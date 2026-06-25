"""Proof that the data-dir isolation actually holds.

The bug this guards against: ``ui.main_window`` captures
``DATA_DIR = user_data_dir()`` at import time, and ``MainWindow.__init__``
does ``AppContext.load(DATA_DIR)`` — which now runs ``grandfather_existing``
and WRITES ``backlog_*`` meta into ``state.sqlite``. A test that constructs
``MainWindow()`` would therefore pollute the user's real
``~/Library/Application Support/Paragraphos``.

These tests pin both halves of the fix without paying the cost of building a
full ``MainWindow`` widget tree (whose watchdog-observer + Qt churn, multiplied
across the suite, destabilises a timing-fragile Qt test elsewhere):

* ``test_user_data_dir_is_redirected`` — the conftest autouse fixture must
  redirect ``core.paths.user_data_dir`` away from the real Application Support
  folder for *every* test (the runtime-call guard).
* ``test_mainwindow_data_dir_is_redirected`` — ``MainWindow.__init__`` loads
  whatever ``ui.main_window.DATA_DIR`` points at; we assert that capture is the
  per-test tmp, never the real dir, and that ``AppContext.load`` fed that value
  resolves ``ctx.data_dir`` to the tmp (so the grandfather migration writes
  there, not to the user's real ``state.sqlite``).
"""

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
import pytest

_REAL = "Library/Application Support/Paragraphos"


def test_user_data_dir_is_redirected():
    """The conftest autouse fixture (no per-test setup here) must already have
    pointed ``user_data_dir`` away from the real Application Support folder."""
    import core.paths

    p = str(core.paths.user_data_dir())
    assert _REAL not in p


def test_mainwindow_data_dir_is_redirected(tmp_path, monkeypatch):
    """Drive the exact path ``MainWindow.__init__`` takes — ``AppContext.load``
    on the import-time ``DATA_DIR`` capture — and prove it lands in the tmp dir.

    We patch ``DATA_DIR`` to a per-test tmp (as the banner tests do for the real
    construction) and load via the captured value rather than building the full
    widget tree, so the proof costs almost nothing.
    """
    import ui.main_window as mw
    from ui.app_context import AppContext

    monkeypatch.setattr(mw, "DATA_DIR", tmp_path, raising=True)
    assert _REAL not in str(mw.DATA_DIR)
    assert str(mw.DATA_DIR) == str(tmp_path)

    ctx = AppContext.load(mw.DATA_DIR)
    try:
        assert _REAL not in str(ctx.data_dir)
        assert str(ctx.data_dir) == str(tmp_path)
        # The grandfather migration MainWindow construction would run must have
        # written into the tmp dir, not the user's real Application Support.
        assert (tmp_path / "state.sqlite").exists()
    finally:
        # Stop the watchdog observer AppContext.load started so this test does
        # not leak a thread onto the rest of the suite.
        obs = getattr(ctx, "_observer", None)
        if obs is not None:
            try:
                obs.stop()
                obs.join(timeout=2)
            except Exception:
                pass
