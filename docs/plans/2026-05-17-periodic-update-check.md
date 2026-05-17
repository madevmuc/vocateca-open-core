# Periodic Update Check on App Activation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Re-check GitHub releases when the app is brought to the foreground (≤1×/24h, opt-out setting), with the tray notification deduped to once per version tag.

**Architecture:** Two Qt-free pure helpers in `core/updater.py` (`should_recheck_update`, `should_notify_tag`) drive the decisions. A new `update_check_enabled` Settings flag gates both the existing startup check and a new, fully decoupled `applicationStateChanged` slot `_on_activation_update_check` (independent of the catch-up slot — `_on_app_activated` is not touched). A QSettings `updater/notified_tag` gate in `_on_update_available` makes the tray notification fire once per tag.

**Tech Stack:** Python 3.12, PyQt6, pytest, ruff. Env: pytest/ruff run as `.venv/bin/python -m pytest` / `.venv/bin/python -m ruff` (system python is 2.7; deps in `.venv`). Pre-commit hook runs ruff + ruff format + pytest on staged files — let it run, never `--no-verify`. Design doc: `docs/plans/2026-05-17-periodic-update-check-design.md`.

---

### Task 1: Pure helpers `should_recheck_update` + `should_notify_tag`

**Files:**
- Modify: `core/updater.py` (imports + append two functions)
- Test: `tests/test_updater.py` (append tests)

**Step 1: Write the failing tests**

Append to `tests/test_updater.py`:

```python
from datetime import datetime, timedelta, timezone

from core.updater import should_notify_tag, should_recheck_update

_NOW = datetime(2026, 5, 17, 12, 0, tzinfo=timezone.utc)


def test_recheck_when_never_checked():
    assert should_recheck_update(None, _NOW) is True
    assert should_recheck_update("", _NOW) is True


def test_no_recheck_within_interval():
    last = (_NOW - timedelta(hours=5)).isoformat()
    assert should_recheck_update(last, _NOW) is False


def test_recheck_after_interval():
    last = (_NOW - timedelta(hours=25)).isoformat()
    assert should_recheck_update(last, _NOW) is True


def test_recheck_at_exact_boundary():
    last = (_NOW - timedelta(hours=24)).isoformat()
    assert should_recheck_update(last, _NOW) is True


def test_recheck_on_garbage_timestamp():
    assert should_recheck_update("not-a-date", _NOW) is True


def test_should_notify_tag_only_on_change():
    assert should_notify_tag("", "v1.4.0") is True
    assert should_notify_tag("v1.3.0", "v1.4.0") is True
    assert should_notify_tag("v1.4.0", "v1.4.0") is False
```

**Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_updater.py -v -k "recheck or notify_tag"`
Expected: FAIL — `ImportError: cannot import name 'should_notify_tag'`

**Step 3: Write minimal implementation**

In `core/updater.py`, change the imports block (currently lines 14-16):

```python
import logging
import threading
from datetime import datetime, timedelta
from typing import Callable, Optional
```

Append at end of `core/updater.py`:

```python
def should_recheck_update(
    last_iso: Optional[str], now: datetime, min_interval_h: float = 24.0
) -> bool:
    """True when a periodic re-check is due: never checked, an unparseable
    stored timestamp (defensively re-check), or at least ``min_interval_h``
    hours since the last check."""
    if not last_iso:
        return True
    try:
        last = datetime.fromisoformat(last_iso)
    except ValueError:
        return True
    return (now - last) >= timedelta(hours=min_interval_h)


def should_notify_tag(notified_tag: str, tag: str) -> bool:
    """True when this release tag has not yet been surfaced via a tray
    notification — so the user is pinged once per version, not once per
    check/launch."""
    return notified_tag != tag
```

**Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_updater.py -v`
Expected: PASS (the 5 pre-existing + 6 new = 11 passed)

**Step 5: Commit**

```bash
git add core/updater.py tests/test_updater.py
git commit -m "feat(updater): add should_recheck_update + should_notify_tag helpers"
```

---

### Task 2: `update_check_enabled` setting + gate the startup check

**Files:**
- Modify: `core/models.py` (Settings — add field near `catch_up_missed`)
- Modify: `app.py:275-280` (wrap startup `check_for_update` in the setting)

**Step 1: Add the setting field**

In `core/models.py`, in `class Settings(BaseModel)`, immediately after the line `catch_up_missed: bool = True` add:

```python
    # Master switch for the GitHub-release update check — gates BOTH the
    # once-at-startup check and the on-activation re-check. Off → zero
    # GitHub requests (honours the "no telemetry" stance).
    update_check_enabled: bool = True
```

**Step 2: Gate the startup check**

In `app.py`, the block at lines 275-280 currently reads:

```python
        self.update_available.connect(self._on_update_available)
        check_for_update(
            local_version=_LOCAL_VERSION,
            on_update_available=lambda tag, url: self.update_available.emit(tag, url),
            repo=self.ctx.settings.github_repo,
        )
```

Replace with:

```python
        self.update_available.connect(self._on_update_available)
        if self.ctx.settings.update_check_enabled:
            check_for_update(
                local_version=_LOCAL_VERSION,
                on_update_available=lambda tag, url: self.update_available.emit(tag, url),
                repo=self.ctx.settings.github_repo,
            )
```

(The `self.update_available.connect(...)` stays unconditional so a later
re-check can still surface — only the *startup* call is gated.)

**Step 3: Verify nothing broke**

Run: `.venv/bin/python -m pytest tests/test_updater.py tests/test_scheduler.py -q`
Expected: PASS (no regressions)

**Step 4: Commit**

```bash
git add core/models.py app.py
git commit -m "feat(updater): add update_check_enabled setting, gate startup check"
```

---

### Task 3: Settings-pane checkbox for `update_check_enabled`

**Files:**
- Modify: `ui/settings_pane.py` (add checkbox after the `catchup` field ~line 440; add save line ~line 1034)

**Step 1: Add the checkbox widget**

In `ui/settings_pane.py`, immediately after the `catchup` `self._add_field(...)` block (it ends at the line after `hint_kind="good",` / closing `)`, right before `self.auto_start = QCheckBox()` at ~line 440) insert:

```python
        self.update_check = QCheckBox()
        self.update_check.setChecked(self.ctx.settings.update_check_enabled)
        self.update_check.stateChanged.connect(self._schedule_save)
        self._add_field(
            f2,
            "Check for updates",
            self.update_check,
            hint="checks GitHub for new releases on launch and when reopened",
            hint_kind="info",
        )
```

**Step 2: Persist it in `_do_save`**

In `ui/settings_pane.py` `_do_save`, immediately after the line
`s.catch_up_missed = self.catchup.isChecked()` add:

```python
        s.update_check_enabled = self.update_check.isChecked()
```

**Step 3: Verify settings-pane tests still pass**

Run: `.venv/bin/python -m pytest tests/ -q -k "settings or setting"`
Expected: PASS (no regressions; if no such tests exist, run `.venv/bin/python -m pytest tests/ -q` and confirm full suite green)

**Step 4: Commit**

```bash
git add ui/settings_pane.py
git commit -m "feat(settings): expose update_check_enabled checkbox"
```

---

### Task 4: `_on_activation_update_check` slot + wire it up

**Files:**
- Modify: `app.py` (add method after `_on_app_activated`; add a second `applicationStateChanged.connect` in `__init__`)

**Step 1: Connect the new slot**

In `app.py.__init__`, the block at ~lines 349-351 currently reads:

```python
        _qapp = QApplication.instance()
        if _qapp is not None:
            _qapp.applicationStateChanged.connect(self._on_app_activated)
```

Change it to also connect the new, independent slot:

```python
        _qapp = QApplication.instance()
        if _qapp is not None:
            _qapp.applicationStateChanged.connect(self._on_app_activated)
            _qapp.applicationStateChanged.connect(self._on_activation_update_check)
```

**Step 2: Add the slot method**

In `app.py`, add this method immediately AFTER the `_on_app_activated`
method ends (after its `QTimer.singleShot(... lambda ...)` block, before
`_on_episode_done`). Do NOT modify `_on_app_activated` or its
`_catch_up_pending` latch:

```python
    def _on_activation_update_check(self, state: Qt.ApplicationState) -> None:
        """Re-check GitHub releases when the app is foregrounded, gated to
        once per 24h via ``last_update_check`` meta. Fully decoupled from
        the catch-up slot — a user with catch_up_missed off (or no missed
        daily check) must still get update checks. ``check_for_update``
        spawns its own daemon thread, so this returns immediately."""
        from core.updater import check_for_update, should_recheck_update

        if state != Qt.ApplicationState.ApplicationActive:
            return
        if not self.ctx.settings.update_check_enabled:
            return
        now = datetime.now(timezone.utc)
        if not should_recheck_update(self.ctx.state.get_meta("last_update_check"), now):
            return
        self.ctx.state.set_meta("last_update_check", now.isoformat())
        check_for_update(
            local_version=_LOCAL_VERSION,
            on_update_available=lambda tag, url: self.update_available.emit(tag, url),
            repo=self.ctx.settings.github_repo,
        )
```

(`datetime`, `timezone` are already imported at `app.py:15`; `Qt` at
`app.py:20`; `_LOCAL_VERSION` at `app.py:38`. `check_for_update` is
imported locally here, matching the existing local-import style.)

**Step 3: Lint + full suite**

Run: `.venv/bin/python -m ruff check app.py core/updater.py && .venv/bin/python -m pytest tests/ -q`
Expected: ruff clean; full suite PASS, no regressions.

**Step 4: Commit**

```bash
git add app.py
git commit -m "feat(app): re-check for updates on app activation (24h-gated)"
```

---

### Task 5: Tray-notification dedupe in `_on_update_available`

**Files:**
- Modify: `app.py:399-411` (`_on_update_available`)

**Step 1: Add the per-tag tray gate**

In `app.py`, `_on_update_available` currently is:

```python
    def _on_update_available(self, tag: str, url: str) -> None:
        """GUI-thread receiver for the updater's async callback. Stores
        the (tag, url) on AppContext so any later-opened MainWindow can
        still find it, surfaces an in-window banner with a Download button,
        and fires a one-shot tray notification."""
        self.ctx.update_available_tag = tag
        self.ctx.update_available_url = url
        if self._window is not None:
            self._window.show_update_banner(tag, url)
        self.tray.showMessage(
            "Paragraphos update available",
            f"{tag} is out — you have v{_LOCAL_VERSION}. Click the Download button in the window.",
        )
```

Replace it with:

```python
    def _on_update_available(self, tag: str, url: str) -> None:
        """GUI-thread receiver for the updater's async callback. Stores
        the (tag, url) on AppContext so any later-opened MainWindow can
        still find it, refreshes the in-window banner with a Download
        button, and fires the tray notification once per release tag
        (deduped via QSettings ``updater/notified_tag`` so re-checks and
        relaunches don't re-nag for an already-announced version)."""
        from PyQt6.QtCore import QSettings

        from core.updater import should_notify_tag

        self.ctx.update_available_tag = tag
        self.ctx.update_available_url = url
        if self._window is not None:
            self._window.show_update_banner(tag, url)
        s = QSettings("madevmuc", "Paragraphos")
        if should_notify_tag(s.value("updater/notified_tag", "", type=str), tag):
            self.tray.showMessage(
                "Paragraphos update available",
                f"{tag} is out — you have v{_LOCAL_VERSION}. "
                "Click the Download button in the window.",
            )
            s.setValue("updater/notified_tag", tag)
```

(The banner is still refreshed unconditionally — it has its own
per-tag dismiss logic in `ui/main_window.py`.)

**Step 2: Lint + full suite**

Run: `.venv/bin/python -m ruff check app.py && .venv/bin/python -m pytest tests/ -q`
Expected: ruff clean; full suite PASS.

**Step 3: Commit**

```bash
git add app.py
git commit -m "fix(app): notify tray once per release tag, not every check/launch"
```

---

### Task 6: Headless smoke of `_on_activation_update_check`

**Files:**
- Create: `tests/test_app_activation_update_check.py`

Mirror the pattern of the existing `tests/test_app_activation_catchup.py`
(real unbound method against a minimal fake `self` + real `StateStore`,
no Qt event loop). `check_for_update` is the thing we assert gets called.

**Step 1: Write the test**

Create `tests/test_app_activation_update_check.py`:

```python
"""Headless smoke of the on-activation update re-check slot.

Drives the real ``ParagraphosApp._on_activation_update_check`` against a
minimal stand-in self plus a real ``StateStore``, with ``check_for_update``
monkeypatched to a recorder so no network/thread is spawned. The real GUI
wiring (applicationStateChanged firing on macOS) stays manual.
"""

from __future__ import annotations

import types
from datetime import datetime, timedelta, timezone

import pytest
from PyQt6.QtCore import Qt

import app as app_module
from core.models import Settings
from core.state import StateStore

ACTIVE = Qt.ApplicationState.ApplicationActive
INACTIVE = Qt.ApplicationState.ApplicationInactive


class _FakeApp:
    def __init__(self, state: StateStore, settings: Settings):
        self.ctx = types.SimpleNamespace(state=state, settings=settings)
        self.update_available = types.SimpleNamespace(emit=lambda *a: None)


@pytest.fixture()
def state(tmp_path) -> StateStore:
    s = StateStore(tmp_path / "state.sqlite")
    s.init_schema()
    return s


@pytest.fixture()
def recorder(monkeypatch):
    calls: list[dict] = []
    monkeypatch.setattr(
        "core.updater.check_for_update",
        lambda **kw: calls.append(kw),
    )
    return calls


def _activate(fake, st=ACTIVE):
    app_module.ParagraphosApp._on_activation_update_check(fake, st)


def test_checks_when_due_and_records_timestamp(state, recorder):
    fake = _FakeApp(state, Settings())  # update_check_enabled True by default

    _activate(fake)

    assert len(recorder) == 1
    assert state.get_meta("last_update_check") is not None


def test_gated_within_24h(state, recorder):
    recent = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()
    state.set_meta("last_update_check", recent)
    fake = _FakeApp(state, Settings())

    _activate(fake)

    assert recorder == []


def test_disabled_by_setting(state, recorder):
    fake = _FakeApp(state, Settings(update_check_enabled=False))

    _activate(fake)

    assert recorder == []
    assert state.get_meta("last_update_check") is None


def test_ignores_non_active_state(state, recorder):
    fake = _FakeApp(state, Settings())

    _activate(fake, INACTIVE)

    assert recorder == []
    assert state.get_meta("last_update_check") is None


def test_rechecks_after_24h(state, recorder):
    old = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    state.set_meta("last_update_check", old)
    fake = _FakeApp(state, Settings())

    _activate(fake)

    assert len(recorder) == 1
```

**Step 2: Run the test**

Run: `.venv/bin/python -m pytest tests/test_app_activation_update_check.py -v`
Expected: PASS (5 passed)

**Step 3: Lint + full suite**

Run: `.venv/bin/python -m ruff check tests/test_app_activation_update_check.py && .venv/bin/python -m pytest tests/ -q`
Expected: ruff clean; full suite PASS.

**Step 4: Commit**

```bash
git add tests/test_app_activation_update_check.py
git commit -m "test(app): headless smoke of on-activation update re-check"
```

---

### Task 7: Manual smoke (deferred, user-run)

The `applicationStateChanged` Qt wiring is not unit-testable headless.
Manual verification (user, on macOS):

1. Set `last_update_check` meta to >24h ago (or unset); `update_check_enabled` on.
2. `.venv/bin/python app.py`, defocus, refocus → an update check fires
   (observe via logs / a tray notification if a newer release exists).
3. Refocus again within 24h → no second check (24h gate).
4. Toggle "Check for updates" off in Settings → no check on next refocus.
5. With a pending update already announced, relaunch → banner shows but
   NO repeated tray notification (per-tag dedupe).

No code; record result. If a fix is needed, fold it into the relevant
task above and re-run that task's verification.

---

## Notes

- DRY: reuses the existing `update_available` signal, `_on_update_available`,
  `check_for_update`, and the `applicationStateChanged` signal — no new
  timer/thread infrastructure.
- YAGNI: no scheduler coupling, no success-callback rework of
  `check_for_update`, no per-check re-notify.
- Decoupling: `_on_app_activated` and its `_catch_up_pending` latch are
  NOT touched — the update slot is an independent second connection.
