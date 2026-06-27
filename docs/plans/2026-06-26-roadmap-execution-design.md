# Roadmap Execution — Design Spec

- **Date:** 2026-06-26
- **Status:** Approved for autonomous overnight execution
- **Owner:** Matthias
- **Branch:** `feat/roadmap-execution` → PR against `main`
- **Source roadmap:** [`2026-06-26-app-improvement-roadmap-design.md`](2026-06-26-app-improvement-roadmap-design.md)

## Purpose & operating mode

This spec turns the full improvement roadmap (Phases 0–5) into a single
**dependency-ordered execution program** that an autonomous overnight run works
through top-to-bottom. It exists so the run needs **no follow-up questions**:
every feature below carries a locked design decision (or an explicit
best-assumption default).

### Operating rules (decided with the user 2026-06-26)

1. **Scope:** everything named in the roadmap. Executed as a prioritized queue,
   dependency-first. If the night runs short, lower-tier items remain undone —
   that is acceptable and expected.
2. **Integration:** all work on `feat/roadmap-execution`, **one commit per
   feature** (Conventional Commits), ending in a PR against `main` with a
   curated summary. Nothing is pushed to `main` directly.
3. **On ambiguity/blockage:** make the best reasonable assumption, document it in
   the commit body and in `docs/plans/NIGHT-RUN-NOTES.md`, and continue. Never
   stop to ask.
4. **Quality gate (per feature, non-negotiable):** TDD where practical, `ruff
   check .` + `ruff format --check .` clean, full `pytest` suite green
   (`QT_QPA_PLATFORM=offscreen .venv/bin/pytest -q --timeout=180
   --timeout-method=thread`), CHANGELOG updated under an `Unreleased` section.
   A feature is not "done" and not committed until its gate passes.
5. **Reality of L-heavyweights:** the large new-subsystem items (1.5, 2.2, 8.2,
   3.5, 10.2, 10.3) are attempted **last**. If a safe, tested, full build is not
   achievable autonomously, the deliverable for that item is a focused design
   doc under `docs/plans/` **plus** a compiling skeleton/feature-flag, marked in
   NIGHT-RUN-NOTES as "design + skeleton, needs follow-up." This is a success,
   not a failure, for those items.

### What is already done (verified in code — do NOT rebuild)

- **8.3** download cache/reuse + resumable — `core/downloader.py:119` (Range
  resume, `.part` handling, on-disk size match, slug-drift recovery). Complete.
- **8.5** ETag/conditional GET + 304 short-circuit — `core/rss.py:150`, with
  per-show `feed_etag:{slug}` / `feed_modified:{slug}` meta storage in the
  worker. **Only gap:** the `use_etag_cache` setting is never consulted. Reduced
  to a 1-line wiring task (see 8.5 below).
- whisper already accepts `-l <lang>` (incl. `auto`) and `--prompt`; `Show`
  already has `language`, `whisper_prompt`, `skip_shorts`,
  `youtube_transcript_pref`. Caption path already has an `auto_ok` /
  `auto-captions` mode (`core/pipeline.py:528`, `core/youtube_captions.py`).
- `state.recover_in_flight()` already recovers in-flight rows on launch (basis
  for 6.2). Model SHA-256 TOFU already exists (basis for 6.5).

## Architecture touchpoints (anchors)

| Concern | File(s) |
|---|---|
| Settings (Pydantic + YAML) | `core/models.py` (`Settings` ~L82, `Show` ~L15) |
| Settings UI | `ui/settings_pane.py` |
| State / SQLite | `core/state.py` (`set_status`, schema, `meta` K-V, `record_completion`) |
| Pipeline | `core/pipeline.py` (`download_phase`, `transcribe_phase`, YouTube dispatch ~L462) |
| Transcriber | `core/transcriber.py` (whisper invocation ~L360, output parse ~L519) |
| Worker | `ui/worker_thread.py` (`CheckAllThread`, claim query, signals) |
| Activity log | `ui/activity_log.py` (`log`, `set_sink`) |
| Tabs | `ui/{queue,library,failed,shows,local_transcript}_tab.py`, `ui/settings_pane.py` |
| CLI / agent surface | `cli.py`, `AGENTS.md` |
| Tests | `tests/`, `tests/conftest.py` (offscreen Qt, msgbox stubs) |

---

## Tier 1 — Foundation + high-confidence features (full design, build confidently)

### 0.1 Internal event bus  `[M]`

**New module `core/events.py`.**

- `Event` dataclass: `type: str`, `ts: str` (ISO-8601 UTC), `show_slug: str |
  None`, `guid: str | None`, `payload: dict` (JSON-serialisable).
- `EventType` string constants grouped by domain:
  - episode: `episode.discovered`, `episode.download_started`,
    `episode.downloaded`, `episode.transcribe_started`, `episode.transcribed`,
    `episode.failed`, `episode.skipped`, `episode.deferred`.
  - run/queue: `run.started`, `run.finished`, `queue.sized`, `queue.paused`,
    `queue.resumed`.
  - feed: `feed.checked`, `feed.unchanged`, `feed.error`.
  - show: `show.added`, `show.removed`, `show.enabled`, `show.disabled`.
  - settings: `settings.changed`.
- `EventBus` singleton (module-level, like `activity_log`):
  - `subscribe(matcher, callback)` — `matcher` is an event-type string, a prefix
    (`"episode."`), or a predicate `Callable[[Event], bool]`.
  - `emit(event)` — synchronous dispatch; **each callback is wrapped in
    try/except and failures are logged, never propagated** (same contract as
    `activity_log`). Thread-safe via a lock; safe to emit from worker threads.
  - `subscribe`/`emit` are import-safe with zero subscribers (no Qt dependency
    in `core/`).
- **Persistence:** new SQLite table `events(id INTEGER PK, ts TEXT, type TEXT,
  show_slug TEXT, guid TEXT, payload_json TEXT)` + index on `(type)` and
  `(guid)`. A built-in subscriber persists every event. Startup prunes events
  older than `event_retention_days` (default 90). This table is the backbone for
  7.1/7.2/7.3.
- **Emission points:** `state.set_status()` is the choke point for episode
  lifecycle — emit there (map status → event type). Worker emits
  `run.started`/`run.finished`/`queue.sized`; RSS pass emits
  `feed.checked`/`feed.unchanged`/`feed.error`; show add/remove/enable/disable
  and settings save emit their events.
- **Activity log bridge:** `activity_log.log()` stays as-is (string API
  unchanged). A subscriber translates a curated subset of events into
  activity-log lines so the existing dock keeps working with richer content.
- **Tests:** subscribe/emit, matcher kinds, callback-exception isolation,
  persistence + prune, status→event mapping.

**Decision:** synchronous dispatch (not a queue/thread) — simplest, and
subscribers that need async (webhooks) spawn their own thread.

### 0.2 Settings-schema expansion  `[S]`

Add Pydantic fields (defaults chosen so existing YAML loads unchanged). Group &
defaults:

```python
# events / observability
event_retention_days: int = 90
# notifications (granular) — 7.4
notify_events: dict[str, bool] = {"episode.transcribed": True, "run.finished": True, "episode.failed": True}
notify_quiet_hours_enabled: bool = False
notify_quiet_hours_start: str = "22:00"
notify_quiet_hours_end: str = "08:00"
# webhooks — 10.1
webhooks_enabled: bool = False
# stored as list of {events: [..], kind: "command"|"post", target: str, enabled: bool}
webhooks: list[dict] = []
# queue ordering — 2.5
queue_order: Literal["oldest_first", "newest_first", "shortest_first"] = "oldest_first"
# duration filters defaults — 3.3 (0 = no limit)
default_min_duration_sec: int = 0
default_max_duration_sec: int = 0
# caption fallback — 3.4
caption_fallback_mode: Literal["manual_whisper", "manual_auto_whisper"] = "manual_whisper"
# confidence marking — 1.3
confidence_marking_enabled: bool = False
confidence_threshold: float = 0.5
# scheduling windows — 2.3
processing_windows_enabled: bool = False
processing_windows: list[str] = []  # ["HH:MM-HH:MM", ...]
# power/budget — 8.4
pause_on_battery: bool = False
battery_load_level: Literal["quiet", "balanced", "full"] = "quiet"
# parallel transcription cap — 2.2
transcribe_concurrency: int = 1
# metal / model auto-pick — 8.1
whisper_metal_enabled: bool = True
whisper_model_autopick: bool = False
# diarization — 1.5
diarization_enabled: bool = False
# disk guard — 6.3
disk_guard_enabled: bool = True
disk_guard_min_free_gb: int = 5
```

Per-`Show` additions: `auto_vocab: bool = False` (1.2),
`min_duration_sec: int = 0`, `max_duration_sec: int = 0` (3.3),
`notify: bool = True` (per-show notification opt-out, 7.4).
`detected_language` is **not** a Show field — it's per-episode (stored in the
episodes table, see 1.1).

CLI `_SHOW_SETTABLE` and `set-setting` allow-lists extended to cover the new
keys. Settings UI grows a section per concern. `settings.changed` event emitted
on save. **Tests:** round-trip load/save with old YAML (defaults applied), CLI
set/get for new keys.

### 1.1 Per-episode language auto-detect  `[S]`

- Add `auto` to the language dropdown in `ui/add_show_dialog.py` and
  `ui/show_details_dialog.py` (label "Auto-detect").
- Capture detection: whisper-cli logs `auto-detected language: xx` to stderr.
  Parse it in `core/transcriber.py` (already streaming stdout/stderr), return on
  the result object.
- New episodes column `detected_language TEXT` (ALTER, same pattern as
  `duration_sec`). `record_completion` (or a new setter) stores it. Written to
  markdown frontmatter; shown in library/episode detail.
- Emit `episode.transcribed` payload with `detected_language`.
- **Tests:** parser extracts language from sample stderr; round-trips into state
  and frontmatter.

### 1.2 Auto-vocabulary prompt  `[S]`

- New `core/vocab.py`: `build_vocab(transcripts: list[str], max_chars=200) ->
  str`. Heuristic — collect capitalised tokens / bigrams not at sentence start,
  rank by frequency, drop stopwords, return comma-separated until cap.
- Per-show `auto_vocab` flag. When on, before transcription compute (or read
  cached `meta["vocab:{slug}"]`) and pass as `--prompt`. **Precedence:** an
  explicit `whisper_prompt` wins; if empty and `auto_vocab` on, use the vocab.
  Cache invalidated when the show's transcript count changes.
- UI toggle in show-details; CLI settable.
- **Tests:** vocab extraction on sample transcripts; precedence (manual >
  auto > none); cache invalidation.

### 2.5 Queue order toggle  `[S]`

- Worker claim query ORDER BY driven by `settings.queue_order`:
  `oldest_first` → `priority DESC, pub_date ASC`; `newest_first` →
  `priority DESC, pub_date DESC`; `shortest_first` →
  `priority DESC, duration_sec ASC NULLS LAST`.
- Toggle control in `ui/queue_tab.py` toolbar (writes the setting, takes effect
  on next claim).
- **Tests:** claim order honours each mode (seed episodes, assert claim
  sequence).

### 3.3 Duration filters + content-type filter surfacing  `[S]`

- Per-show `min_duration_sec`/`max_duration_sec` (0 = no limit), defaults from
  settings. In `download_phase` (or feed-ingest), episodes whose known duration
  falls outside the range are set `SKIPPED` with reason
  `duration-out-of-range`. Unknown duration → not filtered.
- UI: duration min/max controls + the existing `skip_shorts` toggle grouped as
  "Filters" in show-details. Members-only/live remain classifier-driven
  (already handled).
- **Tests:** episodes inside/outside range; unknown duration passes.

### 3.4 Caption fallback mode  `[S]`

- `settings.caption_fallback_mode`. The YouTube dispatch
  (`core/pipeline.py:528`) builds the source chain from it:
  `manual_whisper` → try manual captions → whisper; `manual_auto_whisper` →
  manual → auto captions (`auto_ok=True`) → whisper. Per-show
  `youtube_transcript_pref` still overrides (`whisper` forces audio).
- UI toggle in settings (+ note in show-details). **Tests:** chain selection per
  mode with mocked caption fetch raising `NoCaptionsAvailable`.

### 8.5 Wire `use_etag_cache`  `[S]`

- Worker only sends stored etag/modified when `settings.use_etag_cache` is True;
  when False, skip conditional headers (force full re-fetch). Add the toggle to
  settings UI. **Tests:** headers present/absent per flag.

### 6.5 Integrity checks  `[S]`

- Before transcription: verify the model file SHA-256 against the stored TOFU
  hash (reuse existing fingerprint code) and verify the audio is non-truncated
  (magic-byte sniff already exists for download; add a final-size/!=0 +
  container-EOF sanity check). On mismatch → `FAILED` with a clear reason +
  `episode.failed` event. **Tests:** truncated/zero-byte audio rejected; hash
  mismatch surfaced.

### 9.5 Undo for destructive actions  `[M]`

- New `ui/undo.py`: `UndoManager` holding a short stack of reversible actions,
  each `{label, undo_callable, expires_at}`.
- Covered actions: **remove-show** (snapshot the `Show` + its episode rows;
  undo re-adds), **delete-transcript** (move file to
  `<data_dir>/trash/` instead of hard delete; undo restores), **clear-queue**
  (snapshot pending guids; undo restores PENDING), **dequeue/deactivate**
  (status restore).
- UX: after the action, a banner/toast "X — Undo" (reuse the main-window banner
  mechanism) for 60s; also a persistent "Recently deleted" affordance is **out
  of scope** (YAGNI) — time-boxed undo only.
- **Tests:** each action's undo restores prior state; expiry drops the entry.

### 9.3 Empty-states + inline help + theme polish  `[S]`

- New reusable `ui/widgets/empty_state.py` (icon + title + hint + optional
  action button), theme-token styled.
- Wire into Queue (idle/empty), Library (no transcripts), Failed (none), Shows
  (no shows) — each with a one-line helpful hint and a primary action where
  natural ("Add your first show").
- Audit the new widgets in light + dark. **Tests:** empty-state shows when the
  backing model is empty, hides when populated (offscreen Qt).

---

## Tier 2 — Events/observability + reliability (build on Tier 1)

### 7.4 Granular desktop notifications  `[M]`

Subscribe to the event bus; for each event check `notify_events[type]`, per-show
opt-out (new `Show.notify: bool = True`), and quiet-hours; fire via the existing
`ParagraphosApp.notify` signal. **Tests:** config gating + quiet-hours window
logic (pure function), tested without real notifications.

### 10.1 Webhooks / on-event hooks  `[M]`

A bus subscriber dispatches configured webhooks: `kind="command"` runs a script
(args = event JSON on stdin), `kind="post"` does an HTTP POST of the event JSON.
**Runs in a worker thread; failures logged, never block the pipeline.** POST
targets pass through `safe_url` (SSRF guard). Settings UI to manage the list.
**Tests:** dispatch fires for matching events only; failure is swallowed +
logged; SSRF guard rejects internal URLs.

### 7.2 Episode timeline  `[M]`

From the `events` table, compute per-episode phase durations
(discovered→downloaded→transcribed→done). A read-only view (dialog from episode
context menu, or a panel in show-details). **Tests:** duration computation from a
synthetic event sequence.

### 7.3 Structured, filterable logs + export  `[M]`

Upgrade `LogsPane` (or add a tab) to query the `events` table with filters
(type/show/phase/level) and an export-to-file button (JSON/CSV). **Tests:**
filter query returns expected rows; export writes valid file.

### 7.1 Stats dashboard  `[M]`

Extend `core/stats.py` to compute throughput (episodes/day), avg realtime-factor
(audio_sec / wall_sec from events), success rate, queue burn-down. Render in a
Stats view/panel. **Tests:** stat computations on synthetic data.

### 6.1 Auto-retry + backoff + error taxonomy  `[M]`

Define an error taxonomy (`network`, `not_found`, `too_large`, `format`,
`whisper`, `disk`, `unknown`) mapped from exceptions in the pipeline. Transient
categories (`network`, `disk`) auto-retry with backoff (extend the existing
downloader retry to the pipeline level, capped attempts; store attempt count).
`error_category` column on episodes; surfaced in Failed tab. **Tests:** category
mapping; transient retried, permanent not.

### 6.2 Self-healing startup + health self-check  `[M]`

Build on `recover_in_flight()`: on launch, reset stale DOWNLOADING/TRANSCRIBING
rows (no live job) to a resumable state, and run a health check (deps present,
model hash ok, data dir writable, disk space) surfaced in the banner / a health
panel. **Tests:** stale rows recovered; health check reports each failure mode.

### 6.3 Disk guard  `[M]`

Pre-flight free-space check before download/transcribe with an estimate
(audio size + transcript overhead). Below `disk_guard_min_free_gb` → auto-pause
the queue + banner. **Tests:** guard triggers below threshold; estimate sane.

### 6.4 Crash visibility + bug-report bundle  `[M]`

Install a `sys.excepthook` (+ Qt message handler) that routes uncaught
exceptions to the activity log + events. A "Export bug report" action bundles
logs + settings (redacted) + recent events + versions into a zip. **Tests:**
excepthook logs; bundle contains expected files (redaction verified).

---

## Tier 3 — Queue/perf, ingestion depth, heavyweights (best-effort; design+skeleton if needed)

These touch the worker or add subsystems. Build fully where tractable; otherwise
land a focused design doc + flagged skeleton (per Operating Rule 5).

### Queue & performance

- **2.1 Drag-to-reorder queue `[M]`** — persist row reorder as `priority`.
  Build fully (queue_tab already has priority drag scaffolding).
- **2.3 Scheduling `[M]`** — worker checks `processing_windows` before claiming;
  outside windows it idles. Build fully.
- **2.4 Pausable individual downloads `[M]`** — per-download pause flag honoured
  by the streaming loop (download already resumable). Build fully.
- **8.4 CPU/RAM budget on battery `[M]`** — detect power state (macOS
  `pmset -g batt`), drop to `battery_load_level` on battery. Build fully.
- **8.1 GPU/Metal + model auto-pick `[M]`** — Metal usually compiled into
  whisper.cpp; expose a no-op-safe flag + model auto-pick from `hw.py` core
  count/RAM. Build fully (flag + heuristic), document the Metal caveat.
- **2.2 Parallel processing `[L]`** — transcribe pool up to
  `transcribe_concurrency`. **Risk:** CPU contention + worker re-architecture.
  Best-effort; if not safely testable overnight → design + skeleton behind the
  (default-1) setting.
- **8.2 Streaming transcription `[L]`** — whisper while downloading. **High
  risk** (whisper wants a complete file; needs chunking). Most likely
  **design + skeleton**, not a full build.

### Ingestion depth & reliability

- **3.1 Real upload dates for back-catalogue `[M]`** — background yt-dlp
  metadata fill for rows lacking real dates, non-blocking. Build fully.
- **3.2 Playlist support `[M]`** — treat a playlist URL as a channel-like
  source. Build fully.
- **3.5 Re-upload dedupe `[L]`** — title-similarity/fingerprint near-dup
  detection across sources. Best-effort; likely title-similarity heuristic only,
  fingerprint deferred to design note.

### Heavyweights / AI / integrations

- **4.1 Bulk export `[M]`** — selected transcripts → Markdown/PDF/JSON.
  Markdown/JSON full build; PDF via a lightweight pure-Python path or documented
  dependency. Build fully (PDF best-effort).
- **10.4 Transcript publishing `[M]`** — static searchable site + RSS export of
  transcripts. Build fully (static HTML generator).
- **9.1 Wizard: OPML import + setup check `[M]`** — extend `first_run_wizard`
  with OPML import (defusedxml already present) + dep verification. Build fully.
- **9.2 Command palette (Cmd-K) + keyboard nav `[M]`** — fuzzy action palette +
  core keyboard shortcuts. Build fully.
- **1.5 Speaker diarization (sherpa-onnx) `[L]`** — **new dependency + one-time
  model download.** Per Operating Rule 5 and roadmap intent, deliver a focused
  design doc + an integration skeleton behind `diarization_enabled` (default
  off). A full local build with model download is unlikely to be safely
  completable + testable overnight; **design + skeleton** is the expected
  outcome.
- **10.2 Local HTTP/JSON API `[L]`** — localhost FastAPI/stdlib server exposing
  query/queue/manage. Build a minimal read-only + queue-control server if
  tractable; otherwise design + skeleton.
- **10.3 MCP server `[M]`** — MCP wrapper over the CLI/API surface. Build a
  minimal server if tractable (stdio MCP over existing CLI functions); otherwise
  design + skeleton.

---

## Out of scope (unchanged from roadmap)

Area 5 (semantic/vector search, RAG, entity index, quote finder, keyword
alerts); 1.4 (LLM post-processing); 7.5 (weekly digest); onboarding show
suggestions; cross-machine sync.

## Cross-cutting conventions for the run

- **Migrations:** new SQLite columns/tables via additive `ALTER`/`CREATE IF NOT
  EXISTS` in `state.init_schema()`, matching the existing `duration_sec` pattern.
  New settings are additive Pydantic fields with defaults (old YAML loads clean).
- **CLI + AGENTS.md:** any new user-facing capability gets a CLI command/flag and
  an AGENTS.md line (the LLM-operator surface must stay complete). `test_agents_doc.py`
  must stay green.
- **Local-first constraint:** no runtime network calls beyond what already
  exists (feeds, downloads, yt-dlp, update check). Diarization model is a
  one-time download, gated + off by default.
- **Commit message footer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **NIGHT-RUN-NOTES.md:** a running log of what landed, what was best-assumed (+
  the assumption), and what was deferred to design+skeleton. Drives the final PR
  summary.

## Acceptance for the overnight run

- `feat/roadmap-execution` contains one green-gated commit per completed feature,
  in Tier order.
- Every commit individually passes ruff + full pytest.
- `docs/plans/NIGHT-RUN-NOTES.md` records progress + assumptions + deferrals.
- A PR against `main` with a curated highlights summary (per the user's
  "always write curated changelog" preference), explicitly listing completed vs
  design-only items.
