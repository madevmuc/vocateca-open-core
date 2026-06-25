# "Pausing" Transitional Queue State — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When Pause is pressed while an episode is still transcribing, surface a distinct **`pausing`** state ("pause queued — current episode finishes first, then the queue halts") instead of immediately looking paused.

**Architecture:** One pure, Qt-free helper `queue_ui_state(queue_paused, running)` is the single source of truth for a 4-state model (`idle|running|pausing|paused`), derived from existing signals (no new persisted state). Surfaces consume it: the tray status block (new amber `pausing` Pill kind), the Queue-tab buttons, and the activity log. Because no `episode_done` fires during the drain, a new `pause_state_changed` signal on `CheckAllThread` pokes `ParagraphosApp` to rebuild the tray immediately on the Pause click.

**Tech Stack:** Python 3.12, PyQt6, pytest, ruff. Env: `.venv/bin/python -m pytest` / `.venv/bin/python -m ruff` (system python is 2.7). Pre-commit hook runs ruff + ruff format + pytest on staged `.py`; never `--no-verify`. Design doc: `docs/plans/2026-05-18-queue-pausing-state-design.md`.

**Scope note (design correction):** The design listed a "Surface 3 — Statusbar". Investigation shows `ui/menu_bar.py:346` is the OPML-import toast; there is **no** persistent queue-status statusbar. Adding one is out of scope (YAGNI). The textual cue is the existing `_pause()` activity-log line, whose wording Task 5 aligns. Tray block + Queue-tab buttons + log line are the surfaces.

**Branch:** `feat/queue-pausing-state` (already created; design doc committed there).

---

### Task 1: Pure state helper `queue_ui_state`

**Files:**
- Create: `core/queue_status.py`
- Test: `tests/test_queue_status.py`

**Step 1: Write the failing tests**

Create `tests/test_queue_status.py`:

```python
from core.queue_status import queue_ui_state


def test_running():
    assert queue_ui_state(queue_paused=False, running=True) == "running"


def test_pausing_is_paused_flag_while_still_running():
    assert queue_ui_state(queue_paused=True, running=True) == "pausing"


def test_paused_after_drain():
    assert queue_ui_state(queue_paused=True, running=False) == "paused"


def test_idle():
    assert queue_ui_state(queue_paused=False, running=False) == "idle"
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_queue_status.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'core.queue_status'`

**Step 3: Minimal implementation**

Create `core/queue_status.py`:

```python
"""Derived queue UI state — single source of truth for every surface.

``pausing`` is the transitional state after Pause is pressed but before
the in-flight episode finishes: the worker was told to stop claiming new
work (``queue_paused`` meta = "1") yet ``ctx.queue.running`` is still
True because whisper-cli is finishing the current episode. Pure and
Qt-free so it is unit-testable without the GUI.
"""

from __future__ import annotations


def queue_ui_state(*, queue_paused: bool, running: bool) -> str:
    """Return one of: "idle" | "running" | "pausing" | "paused"."""
    if running and queue_paused:
        return "pausing"
    if running:
        return "running"
    if queue_paused:
        return "paused"
    return "idle"
```

**Step 4: Run to verify it passes**

Run: `.venv/bin/python -m pytest tests/test_queue_status.py -v`
Expected: PASS (4 passed)

**Step 5: Commit**

```bash
git add core/queue_status.py tests/test_queue_status.py
git commit -m "feat(queue): add queue_ui_state pure helper (idle/running/pausing/paused)"
```

---

### Task 2: Amber `pausing` Pill kind

**Files:**
- Modify: `ui/widgets/pill.py` (`ALLOWED_KINDS`)
- Modify: `ui/themes/tokens.py` (`LIGHT` ~line 18-48, `DARK` ~line 58-90)
- Modify: `ui/themes/app.qss.tmpl` (~line 164-167, the per-kind rows)
- Test: `tests/test_pill_pausing_kind.py`

**Step 1: Write the failing test**

Create `tests/test_pill_pausing_kind.py`:

```python
from ui.themes import tokens
from ui.widgets.pill import Pill


def test_pausing_is_allowed_kind():
    assert "pausing" in Pill.ALLOWED_KINDS


def test_both_themes_define_pausing_pill_tokens():
    for theme in (tokens.LIGHT, tokens.DARK):
        assert "pill_pausing_bg" in theme
        assert "pill_pausing_fg" in theme
```

**Step 2: Run to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_pill_pausing_kind.py -v`
Expected: FAIL — `"pausing" not in ALLOWED_KINDS` (and missing token keys).

**Step 3: Implement**

In `ui/widgets/pill.py` change:
```python
    ALLOWED_KINDS = ("ok", "fail", "running", "idle")
```
to:
```python
    ALLOWED_KINDS = ("ok", "fail", "running", "idle", "pausing")
```

In `ui/themes/tokens.py`, in the `LIGHT` dict, immediately after the
`"pill_fail_fg": ...` line add:
```python
    "pill_pausing_bg": "rgba(184, 134, 74, 0.15)",
    "pill_pausing_fg": "#b8864a",
```
(derived from LIGHT's existing `"warn": "#b8864a"`, mirroring the
translucent-bg + solid-fg pattern of `pill_fail_*`.)

In the `DARK` dict, after its `"pill_fail_fg": ...` line add:
```python
    "pill_pausing_bg": "rgba(240, 185, 85, 0.18)",
    "pill_pausing_fg": "#f0b955",
```
(derived from DARK's existing `"warn": "#f0b955"`.)

In `ui/themes/app.qss.tmpl`, after the line:
```
QLabel#Pill[kind="fail"]     {{ background: {pill_fail_bg};    color: {pill_fail_fg}; }}
```
add:
```
QLabel#Pill[kind="pausing"]  {{ background: {pill_pausing_bg}; color: {pill_pausing_fg}; }}
```

**Step 4: Run to verify it passes**

Run: `.venv/bin/python -m pytest tests/test_pill_pausing_kind.py -v`
Expected: PASS (2 passed)

**Step 5: Commit**

```bash
git add ui/widgets/pill.py ui/themes/tokens.py ui/themes/app.qss.tmpl tests/test_pill_pausing_kind.py
git commit -m "feat(ui): add amber 'pausing' Pill kind + theme tokens"
```

---

### Task 3: Tray status block renders the pausing state

**Files:**
- Modify: `ui/menu_bar.py` (`_build_status_block` ~510, `build_tray_menu` ~550-575)
- Modify: `app.py` (`_rebuild_tray_menu` ~374-396; its callers ~314, ~578, ~688)

**Step 1: Thread a `pausing` flag through the builders**

In `ui/menu_bar.py`, change `_build_status_block` signature from:
```python
def _build_status_block(done: int, total: int, current_title: str, eta_sec: int | None) -> QWidget:
```
to add `pausing: bool = False` as the last parameter. Inside it, replace:
```python
    h1.addWidget(Pill("running", kind="running"))
    frac_lbl = QLabel(f"{done}/{total}")
```
with:
```python
    if pausing:
        h1.addWidget(Pill("Pausing", kind="pausing"))
        frac_lbl = QLabel("Finishing current episode…")
    else:
        h1.addWidget(Pill("running", kind="running"))
        frac_lbl = QLabel(f"{done}/{total}")
```
(Keep the progress bar + "Now:" line unchanged — the bar still shows
overall progress and the title still shows the in-flight episode, which
is exactly what is finishing.)

In `build_tray_menu`, add `pausing: bool = False` to the keyword-only
signature (after `eta_sec`), and pass it through:
```python
        wa.setDefaultWidget(_build_status_block(done, total, current_title, eta_sec, pausing))
```
Keep the `if running and total > 0:` gate as-is (during pausing the
worker is still running with a non-zero total, so the rich block shows).

**Step 2: Pass the derived state from app.py**

In `app.py` `_rebuild_tray_menu`, add `pausing: bool = False` to its
keyword-only signature and forward it to `build_tray_menu(..., pausing=pausing)`.
The three existing callers (~314 `running=False`, ~688 `running=False`)
need no change (default `pausing=False`). The `_on_episode_done` caller
(~578) also stays `pausing=False` (a normal tick). The pausing rebuild
is driven by Task 5.

**Step 3: Verify nothing broke**

Run: `.venv/bin/python -m ruff check ui/menu_bar.py app.py && .venv/bin/python -m pytest tests/ -q`
Expected: ruff clean; full suite green (no behavioural change yet — `pausing` defaults False everywhere).

**Step 4: Commit**

```bash
git add ui/menu_bar.py app.py
git commit -m "feat(tray): render 'Pausing' status block when draining"
```

---

### Task 4: Queue-tab buttons reflect `pausing`

**Files:**
- Modify: `ui/queue_tab.py` (`_update_btns` ~337-348)

**Step 1: Use the helper**

In `ui/queue_tab.py` `_update_btns`, replace the body:
```python
        running = self.ctx.queue.running
        paused = self.ctx.state.get_meta("queue_paused") == "1"
        self.start_btn.setEnabled(not running)
        self.start_btn.setText("Resume" if paused else "Start")
        self.pause_btn.setEnabled(running and not paused)
        self.stop_btn.setEnabled(running)
        if not running and self._stop_pressed_once:
            self._stop_pressed_once = False
            self.stop_btn.setText("Stop")
```
with:
```python
        from core.queue_status import queue_ui_state

        running = self.ctx.queue.running
        paused = self.ctx.state.get_meta("queue_paused") == "1"
        state = queue_ui_state(queue_paused=paused, running=running)

        # idle: Start | running: Pause/Stop | pausing: drain in progress |
        # paused: Resume (drained, halted).
        self.start_btn.setEnabled(state in ("idle", "paused"))
        self.start_btn.setText("Resume" if state == "paused" else "Start")
        if state == "pausing":
            self.pause_btn.setText("Pausing…")
            self.pause_btn.setEnabled(False)
        else:
            self.pause_btn.setText("Pause")
            self.pause_btn.setEnabled(state == "running")
        # Stop stays available while the worker runs (incl. pausing) so
        # the user can still force-abort the in-flight episode.
        self.stop_btn.setEnabled(state in ("running", "pausing"))
        if not running and self._stop_pressed_once:
            self._stop_pressed_once = False
            self.stop_btn.setText("Stop")
```
(`_update_btns` is called on the 1 s `_tick` and on the Pause click, so
the Queue tab self-heals into/out of `pausing` without extra wiring.)

**Step 2: Verify**

Run: `.venv/bin/python -m ruff check ui/queue_tab.py && .venv/bin/python -m pytest tests/ -q`
Expected: ruff clean; full suite green.

**Step 3: Commit**

```bash
git add ui/queue_tab.py
git commit -m "feat(queue-tab): show 'Pausing…' button state while draining"
```

---

### Task 5: Immediate tray refresh + log wording on Pause

**Files:**
- Modify: `ui/worker_thread.py` (`CheckAllThread` signals ~471-475)
- Modify: `ui/shows_tab.py` (`_pause` ~567-571)
- Modify: `app.py` (signal-wiring block ~482-485/508-509; add `_on_pause_state_changed`; cache last tick data in `_on_episode_done` ~562-584)

**Step 1: Add the signal**

In `ui/worker_thread.py`, in `class CheckAllThread(QThread):` after
`finished_all = pyqtSignal()` add:
```python
    pause_state_changed = pyqtSignal()  # emitted when Pause is pressed mid-run
```

**Step 2: Emit it from `_pause()` and align the log wording**

In `ui/shows_tab.py` `_pause()`, change:
```python
    def _pause(self):
        self.ctx.state.set_meta("queue_paused", "1")
        if self._thread and self._thread.isRunning():
            self._thread.request_stop()
        self._log("queue paused — Resume to continue (survives restart).")
```
to:
```python
    def _pause(self):
        self.ctx.state.set_meta("queue_paused", "1")
        if self._thread and self._thread.isRunning():
            self._thread.request_stop()
            self._thread.pause_state_changed.emit()
        self._log(
            "pausing — current episode will finish, then the queue halts "
            "(Resume to continue; survives restart)."
        )
```
(If no thread is running there is nothing draining → no signal, and the
Queue-tab tick already handles the plain `paused` shape.)

**Step 3: Cache last tick data + connect the signal in app.py**

In `app.py` `_on_episode_done`, where it computes `eta` and calls
`self._rebuild_tray_menu(running=True, done=done_idx, total=total,
current_title=..., eta_sec=eta)`, also store them for a later pausing
rebuild — immediately before that `_rebuild_tray_menu(...)` call add:
```python
        self._last_tick = (done_idx, total, f"{show_title} — {ep_title}", eta)
```
And in `__init__` (near other instance attrs, e.g. by `self._run_tally`)
add:
```python
        self._last_tick = (0, 0, "", None)
```

Add the handler method (next to `_on_episode_done`):
```python
    def _on_pause_state_changed(self) -> None:
        """Pause was pressed mid-run. No episode_done fires until the
        in-flight episode ends, so rebuild the tray now so the Pill
        flips to 'Pausing' at click time rather than at episode end."""
        done, total, title, eta = self._last_tick
        if total > 0:
            self._rebuild_tray_menu(
                running=True,
                done=done,
                total=total,
                current_title=title,
                eta_sec=eta,
                pausing=True,
            )
```

In the signal-wiring block where the app connects the thread's signals
(the block containing `self._thread.episode_done.connect(...)` /
`self._thread.finished_all.connect(self._on_check_done)`), add:
```python
        self._thread.pause_state_changed.connect(self._on_pause_state_changed)
```
(Wire it in the same place(s) `finished_all` is connected so every
run-owning path — GUI ShowsTab thread and the headless fallback —
gets it. Match each existing `finished_all.connect` site.)

**Step 4: Verify**

Run: `.venv/bin/python -m ruff check app.py ui/shows_tab.py ui/worker_thread.py && .venv/bin/python -m pytest tests/ -q`
Expected: ruff clean; full suite green (472 passed + Task 1/2 additions; no regressions).

**Step 5: Commit**

```bash
git add app.py ui/shows_tab.py ui/worker_thread.py
git commit -m "feat(tray): flip to Pausing immediately on Pause via pause_state_changed"
```

---

### Task 6: Manual smoke (deferred, user-run)

Qt signal + visual; not unit-testable headless.

1. `.venv/bin/python app.py`, add a show, Start a check so an episode is
   transcribing (whisper running).
2. Click **Pause** mid-episode. Expected immediately:
   - Queue tab: Pause button → "Pausing…" disabled; Start disabled;
     Stop still enabled. (This is the pausing surface for a manual
     toolbar Start — verify it here.)
   - Activity log: "pausing — current episode will finish…".
   - Tray status block: the amber **Pausing** pill + "Finishing current
     episode…" (not the x/total fraction; "Now:" still shows the
     in-flight title; progress bar still present) applies **only to
     background runs** — scheduler cron, startup catch-up, or tray
     "Check now". The tray rich status block is never wired for manual
     in-window runs (toolbar Start / Resume / Ctrl+R go through
     `ShowsTab.start_check()`, which drives only the in-window Queue
     tab). To verify the tray pill, trigger the run via the scheduler or
     tray "Check now" instead of a manual toolbar Start, then Pause
     mid-episode and confirm the pill flips at click time. This is an
     accepted constraint (see design "Surface 4"), not a defect.
3. Let the episode finish. Expected: state → **paused** — tray reverts to
   idle menu, Queue tab shows **Resume** enabled, Pause disabled.
4. Click **Resume** → back to running, green pill.
5. Repeat but click **Stop** (force) during `pausing` → in-flight episode
   is killed, state goes to idle/halted (existing force-stop behaviour
   unaffected).
6. (Task-4 review carry-over) Kill `whisper-cli` externally mid-drain
   (e.g. `pkill whisper-cli` while an episode is transcribing) → the
   worker dies without emitting `finished_all`. Confirm the user can
   still recover via **Stop→Stop** (the queue is not permanently stuck).

Record results. Any fix folds into the relevant task above + re-verify.

---

## Notes

- DRY: `queue_ui_state` is the only place the 4-state logic lives;
  Queue-tab and tray both derive from it.
- YAGNI: no persisted state; no new statusbar element (design Surface 3
  dropped — see scope note); no "Resume cancels pause mid-drain"
  affordance; reuse existing Pill / 1 s tick.
- No coupling to the unrelated catch-up/update slots.
- The only cross-component wiring is one new thread signal mirroring the
  existing `episode_done`/`finished_all` pattern the app already uses.
