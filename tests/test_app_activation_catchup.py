"""Headless smoke of the app-activation catch-up hook.

The real GUI smoke test (macOS focus changes, tray toast observation) is
manual — see ``docs/plans/2026-05-17-catch-up-on-app-activation.md`` Task 4.
This drives the *real* ``ParagraphosApp._on_app_activated`` against a
minimal stand-in ``self`` plus a real ``StateStore`` and ``Settings`` so
the ``should_catch_up`` gating and the ``_catch_up_pending`` re-entrancy
latch are exercised for real. ``QTimer.singleShot`` is captured (not run
on an event loop) and ``_run_check`` is a counter, so no Qt loop, no
window/tray, and no real downloads.
"""

from __future__ import annotations

import types
from datetime import datetime, timezone

import pytest
from PyQt6.QtCore import Qt

import app as app_module
from core.models import Settings
from core.scheduler import check_counts_as_success
from core.state import StateStore

ACTIVE = Qt.ApplicationState.ApplicationActive
INACTIVE = Qt.ApplicationState.ApplicationInactive


class _FakeApp:
    """Carries exactly the attributes ``_on_app_activated`` touches."""

    def __init__(self, state: StateStore, settings: Settings, *, busy: bool = False):
        from pathlib import Path

        from core.models import Watchlist

        # Extend ctx with the attributes the new _maybe_reload_watchlist
        # checkpoint touches. With _watchlist_hash="" (empty baseline),
        # is_external_change returns False, so the reload is a safe no-op and
        # never reads the (nonexistent) data_dir/watchlist.yaml path.
        self.ctx = types.SimpleNamespace(
            state=state,
            settings=settings,
            data_dir=Path("/nonexistent"),
            watchlist=Watchlist(),
            _watchlist_hash="",
        )
        # Exercise the REAL checkpoint; the empty baseline above makes it a
        # safe no-op (no file read), so the catch-up assertions are unaffected.
        self._maybe_reload_watchlist = lambda: app_module.ParagraphosApp._maybe_reload_watchlist(
            self
        )
        # _on_app_activated now also runs the 24h auto-accept sweep. With an
        # EMPTY watchlist, undecided_slugs returns [] → safe no-op, so the
        # catch-up assertions below are unaffected.
        self._auto_accept_overdue = lambda: app_module.ParagraphosApp._auto_accept_overdue(self)
        self._is_queue_busy = lambda: busy
        self._catch_up_pending = False
        self._auto_start_delay_ms = 5000
        self.run_check_calls = 0

    def _run_check(self, *, force: bool = False) -> None:
        self.run_check_calls += 1


@pytest.fixture()
def state(tmp_path) -> StateStore:
    s = StateStore(tmp_path / "state.sqlite")
    s.init_schema()
    return s


@pytest.fixture()
def scheduled(monkeypatch):
    """Capture QTimer.singleShot(delay, cb) calls instead of running them."""
    calls: list[tuple[int, object]] = []

    class _Timer:
        @staticmethod
        def singleShot(delay, cb):
            calls.append((delay, cb))

    monkeypatch.setattr(app_module, "QTimer", _Timer)
    return calls


def _activate(fake: _FakeApp, st=ACTIVE) -> None:
    # Call the real unbound method against the fake self.
    app_module.ParagraphosApp._on_app_activated(fake, st)


def test_catch_up_due_schedules_once_and_runs(state, scheduled):
    """Fresh state (no last_successful_check) → activation schedules a
    catch-up; running the scheduled callback clears the latch and fires
    _run_check exactly once."""
    fake = _FakeApp(state, Settings())  # catch_up_missed=True by default

    _activate(fake)

    assert len(scheduled) == 1
    assert fake._catch_up_pending is True
    assert state.get_meta("queue_paused") == "0"
    assert fake.run_check_calls == 0  # not until the timer fires

    delay, cb = scheduled[0]
    assert delay == fake._auto_start_delay_ms
    cb()  # the lambda: clears the latch, then _run_check()
    assert fake._catch_up_pending is False
    assert fake.run_check_calls == 1


def test_reentrant_activation_within_delay_window_does_not_double_schedule(state, scheduled):
    """Refocusing while the catch-up timer is still pending must NOT queue
    a second _run_check (the spurious 'already running' toast guard)."""
    fake = _FakeApp(state, Settings())

    _activate(fake)
    _activate(fake)  # user Cmd-Tabs away and back inside the delay window
    _activate(fake)

    assert len(scheduled) == 1  # latch held — only the first one


def test_busy_guard_blocks_activation_catchup(state, scheduled):
    """A check already running → activation must not schedule another."""
    fake = _FakeApp(state, Settings(), busy=True)

    _activate(fake)

    assert scheduled == []
    assert fake._catch_up_pending is False


def test_catch_up_missed_off_disables_activation_path(state, scheduled):
    """catch_up_missed=False fully disables the new activation trigger."""
    fake = _FakeApp(state, Settings(catch_up_missed=False))

    _activate(fake)

    assert scheduled == []


def test_non_active_state_is_ignored(state, scheduled):
    """Only ApplicationActive triggers; deactivation must do nothing."""
    fake = _FakeApp(state, Settings())

    _activate(fake, INACTIVE)

    assert scheduled == []
    assert fake._catch_up_pending is False


def test_successful_check_today_suppresses_refire(state, scheduled):
    """A clean check already recorded today (after the slot) → should_catch_up
    is False → activation does not re-fire."""
    state.set_meta("last_successful_check", datetime.now(timezone.utc).isoformat())
    fake = _FakeApp(state, Settings(daily_check_time="00:00"))

    _activate(fake)

    assert scheduled == []


def test_failed_check_keeps_slot_eligible_then_activation_retries(state, scheduled):
    """Composition of the Task 2 gate and the Task 3 hook: an offline check
    must NOT advance last_successful_check, so a later activation still
    catches up."""
    # Simulate the _on_check_done success gate for an offline run.
    if check_counts_as_success(stopped=False, paused=False, online=False):
        state.set_meta("last_successful_check", datetime.now(timezone.utc).isoformat())

    # Gate returned False → timestamp stayed unset → slot still eligible.
    assert state.get_meta("last_successful_check") is None

    fake = _FakeApp(state, Settings())
    _activate(fake)

    assert len(scheduled) == 1  # the failed check gets retried on activation
