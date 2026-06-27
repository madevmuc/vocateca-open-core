# PyQt6 → PySide6 Migration Plan & Full Inventory

**Date:** 2026-06-27
**Author:** analysis pass (read-only) for `feat/roadmap-execution`
**Status:** PLAN — no source files modified. Drives a later implementation plan.

## 1. Why & headline finding

**Why:** A future closed-source "Pro" module must link Qt without GPL obligations.
PyQt6 is GPL-3.0 / commercial; **PySide6 is LGPL-3.0** → migrating the binding
unblocks shipping closed-source code that links Qt.

**Headline finding: this is an unusually clean, mostly-mechanical migration.**
The codebase already uses Qt6-idiomatic patterns throughout. The grep sweep
found **none** of the classic hard blockers:

- No `.ui` files, no `.qrc` resource files, no `loadUi`, no `pyrcc`/`uic`.
- No `sip` imports, no `pyqtSlot`, no `pyqtProperty`, no `pyqtBoundSignal`,
  no `pyqtConfigure`, no `QMetaObject`/`staticMetaObject`.
- No `QVariant` usage (one comment mention only), no `.exec_()` (all call
  sites already use Qt6 `.exec()`).
- **All `Qt.*` enums are already fully scoped** (`Qt.AlignmentFlag.AlignLeft`,
  `Qt.ItemDataRole.UserRole`, `QDialog.DialogCode.Accepted`,
  `QMessageBox.StandardButton.Ok`, etc.) — both bindings require this in Qt6,
  so no enum churn.
- `QAction` and `QShortcut` are already imported from `QtGui` (their Qt6 home,
  same in PySide6).
- No `QtMultimedia`, `QtWebEngine`, `QtSvg`, `QtNetwork`, `QtPrintSupport`.
  Only extra module beyond Core/Gui/Widgets is `QtTest` (two test sites).

The bulk of the work is a find/replace of the import token `PyQt6` → `PySide6`
and the symbol renames `pyqtSignal` → `Signal`. Real risk is concentrated in a
handful of behavioural and packaging spots, called out in §4 and §5.

### Touchpoint counts

| Scope | Files | Notes |
|---|---|---|
| Non-test source files importing `PyQt6` | **39** | `app.py`, 33 under `ui/`, `core/connectivity.py`, plus 2 packaging files (`setup-full.py`, `setup-full-universal.py`) |
| `ui/` modules | 33 | incl. `ui/widgets/*`, `ui/themes/__init__.py` |
| `core/` modules touching Qt | **1** | `core/connectivity.py` (uses `QObject`, `pyqtSignal`) — rest of `core/` is Qt-free |
| Test files importing `PyQt6` | **45** | incl. `tests/conftest.py` |
| `pyqtSignal` occurrences in non-test source | **75** | across 17 definition files |
| `pyqtSignal` definition files (`= pyqtSignal(...)`) | 17 | see §3 list |

**`setup.py` (the alias-mode py2app config) does NOT name PyQt6** — it bundles
only `core`, `ui` and non-Qt deps and relies on the venv's binding. Only the two
**standalone** bundlers (`setup-full.py`, `setup-full-universal.py`) name
`"PyQt6"` in `packages`.

## 2. PyQt6 → PySide6 symbol/API delta that ACTUALLY affects this code

Only the differences present in this repo are listed; generic ones that don't
occur here are omitted.

| PyQt6 (current) | PySide6 (target) | Where it occurs | Risk |
|---|---|---|---|
| `from PyQt6.QtCore import ...` | `from PySide6.QtCore import ...` | every file | trivial token swap |
| `from PyQt6.QtGui/QtWidgets import ...` | `from PySide6.QtGui/QtWidgets import ...` | every file | trivial |
| `pyqtSignal` | `Signal` | 17 files, 75 sites | mechanical rename **+ import symbol change** |
| `from PyQt6.QtTest import QTest` | `from PySide6.QtTest import QTest` | `tests/test_local_transcript_tab.py` | trivial |
| `sip` | (not used) → would be `shiboken6` | — | N/A, none present |
| `.exec_()` | `.exec()` | already `.exec()` everywhere | **no-op** |
| `QVariant` | (not used; PySide6 auto-converts) | — | N/A |
| scoped enums `Qt.X.Y` | identical in PySide6 | all enum sites | **no change** |
| `pyqtSlot` / `pyqtProperty` | `Slot` / `Property` | — | N/A, none present |
| `.qrc` → `pyrcc6` | n/a (PySide6 uses `pyside6-rcc`) | — | N/A, no resources |

### Symbols to rename in lockstep with each import line

In each of the 17 signal-defining files the import currently reads e.g.
`from PyQt6.QtCore import QObject, Qt, QTimer, pyqtSignal`. Two edits per such
file: swap `PyQt6`→`PySide6` **and** `pyqtSignal`→`Signal`, then replace each
`pyqtSignal(...)` body call with `Signal(...)`. The signal **call signatures
are identical** (`Signal(str)`, `Signal(object)`, `Signal(int, int)`, etc.), so
no per-signal logic changes.

`Signal`/`Slot`/`Property` live in `PySide6.QtCore` (same module path as
`pyqtSignal` did), which keeps the edit local to the existing import line.

## 3. File-by-file inventory of what must change

### 3a. Files that DEFINE custom signals (need `pyqtSignal`→`Signal` rename)
`app.py`, `ui/main_window.py`, `ui/menu_bar.py`, `ui/library_tab.py`,
`ui/local_transcript_tab.py`, `ui/worker_thread.py`, `ui/first_run_wizard.py`,
`ui/feed_probe.py`, `ui/ytdlp_install_dialog.py`, `ui/show_details_dialog.py`,
`ui/about_dialog.py`, `ui/install_runner.py`, `ui/themes/__init__.py`,
`ui/widgets/sidebar.py`, `ui/widgets/filter_popover.py`, `ui/add_show_dialog.py`,
`core/connectivity.py`.
Test side: `tests/test_add_show_table_wiring.py`, `tests/test_first_run_wizard.py`
(both define inline `pyqtSignal` test stubs).

### 3b. Files that import PyQt6 but only need the token swap (no signal defs)
All remaining `ui/` modules and widgets (e.g. `ui/queue_tab.py`,
`ui/failed_tab.py`, `ui/settings_pane.py`, `ui/setup_dialog.py`,
`ui/shows_tab.py`, `ui/command_palette.py`, `ui/log_dock.py`,
`ui/transcript_diff_dialog.py`, `ui/reconcile_dialog.py`,
`ui/import_folder_dialog.py`, `ui/add_episodes_dialog.py`,
`ui/shortcut_cheatsheet.py`, `ui/widgets/switch.py`,
`ui/widgets/progress_ring.py`, `ui/widgets/resizable_header.py`,
`ui/widgets/show_results_table.py`, `ui/widgets/tray_icon_renderer.py`,
`ui/widgets/empty_state.py`, `ui/widgets/queue_hero.py`, `ui/widgets/pill.py`).
Note: many modules also have **inline lazy imports** (e.g.
`from PyQt6.QtWidgets import QMessageBox` inside functions). `ui/menu_bar.py`
alone has ~11 such inline imports; `ui/settings_pane.py`, `app.py`,
`ui/main_window.py`, `ui/library_tab.py` each have several. A simple
repo-wide token replace of `PyQt6` → `PySide6` catches all of these — do NOT
hand-edit only the top-of-file imports.

### 3c. Threading surface (verify, but API-compatible)
`QThread` subclasses, `QRunnable`/`QThreadPool`, and `moveToThread` are used
heavily and are **API-identical** across the two bindings:
- `QThread` subclasses: `ui/menu_bar.py` (`_OPMLImportThread`, `_BackfillThread`),
  `ui/worker_thread.py` (`_DownloadPool`, `_TranscribeWorker`, `CheckAllThread`),
  `ui/show_details_dialog.py` (3 threads), `ui/about_dialog.py`
  (`_GitHubChangelogThread`), `ui/add_show_dialog.py` (5 threads).
- `QObject` + `moveToThread`: `ui/ytdlp_install_dialog.py`.
- `QRunnable` on `QThreadPool.globalInstance()`: `ui/local_transcript_tab.py`,
  `ui/feed_probe.py`.
No code change expected, but this is the area to exercise hardest in
verification (see §6) — teardown semantics are where bindings can differ
subtly.

### 3d. Packaging files
`setup.py` (no Qt token — leave as-is or document), `setup-full.py`,
`setup-full-universal.py` (replace `"PyQt6"` in `packages` with `"PySide6"` —
see §5).

### 3e. Requirements & docs
`requirements.txt` (`PyQt6>=6.6` → `PySide6>=6.6`), and the
`ui/about_dialog.py` license/credits strings that currently say
"Qt / PyQt6", "PyQt6 under GPL-3.0", "Python 3.12, PyQt6" → update to PySide6 /
LGPL-3.0 (these are user-visible and the whole point of the migration).

## 4. Genuinely risky / behavioural spots (NOT mechanical)

1. **`app.py::_install_slot_exception_handler` — PyQt6-specific behaviour being
   patched away (HIGH attention, LOW effort).**
   This override exists *because* PyQt6 6.x routes an uncaught exception in a
   slot to `qFatal` → SIGABRT. **PySide6 does not do this** — by default it
   prints the traceback and continues. So after migration:
   - The custom `sys.excepthook` becomes a (still-useful) safety net rather
     than a crash-preventer; it should still install cleanly.
   - The docstring/comments referencing "PyQt6 changed PyQt5's behaviour…
     qFatal" become inaccurate and should be updated.
   - **Risk:** behaviour *improves* (fewer hard aborts), but any test that
     asserted the qFatal/SIGABRT path or the excepthook's exact interception
     may need its expectation relaxed. See `tests/test_show_details_feed_health_panel.py`
     (its module docstring explicitly describes a "SIGABRT via PyQt6's
     qFatal-on-slot-exception path"). Re-validate that test's intent.

2. **`tests/conftest.py` QThread-cleanup fixture (HIGH attention).**
   `_stop_running_qthreads()` imports `from PyQt6.QtCore import QThread` and
   calls `requestInterruption/quit/wait/terminate`. The API is identical in
   PySide6, but this fixture is the load-bearing guard against the historically
   flaky "leaked QThread aborts at teardown" SIGABRT (see project memory:
   *pre-commit Qt teardown SIGABRT*). After swapping the import, **run the full
   suite repeatedly** to confirm no teardown aborts reappear under PySide6,
   whose QThread GC/teardown timing can differ. Also note `gc.get_objects()`
   isinstance-matching against the *renamed* QThread type — make sure the swap
   is consistent so the isinstance check still matches live threads.

3. **`QSettings` geometry round-trip (MEDIUM).**
   `ui/main_window.py` does `setValue("window/geometry", self.saveGeometry())`
   and `restoreGeometry(saved)`. `saveGeometry()` returns a `QByteArray`.
   PyQt6 and PySide6 serialize/deserialize `QByteArray` through `QSettings`
   slightly differently (PySide6 may hand back `bytes`/`QByteArray` where the
   code expects a `QByteArray`). `restoreGeometry` accepts both, so this is
   low-probability, but **a stale PyQt6-written `QSettings` value on a dev
   machine could fail to restore** under PySide6. Mitigation: the existing code
   already guards restore in a `try`; confirm the guard swallows a type mismatch
   and falls back to the default size. Verify manually by launching the app
   with an existing `~/Library/Preferences/com.m4ma.*`/`madevmuc.Paragraphos`
   settings file present.
   Also `ui/library_tab.py` stores/reads `library/splitter` sizes (a list of
   ints) via QSettings — list round-tripping differs subtly between bindings;
   verify the splitter restores.

4. **`app.py` native `QFileOpenEvent` interception (MEDIUM).**
   `ParagraphosQApplication.event()` checks
   `QEvent.Type.FileOpen` / `isinstance(e, QFileOpenEvent)` for Finder→Dock
   `.opml` drops, and `QEvent.Type.Quit`. Event-filter/`event()` override is
   API-identical, but `QFileOpenEvent` delivery is a macOS-platform-integration
   path — **must be smoke-tested on the real .app bundle**, not just headless
   (the offscreen QPA won't deliver FileOpen). Low code risk, but it's the one
   thing that can't be proven by the pytest suite.

5. **`ui/widgets/resizable_header.py` known segfault note (LOW–MEDIUM).**
   Comments flag a PyQt6 6.7 segfault on header resize and a QVariant-dict
   serialization caveat that the code already works around by storing simple
   types. The workaround is binding-agnostic and should carry over, but this
   widget is a known fragile spot — include it in focused interactive testing.

6. **License/credits strings (LOW, but it's the deliverable's point).**
   `ui/about_dialog.py` must stop claiming GPL-3.0/PyQt6. Update to PySide6 /
   LGPL-3.0 so the About box is truthful for the closed-source build.

## 5. py2app / packaging impact (macOS)

- **`setup.py` (alias mode, `-A`):** names no Qt package; it references the
  venv's binding directly. Once `PySide6` is the installed binding, alias-mode
  builds pick it up automatically. **No edit strictly required**, though a
  one-line comment update is courteous.
- **`setup-full.py` / `setup-full-universal.py` (standalone bundles):** change
  `"PyQt6"` → `"PySide6"` in the `packages` list. **Gotchas:**
  - PySide6 ships **`shiboken6`** as a separate runtime package. py2app's
    modulegraph usually follows it, but add **`"shiboken6"`** to `packages`
    explicitly if the bundle fails to import `PySide6` at launch.
  - PySide6 wheels are **substantially larger** than PyQt6 and include many Qt
    modules you don't use (QtQml, QtQuick, QtWebEngine, Qt3D, etc.). The
    standalone `.app` will balloon unless you **exclude unused submodules**.
    Add to `excludes` (in addition to the existing tkinter/numpy/etc. list):
    `PySide6.QtQml`, `PySide6.QtQuick`, `PySide6.QtQuick3D`,
    `PySide6.QtWebEngineCore`, `PySide6.QtWebEngineWidgets`, `PySide6.Qt3D*`,
    `PySide6.QtMultimedia`, `PySide6.QtCharts`, `PySide6.QtDataVisualization`,
    `PySide6.QtNetwork` (verify nothing transitively needs it),
    `PySide6.QtPdf`, `PySide6.QtSql`, `PySide6.QtPositioning`,
    `PySide6.QtBluetooth`, `PySide6.QtSerialPort`, `shiboken6.example`. Tune by
    iterating: build, launch, add back anything that was actually needed.
  - **Qt plugins:** the app needs the `platforms/libqcocoa` plugin and likely
    `styles`, `imageformats`. py2app + PySide6's bundling of the
    `PySide6/Qt/plugins` tree is the historically finicky part; if the bundled
    app launches blank or crashes with "could not find the Qt platform plugin
    'cocoa'", set `QT_QPA_PLATFORM_PLUGIN_PATH` or add the plugin dir via
    py2app `resources`/`frameworks`. Budget iteration time here.
  - **Code signing / notarization:** PySide6 dylibs/frameworks must be signed
    for distribution; the larger framework set means more to sign. Out of scope
    for personal alias-mode use but note for any future distributable build.
- **Universal2:** `setup-full-universal.py` targets universal builds. Confirm
  the installed PySide6 wheel is `universal2` (or that both arch wheels are
  available) before attempting a universal bundle — PySide6 macOS wheel arch
  coverage differs from PyQt6's.

## 6. Test / verification strategy

PySide6 is **not yet installed** in the venv (confirmed: `import PySide6`
fails; current binding is **PyQt6 6.11.0**). Step 0 of any execution is
installing it.

1. **Install side-by-side first:** `pip install "PySide6>=6.6"` into `.venv`.
   Keep PyQt6 installed during the transition so you can A/B if needed (they can
   coexist; just don't import both in one process).
2. **Import smoke test:** after the renames, run
   `python -c "import app"` and `python -c "import ui.main_window"` to catch any
   missed `PyQt6` token or symbol (`Signal` not imported, etc.) before pytest.
3. **Headless suite:** the suite runs under the offscreen QPA. Run
   `QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest -q`. 45 test files
   import the binding; they all share the conftest QThread-cleanup +
   msgbox-stub fixtures, which must be migrated (their inline `PyQt6` imports
   swapped) *first* or the whole suite fails to collect.
4. **Stress the threading/teardown path:** because the historical flake is a
   teardown SIGABRT from leaked QThreads, run the full suite **at least 3–5
   times** (and/or `pytest -p no:randomly`-vs-randomized) to confirm PySide6
   teardown stays green. Pay special attention to
   `tests/test_show_details_*`, `tests/test_add_show_dialog_youtube.py`,
   `tests/test_feed_probe.py`, `tests/test_ytdlp_install_dialog.py`,
   `tests/test_local_transcript_tab.py` (the QThread-heavy ones).
5. **Re-examine the SIGABRT-asserting test:**
   `tests/test_show_details_feed_health_panel.py` documents the PyQt6
   qFatal-on-slot path. Confirm it still passes (it should pass *more* easily
   under PySide6); update its docstring if the rationale no longer applies.
6. **Launch the real app (cannot be proven headless):**
   `./.venv/bin/python app.py` and exercise: window geometry restore (§4.3),
   Finder→Dock `.opml` drop (§4.4), the resizable header (§4.5), opening every
   dialog (`.exec()` modal loops), the tray icon, and a real "Check Now" run
   that spins up the worker threads. Then `python setup.py py2app -A` and
   `open dist/Paragraphos.app` to validate alias-mode bundling.
7. **pre-commit:** runs ruff + unit pytest. Ensure ruff has no lint on the new
   imports (unused `Signal` if a file imported `pyqtSignal` only for a removed
   symbol — unlikely) and that the pre-commit pytest subset is green.
8. **Bundle build (optional, later):** only when a distributable is needed —
   `python setup-full.py py2app`, then iterate on the `excludes`/plugin
   gotchas from §5.

## 7. Ordered step plan + effort estimate

Recommended sequence: mechanical first, then risky behaviour, then packaging.

| # | Step | Risk | Est. |
|---|---|---|---|
| 0 | `pip install PySide6>=6.6` into `.venv`; update `requirements.txt` | low | 0.1 d |
| 1 | Migrate `tests/conftest.py` (QThread import) + any shared test helpers FIRST so the suite can collect | med | 0.2 d |
| 2 | Repo-wide mechanical rename: `PyQt6`→`PySide6` (incl. all inline lazy imports) and `pyqtSignal`→`Signal` (import line + call sites) across all 39 source + 45 test files. Use a scripted replace, then review the 17 signal-defining files by hand. | low (volume) | 0.5 d |
| 3 | Import smoke test + run headless pytest; fix any missed tokens/symbols | low | 0.3 d |
| 4 | Address risky spots: `_install_slot_exception_handler` docstring + behaviour re-check; QSettings geometry/splitter round-trip; `QFileOpenEvent`; resizable_header; SIGABRT-asserting test | **med–high** | 0.7 d |
| 5 | Repeated full-suite runs to confirm no teardown SIGABRT regression under PySide6 | med | 0.3 d |
| 6 | Interactive launch verification (geometry, dialogs, threads, tray, Finder drop) | med | 0.4 d |
| 7 | Update user-visible license/credits strings in `ui/about_dialog.py` (PyQt6/GPL → PySide6/LGPL) | low | 0.1 d |
| 8 | Packaging: edit `setup-full*.py` (`PyQt6`→`PySide6`, add `shiboken6`, expand `excludes`); alias-mode build + launch; (optional) standalone bundle + plugin/notarize iteration | **med–high** (standalone) | 0.5 d alias / +1–2 d if full distributable bundle is required |

**Effort estimate:**
- **Core migration to a working, tested, alias-mode app: ~2.5–3 person-days.**
- **Plus a distributable standalone bundle (PySide6 plugin/exclude/sign
  iteration): +1–2 person-days** — defer unless a shippable `.app` is needed.

The dominant cost is *not* the code edits (those are largely scripted) but the
**verification of the threading/teardown path** and the **py2app standalone
bundling** of PySide6's larger framework set. For personal/alias use, this is a
low-risk migration; for a notarized distributable it carries the usual Qt
bundling tail.

## 8. Notes for the implementation-plan author

- Do the rename as one scripted pass but **commit the conftest/test-fixture
  migration separately first** so a broken collect is easy to bisect.
- Keep PyQt6 installed until step 6 passes, then remove it from the venv and
  `requirements.txt` in the final commit.
- The only `core/` file to touch is `core/connectivity.py`; the rest of `core/`
  is Qt-free and must stay that way (it's what makes the "Pro" split viable).
- There is **no resource-compilation step** to port (no `.qrc`/`pyrcc`), which
  removes the single most error-prone part of a typical PyQt→PySide move.
