# YouTube hardening + Per-show episode browser — Design

**Date:** 2026-06-26
**Status:** Brainstorm approved; ready for implementation plan.
**Target version:** v1.6.0 (tentative)

## Context

The "Add YouTube Channel" feature shipped (dedicated Shows-tab button,
focused popup, editable slug, thumbnail, the four backfill modes +
since-date-defaults-to-first-video, the per-video manual-caption
checkbox, the channel-feed-poll fix for new-video discovery, CLI
`add` YouTube-awareness, settings/prompt docs). This effort **hardens**
that feature against real-world edge cases and adds a **source-agnostic
per-show episode browser** for manual / bulk triggering.

The whole thing is **10 workstreams**. WS6 (an earlier "Edit YouTube
show" idea) is absorbed into WS10.

## Locked decisions (from brainstorming)

- **Shorts:** skipped by default; an "Include Shorts" checkbox opts in.
- **Captions:** strict — import only a manual subtitle in the chosen
  language, else whisper. Auto-generated captions are **never** used.
  `language = auto` ⇒ accept the channel's default manual track, else
  whisper.
- **Thumbnail:** real channel **avatar** (fallback chain), not a video
  frame.
- **Video URL pasted into the add dialog:** offer "Add the channel that
  posted this?" rather than rejecting.
- **Live / premiere / upcoming:** *deferred*, re-probed **on the next
  daily check**; not a hard failure.
- **Members-only / age-restricted / region-locked:** specific,
  user-facing error message.
- **WS8 (status taxonomy) and WS9 (docs + global defaults + dead-option
  cleanup):** both in.
- **WS10 (episode browser):** folded in now, **replaces WS6**. It is a
  single **resizable/maximizable per-show window** that keeps everything
  `ShowDetailsDialog` does today (header/artwork, settings form,
  feed-health, Advanced) **plus** the full episode browser.
- **YouTube back-catalogue in the browser:** auto-loaded on open via
  **paced background streaming** so the UI never stalls.
- **From-a-date trigger:** date picker + "Queue all since", alongside
  multi-select + "Queue selected".

## Out of scope (YAGNI)

Chapters in transcripts, SponsorBlock, playlist URLs, members-only
sign-in/cookies, per-video diarization. Revisit on demand.

---

## WS1 — Input robustness

**Goal:** accept the channel-URL forms people actually paste.

- Extend `core/youtube.py:parse_youtube_url` to recognise `/c/<name>`,
  `/user/<name>`, and a bare `@handle` / `name`. These carry no
  channel-id, so they get a new kind (e.g. `channel_url`) carrying the
  page URL to resolve.
- Generalise resolution: `core/youtube_meta.resolve_handle_to_channel_id`
  becomes (or gains a sibling) `resolve_channel_url_to_id(url)` that
  fetches the given channel page and scrapes `<link rel="canonical">`
  (existing trick), working for `@handle`, `/c/`, `/user/`.
- **Video URL → channel:** if the pasted URL parses as a video, resolve
  the video's channel (`yt-dlp --print %(channel_id)s` or page scrape)
  and offer "Add the channel that posted this video?" in the dialog
  instead of the current hard reject.
- Fix the dialog placeholder copy ("…or video URL").

**Tests:** parser table for `/c/`, `/user/`, bare handle, video→channel
offer path (mocked resolution).

---

## WS2 — Enumeration engine

**Goal:** one reusable, accurate, non-blocking channel enumerator. Used
by the add dialog (backfill), CLI (WS5), and the episode browser (WS10).

- `core/youtube_meta.enumerate_channel_videos(channel_id, *, limit=None,
  date_after=None, include_shorts=False)`:
  - `date_after` → yt-dlp `--dateafter YYYYMMDD` (server-side filter,
    early stop, no client-side date guessing → fixes dropped-undated
    videos).
  - `include_shorts=False` → enumerate the channel **`/videos`** tab
    (natively excludes Shorts); `True` → root/`/shorts`.
  - Streaming variant for WS10: yields batches as yt-dlp emits lines so
    the caller can render incrementally.
- **Off the GUI thread, cancellable, with a running count.** The add
  dialog's synchronous `enumerate_channel_videos` call moves to a
  worker thread (mirror `_YoutubeResolveThread`): marquee + "found N…"
  + Cancel. Soft warning past a threshold (e.g. > 1000).
- **Empty result feedback:** "0 videos match this selection" instead of
  a silent empty add.

**Tests:** `date_after` builds the right yt-dlp args; `/videos` vs root
URL selection; streaming batches; cancel stops the worker.

---

## WS3 — Duplicate-channel guard

**Goal:** can't add the same channel twice under a different slug.

- Resolve to channel-id first (so `/c/`, `/@handle`, `/channel/UC…` all
  collapse to one id), then reject in `_do_save` (GUI) and `cmd_add`
  (CLI) if any existing show's feed URL carries the same `channel_id`.
  Error names the existing show.

**Tests:** add same channel via two URL forms → second rejected.

---

## WS4 — Content classification

**Goal:** Shorts / live / restricted videos handled deliberately, not as
generic failures.

- **Backfill:** `include_shorts=False` ⇒ `/videos` tab (WS2).
- **Pipeline branch** (`core/pipeline.py:_process_youtube_episode`)
  classifies each video before/at download:
  - **Short** (show skips Shorts): terminal `skipped` (WS8) with reason.
    Ongoing detection: a cheap `yt-dlp --print` probe (duration / URL)
    when the show skips Shorts.
  - **Live / premiere / upcoming:** `deferred` (WS8) — not a failure.
  - **Members-only / age-restricted / region-locked:** classify from
    yt-dlp's error signature → terminal `failed` with a **specific,
    friendly** `error_text` (not a raw dump).
- Classification lives in a small `core/youtube_classify.py` that maps
  yt-dlp metadata/error output → an enum, unit-tested against captured
  yt-dlp error fixtures.

**Tests:** fixtures of yt-dlp error/metadata output → correct
classification + message.

---

## WS5 — CLI parity

**Goal:** the AI-operator path matches the GUI.

- `cli.py add <youtube-url>` enumerates via WS2 honouring `--backlog
  last:N | since:DATE | all` (deep, not just the 15-video feed window).
- New flags: `--captions/--whisper` (transcript pref), `--skip-shorts/
  --include-shorts`.
- New `cli.py backlog <slug> --backlog …` (a.k.a. `backfill`) — the
  headless twin of WS10's bulk triggering: seed + queue older videos
  for an existing show.

**Tests:** `add` youtube uses the enumerator + flags; `backlog` seeds
the right rows.

---

## WS7 — Avatar + language

**Goal:** nicer artwork + real language coverage.

- **Avatar:** during resolve, scrape the channel **avatar** (`og:image`
  / avatar thumbnail from the channel page). Fallback chain:
  og:image → yt-dlp `thumbnails` → latest-video frame → blank. Stored
  as `Show.artwork_url` (consistent with podcasts).
- **Language:** expand the dialog picker beyond de/en to a curated list
  + `auto`. Mirror in `Settings.youtube_default_language`. Strict-caption
  rule for `auto` defined in the locked decisions.

**Tests:** avatar fallback chain; language list seeds from settings;
`auto` + strict-captions behaviour.

---

## WS8 — Status & retry taxonomy

**Goal:** represent skip/defer as first-class states, not error_text.

- Add two episode states alongside `pending/downloading/downloaded/
  transcribing/done/failed/stale`:
  - **`skipped`** — terminal, with reason (Short, members-only). Not
    retried, not shown as a red failure.
  - **`deferred`** — live/upcoming; **re-probed on the next daily
    check** (the worker re-classifies; once the stream ends it becomes a
    normal `pending` episode). Not counted as failed.
- Queue / Failed / episode-browser display them distinctly (new pill
  kinds + filters). `core/state.py` `EpisodeStatus` + any status-count
  SQL learns the new values.
- Migration: existing rows untouched; new states only ever set going
  forward.

**Tests:** a deferred episode re-probes and promotes on the next check;
skipped never retries; status counts include the new states.

---

## WS9 — Docs, global defaults & cleanup

**Goal:** discoverability + remove the dead option.

- Docs: README, AGENTS.md, CHANGELOG, settings "Automation & remote
  control" help, example agent prompt — fetch-more/episode-browser,
  Shorts, languages, new CLI flags + `backlog` command.
- **Global Settings defaults** for the new per-show knobs:
  `youtube_skip_shorts_default`, expanded `youtube_default_language`,
  strict-captions default. Mirror existing `youtube_default_*` pattern.
- **Remove the dead `auto-captions` affordance.** Auto-generated
  captions are never used, so drop it from `youtube_transcript_pref`'s
  allowed values / settings / prompt / `set` keys (keep tolerant read of
  legacy values, but no UI path to set it).

**Tests:** `set` rejects `auto-captions`; settings round-trip new
defaults; docs-string tests still pass.

---

## WS10 — Per-show window (replaces WS6)

**Goal:** one comprehensive, resizable per-show window: everything
`ShowDetailsDialog` has today **plus** a full episode browser with
manual + bulk triggering, source-agnostic (podcast + YouTube).

**Structure** (grow `ui/show_details_dialog.py`, or a new
`ui/show_window.py` that subsumes it; keep the double-click entry point):

- Keep: artwork header, settings form (now incl. editable YouTube
  language / caption-pref / skip-Shorts — the absorbed WS6 edit),
  feed-health panel, Advanced group.
- **Episode browser** replacing the last-10 table:
  - All episodes (Date / Title / Status), **multi-select**, scrollable,
    status pills incl. WS8 `skipped`/`deferred`.
  - Per-row (existing): Run next / Run now / Re-transcribe / Open
    transcript.
  - **Bulk toolbar:** "Queue selected"; date picker + **"Queue all
    since"**. Triggering = set `pending` + priority bump (reuse
    `prioritize`/`retranscribe` machinery); a not-yet-seeded YouTube
    video is seeded first, then queued.
  - **Filters:** by status (pending / failed / skipped / deferred /
    done).
- **YouTube back-catalogue (paced background streaming):** on open, show
  DB episodes instantly; kick off the WS2 **streaming** enumerator off
  the GUI thread to append older videos in throttled batches (batched
  row inserts, cancel on close, cap + "load more" past a threshold) so
  the window never stalls. Discoverable-but-unseeded rows render with an
  "available" affordance; triggering seeds + queues them.
- **Performance:** for large channels, virtualise / page the table
  (batch inserts, avoid per-row widgets where possible) so thousands of
  rows stay responsive.

**Tests:** full list renders > 10; multi-select + "Queue selected"
queues the right guids; "Queue all since <date>" selects the right set;
streaming enumeration appends + is cancellable; triggering an unseeded
YouTube row seeds + queues it.

---

## Cross-cutting

- **Enumeration engine (WS2)** is the shared spine for WS5, WS7-avatar
  (page scrape), and WS10. Build it first and well.
- **Status taxonomy (WS8)** underpins WS4 and WS10 display. Land it with
  WS4.
- Every workstream lands **green with its own tests**; prefer captured
  fixtures (yt-dlp output, channel feeds) over live network in tests.

## Phasing

1. **Correctness** — WS1, WS2, WS3.
2. **Classification + state** — WS4 + WS8.
3. **Reach** — WS5.
4. **Episode browser** — WS10 (absorbs WS6).
5. **Polish** — WS7.
6. **Docs & cleanup** — WS9.

## Risks

- yt-dlp rate-limiting under bulk enumeration / per-video probes → batch,
  cap, cache within a session.
- Shorts detection reliability (the `/videos` tab is the safe lever;
  the per-video probe is the fallback).
- QTableWidget performance at thousands of rows → batch inserts /
  virtualisation in WS10.
- Live/deferred retry must not livelock → bounded re-probe on the daily
  check only.
