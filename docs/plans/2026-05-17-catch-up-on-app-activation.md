# Catch-up on App Activation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Run a missed daily check the next time the app is brought to the foreground (Mac was off / busy / check failed at the scheduled slot), and stop a failed check from falsely marking the slot as done.

**Architecture:** Two decoupled changes in `app.py` plus one pure helper in `core/scheduler.py`. (1) A Qt-free `check_counts_as_success()` gate decides whether `_on_check_done` advances `last_successful_check`. (2) A `QApplication.applicationStateChanged` hook re-runs the existing `should_catch_up` catch-up path on `ApplicationActive`, guarded so it never doubles a running check or re-fires within the same daily slot.

**Tech Stack:** Python 3.12, PyQt6, APScheduler, pytest, ruff. Design doc: `docs/plans/2026-05-17-catch-up-on-app-activation-design.md`.

---

### Task 1: Pure success-gate helper

**Files:**
- Modify: `core/scheduler.py` (append function)
- Test: `tests/test_scheduler.py` (append tests)

**Step 1: Write the failing tests**

Append to `tests/test_scheduler.py`:

```python
from core.scheduler import check_counts_as_success


def test_success_when_clean_run_online():
    assert check_counts_as_success(stopped=False, paused=False, online=True) is True


def test_not_success_when_stopped():
    assert check_counts_as_success(stopped=True, paused=False, online=True) is False


def test_not_success_when_paused():
    assert check_counts_as_success(stopped=False, paused=True, online=True) is False


def test_not_success_when_offline():
    assert check_counts_as_success(stopped=False, paused=False, online=False) is False
```

**Step 2: Run tests to verify they fail**

Run: `pytest tests/test_scheduler.py -v -k success`
Expected: FAIL — `ImportError: cannot import name 'check_counts_as_success'`

**Step 3: Write minimal implementation**

Append to `core/scheduler.py`:

```python
def check_counts_as_success(*, stopped: bool, paused: bool, online: bool) -> bool:
    """A daily check only advances ``last_successful_check`` when it ran
    cleanly: not user-stopped / offline-paused, queue not paused, and the
    network was up. Individual feed errors still count as success — they
    have their own 1/3/7-day backoff, so one broken feed must not trigger
    an endless catch-up loop."""
    return not stopped and not paused and online
```

**Step 4: Run tests to verify they pass**

Run: `pytest tests/test_scheduler.py -v -k success`
Expected: PASS (4 passed)

**Step 5: Commit**

```bash
git add core/scheduler.py tests/test_scheduler.py
git commit -m "feat(scheduler): add check_counts_as_success success-gate helper"
```

---

### Task 2: Wire the success gate into `_on_check_done`

**Files:**
- Modify: `app.py:585-589` (`_on_check_done`)
- Modify: `app.py:37` (import)

**Step 1: Add the import**

At `app.py:37`, extend the existing scheduler import:

```python
from core.scheduler import check_counts_as_success, should_catch_up  # noqa: E402
```

**Step 2: Replace the unconditional timestamp write**

In `_on_check_done` (currently `app.py:585-589`), replace:

```python
    def _on_check_done(self) -> None:
        self.ctx.state.set_meta(
            "last_successful_check",
            datetime.now(timezone.utc).isoformat(),
        )
```

with:

```python
    def _on_check_done(self) -> None:
        from core.connectivity import is_online

        stopped = bool(getattr(self._thread, "_stop", False)) if self._thread else False
        paused = self.ctx.state.get_meta("queue_paused") == "1"
        if check_counts_as_success(stopped=stopped, paused=paused, online=is_online()):
            self.ctx.state.set_meta(
                "last_successful_check",
                datetime.now(timezone.utc).isoformat(),
            )
```

The rest of `_on_check_done` (notification, tray reset) stays unchanged and still runs on every finish.

**Step 3: Sanity-check nothing else broke**

Run: `pytest tests/test_app_tally.py tests/test_scheduler.py -v`
Expected: PASS (existing app-tally + scheduler tests still green)

**Step 4: Commit**

```bash
git add app.py
git commit -m "fix(app): only advance last_successful_check on a clean online check"
```

---

### Task 3: Activation hook

**Files:**
- Modify: `app.py:20` (import `Qt`)
- Modify: `app.py:341-346` (store delay on `self`, connect signal)
- Modify: `app.py` (add `_on_app_activated` method, e.g. right after `_run_check`)

**Step 1: Import `Qt`**

At `app.py:20`, add `Qt` to the QtCore import:

```python
from PyQt6.QtCore import QEvent, QObject, Qt, QTimer, pyqtSignal
```

**Step 2: Store the auto-start delay on `self` and connect the signal**

In `__init__`, just after `self._sched.start()` (currently `app.py:341`) and before the `_delay_ms` block, persist the delay so the hook can reuse it. Change the existing line:

```python
        _delay_ms = max(0, int(getattr(self.ctx.settings, "auto_start_delay_seconds", 5))) * 1000
```

to:

```python
        _delay_ms = max(0, int(getattr(self.ctx.settings, "auto_start_delay_seconds", 5))) * 1000
        self._auto_start_delay_ms = _delay_ms
        _qapp = QApplication.instance()
        if _qapp is not None:
            _qapp.applicationStateChanged.connect(self._on_app_activated)
```

**Step 3: Add the hook method**

Add this method to the same class, immediately after `_run_check` (after `app.py:488`):

```python
    def _on_app_activated(self, state) -> None:
        """Catch up a missed daily check when the app is brought to the
        foreground. ``should_catch_up`` gates this to once per daily slot
        (it compares against last_successful_check), so this does not
        re-fire on every tray click within the same day."""
        if state != Qt.ApplicationState.ApplicationActive:
            return
        if not self.ctx.settings.catch_up_missed:
            return
        if self._is_queue_busy():
            return
        if not should_catch_up(
            self.ctx.state.get_meta("last_successful_check"),
            self.ctx.settings.daily_check_time,
        ):
            return
        self.ctx.state.set_meta("queue_paused", "0")
        QTimer.singleShot(self._auto_start_delay_ms, self._run_check)
```

**Step 4: Lint + full unit suite**

Run: `ruff check app.py core/scheduler.py && pytest tests/ -q`
Expected: ruff clean; full unit suite PASS (no regressions; pre-existing pass count from README is 429 — expect that plus the 4 new scheduler tests).

**Step 5: Commit**

```bash
git add app.py
git commit -m "feat(app): catch up a missed daily check on app activation"
```

---

### Task 4: Manual smoke test + plan close-out

The activation hook is a Qt signal and is not unit-tested headless; verify by hand.

**Step 1: Force a "missed" state**

In a Python REPL against the app's state DB (or via the app stopped), set `last_successful_check` to yesterday and ensure `catch_up_missed` is on in Settings, `daily_check_time` is in the past for today.

**Step 2: Run the app, defocus, refocus**

Run: `python app.py`
- Let it finish launch catch-up (or set state so launch catch-up does not fire).
- Click another app to deactivate, then click the Paragraphos tray icon / window to reactivate.
- Expected: after `auto_start_delay_seconds`, a check starts (visible in the tray status block / Shows tab).

**Step 3: Verify no double-fire**

- With a fresh successful check just completed (today, after slot), deactivate/reactivate repeatedly.
- Expected: no new check starts (guarded by `should_catch_up`).

**Step 4: Verify busy-guard**

- While a check is running, deactivate/reactivate.
- Expected: no second check starts ("A check is already running." path is never reached because `_is_queue_busy()` short-circuits first).

**Step 5: Mark design doc done and commit notes if any**

If the smoke test surfaces fixes, fold them into the relevant task above and re-run. Otherwise:

```bash
git commit --allow-empty -m "test(app): manual smoke of activation catch-up — passed"
```

---

## Notes

- DRY: reuses `should_catch_up`, `_is_queue_busy`, `_run_check`, and the
  existing `_delay_ms` value — no parallel catch-up logic.
- YAGNI: no Mac-wake detection, no periodic timer, no new state field —
  explicitly scoped out in the design.
- `is_online()` is a ~2 s blocking probe on the GUI thread, called once
  per check completion only — acceptable, documented in the design.
