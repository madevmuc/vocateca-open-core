"""Test bootstrap: expose hyphenated dir as importable package root."""

import sys
from pathlib import Path

PKG_ROOT = Path(__file__).resolve().parent.parent  # scripts/paragraphos/
sys.path.insert(0, str(PKG_ROOT))

import sys as _sys

import pytest


@pytest.fixture(autouse=True)
def _isolate_user_data_dir(tmp_path_factory, monkeypatch):
    """Hermetic guard: no test may touch the real ~/Library/.../Paragraphos.

    Redirects ``core.paths.user_data_dir`` to a throwaway dir so any direct
    call -- or a module imported *fresh* during a test whose import-time
    ``X = user_data_dir()`` binds the patched function -- gets the tmp dir
    instead of the user's real Application Support folder. We also patch
    ``cli.DATA`` (its import-time capture) when ``cli`` is already imported.

    NOTE: ``ui.main_window.DATA_DIR`` is deliberately NOT patched here. Doing
    so for every test makes the ~handful of MainWindow-constructing tests run a
    full ``AppContext.load`` (library scan + a watchdog observer thread) against
    a fresh empty dir; that cumulative thread/event-loop churn measurably slowed
    the suite and tipped a timing-fragile, unrelated Qt test over its debounce
    window. Instead, the three test modules that build ``MainWindow`` isolate
    ``DATA_DIR`` themselves (per-test monkeypatch), so the real dir is still
    never touched while the other ~500 tests pay no extra cost.
    """
    data = tmp_path_factory.mktemp("paragraphos-data")
    import core.paths

    monkeypatch.setattr(core.paths, "user_data_dir", lambda: data, raising=True)
    mod = _sys.modules.get("cli")
    if mod is not None and hasattr(mod, "DATA"):
        monkeypatch.setattr(mod, "DATA", data, raising=False)
    yield


def _stop_running_qthreads() -> None:
    """Stop any still-running QThread so its C++ object is never destroyed while
    running (which makes Qt abort the process with SIGABRT at teardown).

    Some GUI tests start background QThreads (channel resolve / preview / feed
    fetch) that make network calls and outlive the test (kept alive by the test
    module's ``_keepalive`` lists). Graceful ``quit()`` can't interrupt a
    pure-Python ``run()``, so for anything still running we fall back to
    ``terminate()`` — safe here because it's teardown, not live operation."""
    try:
        import gc

        from PyQt6.QtCore import QThread
    except Exception:
        return
    try:
        gc.collect()
        for obj in list(gc.get_objects()):
            if not isinstance(obj, QThread):
                continue
            try:
                if not obj.isRunning():
                    continue
                obj.requestInterruption()
                obj.quit()
                if not obj.wait(300):
                    obj.terminate()
                    obj.wait(300)
            except Exception:
                pass
    except Exception:
        pass


@pytest.fixture(autouse=True)
def _join_qthreads_each_test():
    """Stop leaked background QThreads after each test so they never accumulate
    to interpreter teardown (where a still-running QThread aborts the process)."""
    yield
    _stop_running_qthreads()


@pytest.fixture(autouse=True)
def _reset_event_bus():
    """Clear core.events subscribers around every test for isolation.

    The bus is a module-level singleton; persistence + activity-bridge + ad-hoc
    test subscribers otherwise accumulate across the session and could let one
    test's emit fire another test's subscriber. Resetting per-test keeps state
    isolated. (Harmless when core.events isn't importable.)
    """
    try:
        from core import events

        events.reset()
    except Exception:
        pass
    yield
    try:
        from core import events

        events.reset()
    except Exception:
        pass


@pytest.fixture(autouse=True)
def _stub_blocking_msgboxes(monkeypatch):
    """No test may block on a modal QMessageBox under the offscreen QPA.

    The informational static dialogs (``warning`` / ``information`` /
    ``critical``) wait for an OK click and hang headless runs — e.g.
    ``AddShowDialog._add_from_youtube`` pops ``QMessageBox.warning('Resolve a
    channel URL first')`` and the suite stalls until the runner is killed.
    Stub them to return ``Ok`` without showing anything. ``question`` and
    instance ``exec`` are left alone — tests that need a specific button
    answer patch those themselves.
    """
    try:
        from PyQt6.QtWidgets import QMessageBox
    except Exception:
        return
    ok = QMessageBox.StandardButton.Ok
    for _name in ("warning", "information", "critical"):
        monkeypatch.setattr(QMessageBox, _name, staticmethod(lambda *a, **k: ok), raising=False)
    yield
