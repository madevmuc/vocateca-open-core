# Paragraphos — Improvement Roadmap

- **Date:** 2026-06-26
- **Status:** Approved (portfolio roadmap; each feature gets its own design before implementation)
- **Owner:** Matthias

## Context

Paragraphos is a local, tray-based PyQt6 app that watches podcast RSS feeds and
YouTube channels, downloads audio, and transcribes it with whisper.cpp (captions
are reused when available). It already has: a queue with priorities, a per-show
episode browser (with a paced back-catalogue stream), a transcript library, feed
health, a backlog model, a CLI + an LLM-operator surface, an activity log, and a
settings pane.

This roadmap captures the agreed set of improvements from a brainstorming pass
(10 areas × 5 ideas). It is a **map, not a single implementable plan** — each
feature gets its own focused design before it is built.

## Guiding constraints

- **Local-first, offline.** No paid services, no runtime calls to external APIs,
  no cloud. Everything runs on the user's machine.
- **Open-source dependencies only.** A *one-time* model download (as already
  happens for whisper models) is acceptable; runtime network use is not.
- **LLM features stay external.** The app exposes an LLM-operator surface
  (CLI/agent/prompt); LLM-based post-processing is left to external tooling and
  is explicitly out of scope here.

## Whisper capability note (Area 1)

The app uses whisper.cpp (`whisper-cli`, ggml models). Of the transcription
ideas:

- **Native to whisper.cpp:** language auto-detect (`-l auto`), custom prompt /
  auto-vocabulary (`--prompt`), token-confidence (`--output-json-full` token `p`).
- **Needs extra software:** speaker diarization — decided to use **sherpa-onnx**
  (Apache-2.0, ONNX-runtime, no PyTorch, no gated token, fully local). Rejected
  pyannote/WhisperX (heavy PyTorch + Hugging-Face-gated model download) and
  whisper.cpp `--tinydiarize` (turn-markers only, English-only).
- **Dropped:** LLM post-processing (external, per constraints above).

## Phases

Effort tags: `S` small · `M` medium · `L` large. "Done when" is a one-line
acceptance sketch to anchor the later per-feature design.

### Phase 0 — Foundation (unblocks much of Phases 2 & 5)

| ID | Feature | Effort | Done when |
|----|---------|--------|-----------|
| 0.1 | Internal event bus (extend `activity_log` into typed events) | M | Pipeline/queue/feed lifecycle emit typed events that notifications, the timeline, and webhooks subscribe to. |
| 0.2 | Settings-schema expansion (notifications, scheduling, budgets, caption modes) | S | New settings persist + round-trip; UI + CLI + LLM prompt see them. |

### Phase 1 — Quick wins (cheap, mostly independent)

| ID | Feature | Effort | Done when |
|----|---------|--------|-----------|
| 1.1 | Per-episode language auto-detect | S | A show can opt into `auto`; whisper detects per episode; result recorded. |
| 1.2 | Auto-vocabulary prompt from past transcripts | S | Frequent proper nouns from a show's transcripts seed its whisper `--prompt`. |
| 1.3 | Confidence marking | M | Low-probability tokens (from JSON-full) are flagged in the transcript/UI. |
| 3.3 | Shorts/Live/Members + min/max-duration filters in the UI | S | Per-show filter controls; the pipeline honours them. |
| 3.4 | Caption fallback mode setting | S | Setting toggles `manual→auto→whisper` vs `manual→whisper` (default `manual→whisper`). |
| 8.5 | Incremental feed polls (ETag / conditional GET) | S | Unchanged feeds return 304; checks skip re-parse and run faster. |
| 8.3 | Download cache/reuse + resumable | M | Existing audio is reused; interrupted downloads resume instead of restarting. |
| 9.3 | Empty-states + inline help + theme polish | S | Every empty list has a helpful state; light/dark both clean. |
| 9.4 | Bulk actions everywhere | M | Multi-select add + multi-show settings edits work. |
| 9.5 | Undo for destructive actions | M | Remove-show / delete-transcript are undoable (not just double-confirm). |
| 2.5 | Queue order toggle (newest/oldest, short-first) | S | User can flip queue ordering; worker claim order follows. |

### Phase 2 — Events, notifications, observability (needs Phase 0)

| ID | Feature | Effort | Done when |
|----|---------|--------|-----------|
| 7.4 | **Granular** desktop notifications | M | Per-event-type, per-show, and quiet-hours toggles; notifications fire only as configured. |
| 10.1 | Webhooks / on-event hooks | M | User can run a script / POST on chosen events; failures are logged, never block. |
| 7.2 | Episode timeline | M | Per-episode phase durations (discovered→downloaded→transcribed→done) are viewable. |
| 7.3 | Structured, filterable logs + export | M | Logs filter by level/show/phase and export. |
| 7.1 | Stats dashboard | M | Throughput, avg realtime-factor, success rate, queue burn-down rendered. |

### Phase 3 — Queue & performance (touches the worker)

| ID | Feature | Effort | Done when |
|----|---------|--------|-----------|
| 2.2 | Parallel processing (concurrency cap) | L | N episodes process concurrently up to a settings cap, safely. |
| 8.2 | Streaming transcription (whisper while downloading) | L | Transcription starts before the download fully completes. |
| 8.4 | CPU/RAM budget (throttle on battery) | M | Whisper thread/processor counts adapt to a budget / power state. |
| 2.1 | Drag-to-reorder queue | M | Manual reordering persists as priority. |
| 2.3 | Scheduling (time-of-day / power) | M | Processing windows configurable; worker respects them. |
| 2.4 | Resumable / pausable individual downloads | M | A single download can be paused/resumed. |
| 8.1 | GPU/Metal accel + model auto-pick | M | Metal toggle + model size chosen from machine capability. |

### Phase 4 — Ingestion depth & reliability hardening

| ID | Feature | Effort | Done when |
|----|---------|--------|-----------|
| 3.1 | Real upload dates for the back-catalogue | M | A lazy/background full-extract fills dates for available rows without blocking open. |
| 3.2 | Playlist support | M | A YouTube playlist can be watched like a channel. |
| 3.5 | Re-upload dedupe across sources | L | Near-duplicate episodes (title similarity / fingerprint) are detected. |
| 6.1 | Auto-retry + backoff + error taxonomy | M | Transient failures retry with backoff; failures carry a clear category. |
| 6.2 | Self-healing startup + health self-check | M | Stale in-flight rows recover on launch; a health check surfaces issues. |
| 6.3 | Disk guard with pre-flight estimate + auto-pause | M | Low disk auto-pauses with an estimate shown. |
| 6.4 | Crash visibility + bug-report bundle | M | Uncaught exceptions reach the activity log; a one-click bundle exports logs/state. |
| 6.5 | Integrity checks | S | Model hash + non-truncated mp3 verified before transcribing. |

### Phase 5 — Heavyweights / AI / integrations

| ID | Feature | Effort | Done when |
|----|---------|--------|-----------|
| 1.5 | Speaker diarization (**sherpa-onnx**, local) | L | Transcripts carry speaker labels (A/B/C); fully local, no token, no PyTorch. |
| 4.1 | Bulk export | M | Selected transcripts export to Markdown/PDF/JSON (Obsidian/Notion friendly). |
| 10.2 | Local HTTP/JSON API | L | A localhost API exposes query/queue/manage for headless control. |
| 10.3 | MCP server | M | An LLM agent can query/queue/manage the library via MCP. |
| 10.4 | Transcript publishing | M | Export a searchable static site / RSS of transcripts. |
| 9.1 | Wizard: OPML import + setup check | M | First-run imports OPML and verifies whisper/yt-dlp/sherpa setup. |
| 9.2 | Command palette (Cmd-K) + keyboard nav | M | Cmd-K jumps anywhere / runs actions; core flows are keyboard-driven. |

## Out of scope (explicitly dropped)

- Area 5 — semantic / vector search, RAG Q&A, entity index, quote finder, keyword alerts.
- 1.4 — LLM transcription post-processing (left to external tooling via the LLM surface).
- 7.5 — weekly digest.
- 9 — show suggestions in onboarding.
- 10 — cross-machine sync.

## Sequencing & next steps

Build Phase 0 first (the event bus + settings schema unblock Phases 2 and 5),
then Phase 1 quick wins for immediate value. Each feature gets its own focused
design (and a writing-plans implementation plan) when it is picked up.

**Immediate next:** design **Phase 0 (foundation)** + the **Phase 1 quick wins**
in depth, then take that design to an implementation plan.
