# Roadmap Execution — Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Work top-to-bottom; lower tasks may remain undone if time runs out.

**Goal:** Execute the full improvement roadmap (Phases 0–5) as a dependency-ordered queue of independently-committed features on `feat/roadmap-execution`, ending in a PR against `main`.

**Architecture:** A new `core/events.py` event bus + an `events` SQLite table form the foundation; additive Pydantic settings + additive SQLite columns carry per-feature config; features layer on top in tiers (foundation → quick wins → observability/reliability → heavyweights). Local-first, offline, open-source-only.

**Tech Stack:** Python 3.12, PyQt6, Pydantic v2 (YAML), SQLite (WAL), httpx, feedparser, yt-dlp, whisper.cpp (`whisper-cli`), pytest (+ pytest-timeout, respx), ruff.

**Spec:** [`2026-06-26-roadmap-execution-design.md`](2026-06-26-roadmap-execution-design.md)

## Global Constraints

- **Local-first/offline:** no new runtime network calls beyond existing (feeds, downloads, yt-dlp, update check). Diarization model = one-time download, gated, default off.
- **Open-source deps only.** Any new dependency must be permissively licensed and added to `requirements.txt` (or `dev-requirements.txt`).
- **Python ≥ 3.12**, ruff line-length 100, target py312.
- **Per-task verification gate (THE RITUAL — applies to every task, do not skip):**
  1. Write failing test(s) first (TDD) where practical.
  2. `QT_QPA_PLATFORM=offscreen PYTHONPATH=. .venv/bin/pytest -q --timeout=180 --timeout-method=thread` → green (full suite, not just the new test).
  3. `.venv/bin/ruff check .` and `.venv/bin/ruff format --check .` → clean.
  4. Update `CHANGELOG.md` under an `## [Unreleased]` section (curated, human-readable line).
  5. Update `AGENTS.md` + add/extend a CLI command/flag if the feature is user-facing (keep `test_agents_doc.py` green).
  6. Append a line to `docs/plans/NIGHT-RUN-NOTES.md` (what landed / best-assumptions made / deferrals).
  7. One commit, Conventional Commits, footer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. A pre-commit hook runs ruff + pytest — let it.
- **Migrations:** additive only. SQLite via `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ADD COLUMN` guarded in `state.init_schema()` (match the `duration_sec` pattern). Settings via new Pydantic fields with defaults (old YAML must load unchanged).
- **On ambiguity/blockage:** make the best reasonable assumption, document it in the commit body + NIGHT-RUN-NOTES, continue. Never stop to ask.
- **Heavyweight escape hatch (Tier 3 L-items 1.5/2.2/8.2/3.5/10.2/10.3):** if a safe, tested, full build is not achievable, deliver a focused design doc under `docs/plans/` + a compiling, flag-gated skeleton, and mark it "design+skeleton" in NOTES. That counts as done.

## Task 0: Run setup (do this first, once)

**Files:** Create `docs/plans/NIGHT-RUN-NOTES.md`.

- [ ] Confirm on branch `feat/roadmap-execution` (`git branch --show-current`).
- [ ] Confirm baseline green: run THE RITUAL step 2 + 3 on the clean tree. If red, fix or record the pre-existing failure in NOTES before proceeding.
- [ ] Create `docs/plans/NIGHT-RUN-NOTES.md` with a header `# Night-run notes (2026-06-26)` and a `## Progress log` section.
- [ ] Commit: `chore(plan): night-run notes scaffold`.

---

# TIER 1 — Foundation + high-confidence features

## Task 1: Event bus core (`core/events.py`)  — roadmap 0.1

**Files:**
- Create: `core/events.py`
- Test: `tests/test_events.py`

**Interfaces — Produces:**
```python
# core/events.py
from dataclasses import dataclass, field

@dataclass
class Event:
    type: str
    ts: str               # ISO-8601 UTC
    show_slug: str | None = None
    guid: str | None = None
    payload: dict = field(default_factory=dict)

class EventType:
    EPISODE_DISCOVERED = "episode.discovered"
    EPISODE_DOWNLOAD_STARTED = "episode.download_started"
    EPISODE_DOWNLOADED = "episode.downloaded"
    EPISODE_TRANSCRIBE_STARTED = "episode.transcribe_started"
    EPISODE_TRANSCRIBED = "episode.transcribed"
    EPISODE_FAILED = "episode.failed"
    EPISODE_SKIPPED = "episode.skipped"
    EPISODE_DEFERRED = "episode.deferred"
    RUN_STARTED = "run.started"
    RUN_FINISHED = "run.finished"
    QUEUE_SIZED = "queue.sized"
    QUEUE_PAUSED = "queue.paused"
    QUEUE_RESUMED = "queue.resumed"
    FEED_CHECKED = "feed.checked"
    FEED_UNCHANGED = "feed.unchanged"
    FEED_ERROR = "feed.error"
    SHOW_ADDED = "show.added"
    SHOW_REMOVED = "show.removed"
    SHOW_ENABLED = "show.enabled"
    SHOW_DISABLED = "show.disabled"
    SETTINGS_CHANGED = "settings.changed"

def emit(event: Event) -> None: ...
def subscribe(matcher, callback) -> None: ...   # matcher: str (exact or "prefix.") | Callable[[Event], bool]
def reset() -> None: ...                          # test helper: clear subscribers
def now_iso() -> str: ...                          # ISO-8601 UTC, no tz suffix beyond 'Z' or +00:00
```

**Design:** module-level `_subscribers: list[tuple[matcher, callback]]` + a `threading.Lock`. `emit` snapshots subscribers under the lock, dispatches outside it; each callback wrapped in try/except → log to `logging.getLogger("paragraphos.events")`, never raise. Matcher: if `str` ending in `.` → prefix match; if `str` → exact; if callable → predicate. No Qt import.

- [ ] **Step 1 (failing test):** write `tests/test_events.py`:
```python
from core import events
from core.events import Event, EventType

def setup_function():
    events.reset()

def test_exact_match_delivery():
    seen = []
    events.subscribe(EventType.EPISODE_TRANSCRIBED, seen.append)
    events.emit(Event(type=EventType.EPISODE_TRANSCRIBED, ts=events.now_iso(), guid="g1"))
    assert len(seen) == 1 and seen[0].guid == "g1"

def test_prefix_match():
    seen = []
    events.subscribe("episode.", seen.append)
    events.emit(Event(type=EventType.EPISODE_FAILED, ts=events.now_iso()))
    events.emit(Event(type=EventType.RUN_STARTED, ts=events.now_iso()))
    assert [e.type for e in seen] == [EventType.EPISODE_FAILED]

def test_predicate_match():
    seen = []
    events.subscribe(lambda e: e.show_slug == "x", seen.append)
    events.emit(Event(type="any", ts=events.now_iso(), show_slug="x"))
    events.emit(Event(type="any", ts=events.now_iso(), show_slug="y"))
    assert len(seen) == 1

def test_callback_exception_isolated():
    seen = []
    events.subscribe("a.", lambda e: (_ for _ in ()).throw(RuntimeError("boom")))
    events.subscribe("a.", seen.append)
    events.emit(Event(type="a.x", ts=events.now_iso()))  # must not raise
    assert len(seen) == 1
```
- [ ] **Step 2:** run it → FAIL (module missing).
- [ ] **Step 3:** implement `core/events.py` per the design.
- [ ] **Step 4:** run → PASS; run THE RITUAL.
- [ ] **Step 5:** commit `feat(events): in-process typed event bus`.

## Task 2: Event persistence (`events` table)  — roadmap 0.1

**Files:**
- Modify: `core/state.py` (schema + new methods)
- Modify: `core/events.py` (persistence subscriber installer)
- Test: `tests/test_events_persistence.py`

**Interfaces — Produces:**
```python
# core/state.py (StateStore methods)
def append_event(self, ev) -> None: ...                     # ev: events.Event
def query_events(self, *, type_prefix: str | None = None, show_slug: str | None = None,
                 guid: str | None = None, since: str | None = None, limit: int = 1000) -> list[dict]: ...
def prune_events(self, retention_days: int) -> int: ...     # returns rows deleted
# core/events.py
def install_persistence(store) -> None: ...                  # subscribes a persister to "" (all)
```

**Schema (additive in `init_schema`):**
```sql
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL, type TEXT NOT NULL,
  show_slug TEXT, guid TEXT, payload_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_guid ON events(guid);
```

- [ ] Failing tests: append then query by prefix/guid/since; prune drops old rows, keeps recent. Use the isolated data dir fixture.
- [ ] Implement schema + methods + `install_persistence` (a subscriber on matcher `""` meaning all — extend matcher to treat `""` as match-all). Call `install_persistence(store)` + `store.prune_events(settings.event_retention_days)` at app startup (`ui/app_context.py` load) and in CLI bootstrap.
- [ ] RITUAL + commit `feat(events): persist events to sqlite with retention prune`.

## Task 3: Wire lifecycle emissions  — roadmap 0.1

**Files:**
- Modify: `core/state.py` (`set_status` emits episode events)
- Modify: `ui/worker_thread.py` (run/queue/feed events)
- Modify: `ui/activity_log.py` (subscribe to translate curated events → log lines)
- Modify: `cli.py` (show add/remove/enable/disable emit; ensure bus installed)
- Test: `tests/test_event_emissions.py`

**Design:** map `EpisodeStatus` → `EventType` in `set_status` (DOWNLOADING→download_started, DOWNLOADED→downloaded, TRANSCRIBING→transcribe_started, DONE→transcribed, FAILED→failed, SKIPPED→skipped, DEFERRED→deferred). Pass `show_slug`/`guid` and any known payload (error_text for failed). `activity_log` gains an `install_event_bridge()` that subscribes and renders a curated subset to the existing string sink (keep current direct `log()` calls working).

- [ ] Failing test: setting status emits the mapped event with guid/show_slug; bridge produces a non-empty activity line for `episode.failed`.
- [ ] Implement emissions at each point; install the bridge in `MainWindow` setup.
- [ ] RITUAL + commit `feat(events): emit episode/run/feed/show lifecycle events`.

## Task 4: Settings + Show schema expansion  — roadmap 0.2

**Files:**
- Modify: `core/models.py` (Settings + Show fields per spec §0.2)
- Modify: `cli.py` (`_SHOW_SETTABLE`, `set-setting` allow-list, settings JSON output)
- Modify: `ui/settings_pane.py` (sections for the new toggles where user-facing now: queue_order, caption_fallback_mode, confidence_*, use_etag_cache, event_retention_days, disk_guard_*)
- Test: `tests/test_settings_schema.py`, extend `tests/test_models*` if present

**Interfaces — Produces:** all fields listed in spec §0.2 (Settings) + Show `auto_vocab`, `min_duration_sec`, `max_duration_sec`, `notify`.

- [ ] Failing tests: (a) load a legacy YAML lacking all new keys → defaults applied, no error; (b) save+reload round-trips new values; (c) CLI `set <slug> auto_vocab=true` and `set-setting queue_order newest_first` persist; (d) emits `settings.changed` on save.
- [ ] Implement fields (defaults exactly as in spec), CLI allow-lists, minimal UI wiring, emit on save.
- [ ] RITUAL + commit `feat(settings): expand settings + per-show schema for roadmap features`.

## Task 5: Per-episode language auto-detect  — roadmap 1.1

**Files:**
- Modify: `core/transcriber.py` (parse `auto-detected language: xx` from output; return on result)
- Modify: `core/state.py` (`detected_language` column + setter; include in `_episode_dict`)
- Modify: `core/pipeline.py` / `core/export.py` (write detected language to frontmatter)
- Modify: `ui/add_show_dialog.py`, `ui/show_details_dialog.py` (language dropdown gains "Auto-detect" → `auto`)
- Modify: `ui/library_tab.py` or episode detail (show detected language)
- Test: `tests/test_transcriber_langdetect.py`, extend transcriber tests

**Design:** whisper-cli emits `whisper_full_with_state: auto-detected language: de (p = ...)` on stderr. Add a regex `re.compile(r"auto-detected language:\s*([a-z]{2,3})")`; capture during the existing stdout/stderr stream loop. Store on `TranscriptionResult.detected_language`. Persist when `language == "auto"`.

- [ ] Failing test: feed a sample stderr string to the parser helper → returns `"de"`; pipeline stores it; frontmatter contains it.
- [ ] Implement parser + plumbing + UI dropdown entry + display.
- [ ] RITUAL + commit `feat(transcribe): per-episode language auto-detect (-l auto) + capture`.

## Task 6: Auto-vocabulary prompt  — roadmap 1.2

**Files:**
- Create: `core/vocab.py`
- Modify: `core/pipeline.py` / `core/transcriber.py` invocation (seed `--prompt` from vocab when `show.auto_vocab` and no manual prompt)
- Modify: `ui/show_details_dialog.py` (auto_vocab toggle)
- Test: `tests/test_vocab.py`

**Interfaces — Produces:**
```python
# core/vocab.py
def build_vocab(transcripts: list[str], *, max_chars: int = 200, min_freq: int = 3) -> str: ...
```
**Design:** tokenize; collect capitalised tokens (and adjacent capitalised bigrams) that are NOT the first token of a sentence; drop a small German+English stopword set; rank by frequency ≥ `min_freq`; join with ", " until `max_chars`. Cache per show in `meta["vocab:{slug}"]` keyed by transcript count `meta["vocab_count:{slug}"]`; rebuild when count changes.

**Precedence:** manual `whisper_prompt` (non-empty) wins; else if `auto_vocab` → vocab; else "".

- [ ] Failing tests: extraction picks repeated proper nouns, skips sentence-initial-only words & stopwords, respects `max_chars`; precedence resolver (manual > auto > none); cache invalidates on count change.
- [ ] Implement; wire resolver into the invocation path; UI toggle.
- [ ] RITUAL + commit `feat(transcribe): auto-vocabulary prompt from past transcripts`.

## Task 7: Confidence marking  — roadmap 1.3

**Files:**
- Modify: `core/transcriber.py` (add `-oj`/`--output-json-full`; parse token `p`)
- Create: `core/confidence.py` (parse whisper json-full → per-segment/token confidence; mark low-confidence inline)
- Modify: `core/export.py` (render markers when `confidence_marking_enabled`)
- Modify: `core/state.py` (`mean_confidence REAL` column; store)
- Modify: library/episode UI (confidence indicator)
- Test: `tests/test_confidence.py`

**Interfaces — Produces:**
```python
# core/confidence.py
def parse_json_full(path) -> list[dict]: ...        # [{text, p}], token-level
def mean_confidence(tokens: list[dict]) -> float: ...
def mark_low_confidence(markdown: str, tokens: list[dict], threshold: float) -> str: ...  # wrap low-p spans
```
**Design:** when `settings.confidence_marking_enabled`, add `-oj` (json-full) to the whisper command (alongside txt/srt). Parse the `.json`; compute mean token probability; wrap tokens with `p < threshold` in a subtle marker (e.g. HTML `<mark>` in the rendered preview / `⟨word⟩` in raw markdown — choose markdown `==word==` highlight, Obsidian-compatible). Store mean confidence; show as a small badge.

**Best-assumption (documented):** default OFF (changes output format + adds runtime); threshold 0.5; markdown `==highlight==` for flagged spans.

- [ ] Failing tests: parse a sample json-full fixture → tokens+mean; `mark_low_confidence` wraps only sub-threshold tokens; disabled flag = no json-full flag added (assert command list).
- [ ] Implement; gate strictly behind the setting.
- [ ] RITUAL + commit `feat(transcribe): optional confidence marking via whisper json-full`.

## Task 8: Queue order toggle  — roadmap 2.5

**Files:**
- Modify: `ui/worker_thread.py` (claim query ORDER BY from `settings.queue_order`)
- Modify: `core/state.py` if the claim SQL lives there
- Modify: `ui/queue_tab.py` (order toggle control)
- Test: `tests/test_queue_order.py`

**Design:** ORDER BY map — `oldest_first`: `priority DESC, pub_date ASC`; `newest_first`: `priority DESC, pub_date DESC`; `shortest_first`: `priority DESC, (duration_sec IS NULL), duration_sec ASC`. Whitelist the three values (never interpolate raw).

- [ ] Failing test: seed episodes with varied pub_date/duration; assert claim sequence per mode.
- [ ] Implement; UI toggle writes the setting.
- [ ] RITUAL + commit `feat(queue): newest/oldest/shortest order toggle`.

## Task 9: Duration filters + filter surfacing  — roadmap 3.3

**Files:**
- Modify: `core/pipeline.py` (skip episodes outside [min,max] with reason `duration-out-of-range`)
- Modify: `ui/show_details_dialog.py` ("Filters" group: min/max duration + skip_shorts)
- Test: `tests/test_duration_filter.py`

**Design:** resolve effective min/max from show (fallback settings defaults); 0 = no limit. Apply where the episode's duration is known (feed `duration` / `duration_sec`); unknown → pass. Set `SKIPPED` + emit `episode.skipped` with reason.

- [ ] Failing tests: inside-range passes; below-min/above-max skipped; unknown duration passes.
- [ ] Implement + UI.
- [ ] RITUAL + commit `feat(filters): per-show min/max duration filters`.

## Task 10: Caption fallback mode  — roadmap 3.4

**Files:**
- Modify: `core/pipeline.py` (YouTube dispatch ~L528 builds chain from `settings.caption_fallback_mode`)
- Modify: `ui/settings_pane.py` (mode toggle)
- Test: `tests/test_caption_fallback.py`

**Design:** `manual_whisper` → manual captions → whisper; `manual_auto_whisper` → manual → auto (`auto_ok=True`) → whisper. Per-show `youtube_transcript_pref` overrides (`whisper` forces audio). Mock `fetch_manual_captions` raising `NoCaptionsAvailable` to assert chain progression.

- [ ] Failing tests: each mode's source order; per-show override wins.
- [ ] Implement + UI.
- [ ] RITUAL + commit `feat(youtube): caption fallback mode (manual→[auto]→whisper)`.

## Task 11: Wire `use_etag_cache`  — roadmap 8.5

**Files:**
- Modify: `ui/worker_thread.py` (only send stored etag/modified when `settings.use_etag_cache`)
- Modify: `ui/settings_pane.py` (toggle)
- Test: extend `tests/` feed test

**Design:** pass `etag`/`modified` to `build_manifest_with_url` only when the flag is on; otherwise pass `None`.

- [ ] Failing test: flag off → conditional headers absent (assert via respx or a fake client capturing headers).
- [ ] Implement + toggle.
- [ ] RITUAL + commit `feat(feeds): honour use_etag_cache setting`.

## Task 12: Integrity checks  — roadmap 6.5

**Files:**
- Modify: `core/transcriber.py` or `core/pipeline.py` (pre-transcribe model-hash + audio-non-truncation verify)
- Test: `tests/test_integrity.py`

**Design:** before invoking whisper: (a) verify model file SHA-256 == stored TOFU hash (reuse existing fingerprint helper); mismatch → `FAILED` reason `model-hash-mismatch`. (b) verify audio file size > 0 and passes the existing magic-byte sniff + a container-EOF sanity check; truncated/zero → `FAILED` reason `audio-truncated`. Emit `episode.failed`.

- [ ] Failing tests: zero-byte audio rejected; hash-mismatch surfaced (mock the stored hash).
- [ ] Implement.
- [ ] RITUAL + commit `feat(reliability): pre-transcribe model-hash + audio integrity checks`.

## Task 13: Undo for destructive actions  — roadmap 9.5

**Files:**
- Create: `ui/undo.py` (`UndoManager`)
- Modify: `ui/shows_tab.py` (remove-show → undoable), `ui/library_tab.py` (delete-transcript → trash+undo), `ui/queue_tab.py` (clear-queue / dequeue / deactivate → undoable)
- Modify: `core/paths.py` (trash dir helper) / `core/state.py` (snapshot+restore helpers)
- Test: `tests/test_undo.py`

**Interfaces — Produces:**
```python
# ui/undo.py
@dataclass
class UndoAction: label: str; undo: Callable[[], None]; expires_at: float
class UndoManager:
    def push(self, label: str, undo: Callable[[], None], ttl_sec: float = 60.0) -> None: ...
    def undo_last(self) -> str | None: ...     # runs + returns label, or None if empty/expired
    def peek(self) -> UndoAction | None: ...
```
**Design:** remove-show snapshots the `Show` model + its episode rows; undo re-inserts. delete-transcript moves the file to `<data_dir>/trash/<uuid>-<name>`; undo moves it back. clear-queue/dequeue/deactivate snapshot affected guids+statuses; undo restores. Surface via the main-window banner ("X — Undo", 60s). **Out of scope:** persistent "Recently deleted" (YAGNI).

- [ ] Failing tests: each action's undo restores prior state; expired action returns None; trash round-trip restores file. Use offscreen Qt + isolated data dir; stub msgboxes.
- [ ] Implement manager + wire each call site + banner action.
- [ ] RITUAL + commit `feat(ui): time-boxed undo for remove-show/delete-transcript/clear-queue`.

## Task 14: Empty-states + inline help + theme polish  — roadmap 9.3

**Files:**
- Create: `ui/widgets/empty_state.py`
- Modify: `ui/{queue,library,failed,shows}_tab.py` (show empty-state when model empty)
- Test: `tests/test_empty_state.py`

**Interfaces — Produces:** `class EmptyState(QWidget)` with `__init__(self, *, title, hint, action_text=None, on_action=None)`; theme-token styled.

**Best-assumption (documented):** copy per tab — Shows: "No shows yet" / "Add a podcast or YouTube channel to start." + "Add show"; Queue: "Nothing in the queue" / "Run a check or add episodes."; Library: "No transcripts yet" / "They'll appear here after the first run."; Failed: "Nothing failed 🎉".

- [ ] Failing tests: each tab shows EmptyState when backing model empty, hides when populated.
- [ ] Implement widget + wiring; verify light/dark via token usage (no hard-coded colors).
- [ ] RITUAL + commit `feat(ui): reusable empty-states + inline help across tabs`.

---

# TIER 2 — Observability + reliability (depends on Tier 1 event bus)

Each task: write tests first, follow THE RITUAL, one commit. Interfaces named so tasks compose.

## Task 15: Granular desktop notifications  — roadmap 7.4

**Files:** Create `core/notify_rules.py` (pure logic); Modify `app.py` (subscribe to bus → emit `notify`); Modify `ui/settings_pane.py`; Test `tests/test_notify_rules.py`.

**Interfaces — Produces:** `def should_notify(event, settings, show) -> bool` (checks `notify_events[type]`, `show.notify`, quiet-hours window). `def in_quiet_hours(now_hhmm, start, end) -> bool` (handles wrap past midnight).

- [ ] Tests: per-type gating; per-show opt-out; quiet-hours incl. midnight wrap. Implement; subscribe in `app.py`; UI toggles. RITUAL + commit `feat(notify): granular per-event/per-show notifications + quiet hours`.

## Task 16: Webhooks / on-event hooks  — roadmap 10.1

**Files:** Create `core/webhooks.py`; Modify app/cli bootstrap (subscribe); Modify `ui/settings_pane.py` (manage list); Test `tests/test_webhooks.py`.

**Design:** subscriber filters by configured event types; `kind="command"` runs script with event JSON on stdin (subprocess, timeout, never blocks — run in a thread); `kind="post"` does httpx POST of event JSON, target validated by `safe_url`. All failures logged, swallowed.

- [ ] Tests: fires only for matching events; failure swallowed+logged; `safe_url` rejects internal/loopback POST targets. Implement (dispatch in a worker thread/executor). RITUAL + commit `feat(hooks): event-driven webhooks (command + POST), non-blocking`.

## Task 17: Episode timeline  — roadmap 7.2

**Files:** Create `core/timeline.py` (`def phase_durations(events_for_guid) -> dict`); Modify episode context-menu/show-details to show it; Test `tests/test_timeline.py`.

- [ ] Tests: durations computed from a synthetic event sequence (discovered→downloaded→transcribed→done). Implement + minimal view. RITUAL + commit `feat(observability): per-episode phase timeline`.

## Task 18: Structured, filterable logs + export  — roadmap 7.3

**Files:** Modify `ui/log_dock.py` (LogsPane gains filters backed by `query_events`); add export button; Test `tests/test_logs_export.py`.

- [ ] Tests: filter query returns expected rows; export writes valid JSON/CSV. Implement. RITUAL + commit `feat(logs): filterable event log view + export`.

## Task 19: Stats dashboard  — roadmap 7.1

**Files:** Modify `core/stats.py` (throughput, avg realtime-factor, success rate, burn-down); add a Stats view/panel; Test `tests/test_stats_dashboard.py`.

**Design:** realtime-factor = audio_sec / wall_sec (wall from transcribe_started→transcribed events). Success rate = done / (done+failed) over a window.

- [ ] Tests: each metric on synthetic events/episodes. Implement + view. RITUAL + commit `feat(stats): throughput / realtime-factor / success-rate / burn-down dashboard`.

## Task 20: Auto-retry + backoff + error taxonomy  — roadmap 6.1

**Files:** Create `core/errors.py` (`def categorize(exc) -> str`); Modify `core/pipeline.py` (retry transient with backoff, store attempts + `error_category` column); Modify `ui/failed_tab.py` (show category); Test `tests/test_error_taxonomy.py`.

**Design:** categories `network|not_found|too_large|format|whisper|disk|unknown`. Transient (`network`,`disk`) retried with capped backoff (reuse downloader delays pattern); permanent not. `error_category` + `attempts` columns (additive).

- [ ] Tests: exception→category mapping; transient retried then failed-after-cap; permanent not retried. Implement. RITUAL + commit `feat(reliability): error taxonomy + transient auto-retry with backoff`.

## Task 21: Self-healing startup + health check  — roadmap 6.2

**Files:** Modify `core/state.py` (extend `recover_in_flight` to reset stale rows); Create `core/health.py` (`def run_health_check(ctx) -> list[dict]`); Modify banner/a health panel; Test `tests/test_health.py`.

**Design:** on launch reset DOWNLOADING/TRANSCRIBING rows with no live job to a resumable state. Health check: deps present, model hash ok, data dir writable, disk free ≥ guard. Surface failures.

- [ ] Tests: stale rows recovered; health reports each failure mode (mock conditions). Implement. RITUAL + commit `feat(reliability): self-healing startup + health self-check`.

## Task 22: Disk guard  — roadmap 6.3

**Files:** Create `core/diskguard.py` (`def free_gb(path)`, `def estimate_needed(...)`, `def should_pause(settings, path)`); Modify `core/pipeline.py`/worker (pre-flight + auto-pause + banner); Test `tests/test_diskguard.py`.

- [ ] Tests: pause triggers below `disk_guard_min_free_gb`; estimate sane. Implement (auto-pause sets queue paused + banner). RITUAL + commit `feat(reliability): disk guard with pre-flight estimate + auto-pause`.

## Task 23: Crash visibility + bug-report bundle  — roadmap 6.4

**Files:** Modify `app.py` (install `sys.excepthook` + Qt message handler → activity log + events); Create `core/bugbundle.py` (`def build_bundle(dest) -> Path`); add an Export action (About/Settings); Test `tests/test_bugbundle.py`.

**Design:** bundle = zip of recent logs + redacted settings (strip paths/tokens) + recent events + version fingerprints. Excepthook routes uncaught exceptions to the log without crashing the UI where possible.

- [ ] Tests: excepthook logs a synthetic exception; bundle contains expected files; redaction removes sensitive fields. Implement. RITUAL + commit `feat(diagnostics): crash logging + one-click bug-report bundle`.

---

# TIER 3 — Queue/perf, ingestion, heavyweights (best-effort; design+skeleton if needed)

For each: attempt a full TDD build following THE RITUAL. For the L-items flagged **(escape hatch)**, if a safe tested build isn't achievable, instead write `docs/plans/<slug>-design.md` + a compiling flag-gated skeleton and record "design+skeleton" in NOTES, then move on.

## Task 24: Drag-to-reorder queue  — 2.1
**Files:** `ui/queue_tab.py` (persist row reorder → `priority`); `core/state.py` (bulk priority setter); `tests/test_queue_reorder.py`.
- [ ] Tests: reordering rows rewrites priority so claim order matches the visual order. Implement. RITUAL + commit `feat(queue): drag-to-reorder persists as priority`.

## Task 25: Scheduling windows  — 2.3
**Files:** Create `core/schedule_windows.py` (`def within_windows(now_hhmm, windows) -> bool`); Modify worker (idle outside windows when `processing_windows_enabled`); `ui/settings_pane.py`; `tests/test_schedule_windows.py`.
- [ ] Tests: window membership incl. midnight wrap; worker skips claiming outside windows. Implement. RITUAL + commit `feat(scheduling): processing-window gating for the worker`.

## Task 26: Pausable individual downloads  — 2.4
**Files:** `core/downloader.py` (honour a per-download pause flag/callback in the stream loop); `ui/queue_tab.py` (pause/resume a single row); `tests/test_download_pause.py`.
- [ ] Tests: pause flag halts the loop leaving a `.part`; resume continues (download already resumable). Implement. RITUAL + commit `feat(downloads): pause/resume an individual download`.

## Task 27: CPU/RAM budget on battery  — 8.4
**Files:** Create `core/power.py` (`def on_battery() -> bool` via `pmset -g batt`); Modify `core/load.py` (drop to `battery_load_level` when on battery & `pause_on_battery`/budget); `tests/test_power.py`.
- [ ] Tests: parse `pmset` output for battery/AC; load profile reflects battery state (mock `on_battery`). Implement. RITUAL + commit `feat(perf): adapt whisper load to power state`.

## Task 28: GPU/Metal + model auto-pick  — 8.1
**Files:** Modify `core/transcriber.py` (Metal flag pass-through, no-op-safe) + `core/hw.py` (`def recommend_model(cores, ram_gb) -> str`); `ui/settings_pane.py`; `tests/test_model_autopick.py`.
- [ ] Tests: `recommend_model` heuristic returns expected sizes per machine class; metal flag toggles in command list. Document Metal-compiled caveat in NOTES. RITUAL + commit `feat(perf): metal toggle + model auto-pick heuristic`.

## Task 29: Real upload dates for back-catalogue  — 3.1
**Files:** Create `core/backcat_dates.py` (background yt-dlp per-video date fill for rows with synthetic dates); Modify worker/scheduler to run it non-blocking; `tests/test_backcat_dates.py`.
- [ ] Tests: rows lacking real dates get filled (mock yt-dlp metadata); does not block open. Implement. RITUAL + commit `feat(youtube): background back-catalogue date backfill`.

## Task 30: Playlist support  — 3.2
**Files:** `core/youtube.py` (resolve a playlist URL → video list); `cli.py add`/`add_show_dialog` accept playlists (`source="youtube"`, playlist marker); `tests/test_youtube_playlist.py`.
- [ ] Tests: playlist URL resolves to videos and seeds episodes like a channel (mock yt-dlp). Implement. RITUAL + commit `feat(youtube): watch a playlist like a channel`.

## Task 31: Bulk export  — 4.1
**Files:** Create `core/bulk_export.py` (`def export(transcripts, fmt, dest)` for `md|json|pdf`); `ui/library_tab.py` (multi-select export); `tests/test_bulk_export.py`.
**Design:** md = concatenated/zipped files; json = structured array; pdf = best-effort (pure-python; if a dep is needed, add it or document md/json-only + defer pdf). Obsidian/Notion-friendly frontmatter retained.
- [ ] Tests: md + json exports valid; pdf produced or cleanly reported unsupported. Implement. RITUAL + commit `feat(export): bulk export selected transcripts (md/json[/pdf])`.

## Task 32: Transcript publishing  — 10.4
**Files:** Create `core/publish.py` (static searchable HTML site + RSS of transcripts); `cli.py publish`; `tests/test_publish.py`.
- [ ] Tests: generates index + per-transcript pages + valid RSS; client-side search asset present. Implement. RITUAL + commit `feat(publish): static searchable transcript site + RSS export`.

## Task 33: Wizard OPML import + setup check  — 9.1
**Files:** Modify `ui/first_run_wizard.py` (OPML import via defusedxml + dep verification step); Create `core/opml.py` (`def parse_opml(text) -> list[dict]`); `tests/test_opml.py`.
- [ ] Tests: OPML parse extracts feeds (XXE-safe); dep check reports missing whisper/yt-dlp. Implement. RITUAL + commit `feat(onboarding): OPML import + setup verification in wizard`.

## Task 34: Command palette (Cmd-K) + keyboard nav  — 9.2
**Files:** Create `ui/command_palette.py` (fuzzy action list, Cmd-K); Modify `ui/main_window.py` (register actions + shortcuts); `tests/test_command_palette.py`.
- [ ] Tests: palette filters actions by query; selecting runs the action; core shortcuts registered. Implement (offscreen Qt). RITUAL + commit `feat(ui): Cmd-K command palette + keyboard navigation`.

## Task 35: Re-upload dedupe **(escape hatch)**  — 3.5
**Files:** Create `core/dedupe.py` (title-similarity near-dup detection); integrate at feed-ingest; `tests/test_dedupe.py`. Fingerprint-based dedup → design note if not tractable.
- [ ] Tests: near-duplicate titles flagged/skipped; distinct kept. Implement title-similarity; defer audio-fingerprint to `docs/plans/dedupe-fingerprint-design.md` if needed. RITUAL + commit.

## Task 36: Parallel processing **(escape hatch)**  — 2.2
**Files:** `ui/worker_thread.py` (transcribe pool up to `transcribe_concurrency`, default 1); `tests/test_parallel_transcribe.py`.
- [ ] If safely testable: implement bounded concurrent transcription + tests. Else: `docs/plans/parallel-transcription-design.md` + keep setting at 1 (skeleton). RITUAL + commit.

## Task 37: Streaming transcription **(escape hatch)**  — 8.2
- [ ] Almost certainly **design+skeleton**: write `docs/plans/streaming-transcription-design.md` (chunked-download → incremental whisper approach, risks, interface) + a flag-gated no-op skeleton. RITUAL + commit `docs(plan): streaming transcription design + skeleton`.

## Task 38: Speaker diarization (sherpa-onnx) **(escape hatch)**  — 1.5
**Files:** `docs/plans/diarization-design.md`; Create `core/diarize.py` skeleton behind `diarization_enabled` (default off); `requirements` note for `sherpa-onnx` (Apache-2.0, one-time model download).
- [ ] Expected **design+skeleton**: document the sherpa-onnx integration (model fetch, A/B/C labelling, frontmatter/SRT speaker tags), provide a flag-gated `diarize()` stub + tests for the stub's no-op path. Do NOT add the heavy dep download to the default path. RITUAL + commit `feat(diarize): sherpa-onnx diarization design + flag-gated skeleton`.

## Task 39: Local HTTP/JSON API **(escape hatch)**  — 10.2
**Files:** Create `core/api_server.py` (localhost-only, read + queue-control over existing CLI functions); `cli.py serve`; `tests/test_api_server.py`.
- [ ] If tractable: minimal stdlib `http.server` (no new dep) exposing `/shows`, `/status`, `/queue` (GET) + queue control (POST), bound to 127.0.0.1, with a token. Else design+skeleton. RITUAL + commit.

## Task 40: MCP server **(escape hatch)**  — 10.3
**Files:** Create `core/mcp_server.py` (stdio MCP wrapping CLI/API functions); `tests/test_mcp_server.py`.
- [ ] If tractable with an OSS MCP lib (add to deps): expose query/queue/manage tools. Else design+skeleton referencing the local API surface. RITUAL + commit.

---

# Finalisation (after the queue stops, whenever that is)

## Task 41: Wrap up + PR
- [ ] Ensure full suite green + ruff clean on the final tree.
- [ ] Curate `CHANGELOG.md` `[Unreleased]` into highlights (per "always write curated changelog" preference) — not just the raw commit list.
- [ ] Finalise `docs/plans/NIGHT-RUN-NOTES.md`: completed vs design-only vs deferred, with assumptions.
- [ ] `git push -u origin feat/roadmap-execution`.
- [ ] Open PR against `main` via `gh pr create` with a curated summary table (feature → status: done / design+skeleton / deferred) and a link to the spec.
- [ ] Do NOT merge — leave for Matthias's morning review.

---

## Self-review notes (author check)

- **Spec coverage:** every roadmap ID 0.1–10.4 maps to a task (0.1→T1-3, 0.2→T4, 1.1→T5, 1.2→T6, 1.3→T7, 2.5→T8, 3.3→T9, 3.4→T10, 8.5→T11, 6.5→T12, 9.5→T13, 9.3→T14, 7.4→T15, 10.1→T16, 7.2→T17, 7.3→T18, 7.1→T19, 6.1→T20, 6.2→T21, 6.3→T22, 6.4→T23, 2.1→T24, 2.3→T25, 2.4→T26, 8.4→T27, 8.1→T28, 3.1→T29, 3.2→T30, 4.1→T31, 10.4→T32, 9.1→T33, 9.2→T34, 3.5→T35, 2.2→T36, 8.2→T37, 1.5→T38, 10.2→T39, 10.3→T40). 8.3 already shipped (no task). 
- **Already-shipped guard:** 8.3 omitted by design; 8.5 reduced to wiring (T11).
- **Type consistency:** event matcher accepts str/prefix/`""`(all)/predicate consistently across T1–T3, T15–T19. `detected_language` is per-episode (T5), not a Show field. `confidence_threshold`/`confidence_marking_enabled` defined in T4, consumed in T7.
