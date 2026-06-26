# YouTube hardening + Per-show episode browser — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Harden the shipped "Add YouTube Channel" feature against real-world edge cases and add a source-agnostic per-show episode browser with manual/bulk/from-date triggering.

**Architecture:** A shared off-thread channel **enumeration engine** (`core/youtube_meta`) is the spine; a small **classification** module routes Shorts/live/restricted videos; two new episode **states** (`skipped`, `deferred`) make that routing first-class; the per-show window grows into the episode browser. Pure-logic core modules are unit-tested with captured fixtures (no live network); PyQt surfaces use the existing offscreen-QPA test pattern.

**Tech Stack:** Python 3.12, PyQt6, yt-dlp (subprocess), httpx, feedparser, SQLite (`core/state.py`), pytest + respx, ruff.

**Design of record:** `docs/plans/2026-06-26-youtube-and-episode-browser-design.md`

---

## How to execute this with sub-agents

Tasks are tagged `[parallel-group: X]`. Within a group, tasks touch disjoint files and can be dispatched to **concurrent sub-agents**. Across groups there are ordering dependencies (a later group imports symbols a earlier group creates). Rules:

- **Same-file tasks never run in parallel.** `ui/add_show_dialog.py`, `core/pipeline.py`, `cli.py`, and `core/youtube_meta.py` are each touched by several tasks — serialize those, or give each agent its own git worktree (`isolation: worktree`) and merge.
- Each task is independently verifiable: it ends with its own passing test + commit. A reviewing agent (superpowers:code-reviewer) checks each task against this plan before the next starts.
- After every phase, run the **full** suite (`.venv/bin/python -m pytest -q`) + `ruff check . && ruff format --check .` before opening the next phase.

Run all commands from `/Users/matthiasmaier/dev/paragraphos` with the venv: `PYTHONPATH=. .venv/bin/python …`, tests via `.venv/bin/python -m pytest`.

---

# Phase 1 — Correctness (WS1, WS2, WS3)

`[parallel-group: P1]` — WS1-parser, WS2-enumerator, and WS3-dedup-core are independent (different files/functions). The dialog wiring tasks that consume them are serialized at the end of the phase because they share `ui/add_show_dialog.py`.

## Task 1.1 — Parse `/c/`, `/user/`, bare handle  `[parallel-group: P1]`

**Files:**
- Modify: `core/youtube.py`
- Test: `tests/test_youtube.py`

**Step 1 — failing tests:**
```python
def test_parse_c_custom_url():
    u = parse_youtube_url("https://www.youtube.com/c/Veritasium")
    assert u.kind == "channel_url" and u.value == "https://www.youtube.com/c/Veritasium"

def test_parse_user_legacy_url():
    u = parse_youtube_url("https://www.youtube.com/user/Vsauce")
    assert u.kind == "channel_url"

def test_parse_bare_handle():
    u = parse_youtube_url("@veritasium")
    assert u.kind == "channel_url" and "veritasium" in u.value

def test_parse_handle_still_works():
    assert parse_youtube_url("https://www.youtube.com/@veritasium").kind == "handle"
```

**Step 2 — run, expect FAIL.** `.venv/bin/python -m pytest tests/test_youtube.py -q`

**Step 3 — implement.** Add a `channel_url` kind to `YoutubeKind`. In `parse_youtube_url`, after the `/@` branch add `/c/` and `/user/` → `YoutubeUrl("channel_url", url)`; before the final `raise`, accept a bare `@handle`/`name` (no scheme/host) → `channel_url` with a normalized `https://www.youtube.com/<...>` URL. Keep `/@handle` (full URL) returning `handle` for the existing fast path.

**Step 4 — run, expect PASS.**

**Step 5 — commit:** `feat(youtube): parse /c/, /user/, and bare-handle channel URLs`

## Task 1.2 — Resolve arbitrary channel URL → id  `[parallel-group: P1]`

**Files:**
- Modify: `core/youtube_meta.py` (add `resolve_channel_url_to_id`)
- Test: `tests/test_youtube_meta.py`

**Step 1 — failing test** (mock `_http_get_text` to return HTML with a canonical link, mirroring `test_resolve_handle_uses_http_fast_path`):
```python
def test_resolve_channel_url_scrapes_canonical(monkeypatch):
    html = '<link rel="canonical" href="https://www.youtube.com/channel/UCabc1234567890123456789">'
    monkeypatch.setattr("core.youtube_meta._http_get_text", lambda url, timeout=10.0: html)
    assert resolve_channel_url_to_id("https://www.youtube.com/c/X") == "UCabc1234567890123456789"
```

**Step 2 — FAIL.**

**Step 3 — implement** `resolve_channel_url_to_id(url)`: GET the page via `_http_get_text`, match `_CANONICAL_RE`; on miss, yt-dlp fallback (`--print %(channel_id)s`). Refactor `resolve_handle_to_channel_id` to delegate (`resolve_channel_url_to_id(f"https://www.youtube.com/@{handle}")`).

**Step 4 — PASS. Step 5 — commit:** `feat(youtube): generic channel-URL → channel-id resolver`

## Task 1.3 — `video → channel` resolver  `[parallel-group: P1]`

**Files:** Modify `core/youtube_meta.py` (`resolve_video_to_channel_id`); Test `tests/test_youtube_meta.py`.

**Step 1 — failing test** (mock `_run_ytdlp` to print a channel id). **Step 3 — implement** `resolve_video_to_channel_id(video_id)` via `yt-dlp --print %(channel_id)s https://www.youtube.com/watch?v=<id>` (fixture-tested). **Commit:** `feat(youtube): resolve a video to its channel id`

## Task 1.4 — Enumerator: `date_after` + `include_shorts`  `[parallel-group: P1]`

**Files:** Modify `core/youtube_meta.py:enumerate_channel_videos`; Test `tests/test_youtube_meta.py`.

**Step 1 — failing tests** (assert the yt-dlp argv, patching `_run_ytdlp` to capture args):
```python
def test_enumerate_dateafter_arg(monkeypatch):
    seen = {}
    monkeypatch.setattr("core.youtube_meta._run_ytdlp", lambda args, timeout=300: (seen.setdefault("a", args), "")[1])
    enumerate_channel_videos("UCabc", date_after="2020-01-01")
    assert "--dateafter" in seen["a"] and "20200101" in seen["a"]

def test_enumerate_excludes_shorts_via_videos_tab(monkeypatch):
    seen = {}
    monkeypatch.setattr("core.youtube_meta._run_ytdlp", lambda args, timeout=300: (seen.setdefault("a", args), "")[1])
    enumerate_channel_videos("UCabc", include_shorts=False)
    assert any(a.endswith("/videos") for a in seen["a"])
```

**Step 3 — implement:** add kwargs `date_after: str | None = None`, `include_shorts: bool = False`. `date_after` → append `--dateafter <YYYYMMDD>` (strip dashes). `include_shorts=False` → target `…/channel/<id>/videos`; else the channel root. Keep `limit` behaviour.

**Step 5 — commit:** `feat(youtube): enumerate with date_after + shorts-excluding /videos tab`

## Task 1.5 — Off-thread, cancellable enumeration worker  `[parallel-group: P1]`

**Files:** Create `core/youtube_meta.py` streaming helper *(or)* keep batching in the UI thread class; Add `_YoutubeEnumerateThread` to `ui/add_show_dialog.py`. Test `tests/test_add_show_dialog_youtube.py`.

**Detail:** A `QThread` that calls `enumerate_channel_videos` and emits `done(list)` / `error(str)` / optional `progress(int)`. Mirror `_YoutubeResolveThread`. The add dialog's `_add_from_youtube` enumeration moves onto it (marquee + Cancel + "found N…"); empty result → `QMessageBox.information(... "0 videos match this selection")`. **Serialize** with other `add_show_dialog.py` tasks.

**Test:** patch `enumerate_channel_videos`, drive the thread, assert rows seeded + empty-feedback path. **Commit:** `feat(add-dialog): off-thread cancellable channel enumeration`

## Task 1.6 — Channel-id dedup (core + GUI + CLI)  `[serialize: add_show_dialog.py, cli.py]`

**Files:** Add `core/youtube.py:channel_id_from_feed_url`; Modify `ui/add_show_dialog.py:_do_save`, `cli.py:cmd_add`. Tests: `tests/test_youtube.py`, `tests/test_add_show_dialog_youtube.py`, `tests/test_cli_add_youtube.py`.

**Step 1 — failing tests:** `channel_id_from_feed_url("…?channel_id=UCx")==“UCx”`; adding a channel whose id already exists (under any slug) is rejected with a message naming the existing show (GUI `_do_save` returns without appending; CLI returns exit `3`).

**Step 3 — implement:** helper via `urllib.parse`. In `_do_save`/`cmd_add`, before slug checks, compute the new show's channel-id and reject if any existing youtube show resolves to the same id.

**Commit:** `feat(youtube): reject adding the same channel twice (by channel id)`

## Task 1.7 — Video-URL → "add the channel?" offer  `[serialize: add_show_dialog.py]`

**Files:** Modify `ui/add_show_dialog.py:_on_youtube_url_resolve`; fix placeholder. Test `tests/test_add_show_dialog_youtube.py`.

**Detail:** when `parse_youtube_url` returns `kind=="video"`, instead of the current reject, `QMessageBox.question("Add the channel that posted this video?")`; on Yes, `resolve_video_to_channel_id` → continue the channel resolve flow. Update placeholder to "Paste a YouTube channel URL (or a video — we'll offer its channel)".

**Test:** patch the resolver + `QMessageBox.question`→Yes; assert it proceeds to channel preview. **Commit:** `feat(add-dialog): offer the channel when a video URL is pasted`

**Phase 1 gate:** full suite + ruff green. Dispatch 1.1–1.5 in parallel (worktrees if needed); run 1.6, 1.7 serially after.

---

# Phase 2 — Classification + status taxonomy (WS4, WS8)

WS8 lands first (WS4 sets the new states). `core/state.py` and `core/pipeline.py` are each single-owner here — serialize within each file.

## Task 2.1 — Add `skipped` + `deferred` states  `[parallel-group: P2a]`

**Files:** Modify `core/state.py` (`EpisodeStatus`, any status-set helpers, status-count SQL); Test `tests/` (new `tests/test_status_taxonomy.py`).

**Steps:** failing test asserts `EpisodeStatus.SKIPPED`/`DEFERRED` exist and `set_status` round-trips them; a deferred episode is excluded from the "failed" counts and from the normal claim query (`_claim_next_processable` must not pick `skipped`/`deferred`). Implement enum + claim-query exclusion. Commit: `feat(state): skipped + deferred episode states`

## Task 2.2 — Status pill kinds + tab display  `[parallel-group: P2a]`

**Files:** Modify `ui/show_details_dialog.py:_STATUS_PILL_KIND`, the Failed/Queue tab filters as needed. Test the mapping. Commit: `feat(ui): render skipped/deferred status pills`

## Task 2.3 — Classification module  `[parallel-group: P2a]`

**Files:** Create `core/youtube_classify.py`; Test `tests/test_youtube_classify.py`.

**Detail:** `classify_video(meta_or_error) -> ("ok"|"short"|"live"|"members_only"|"age_restricted"|"region_locked", message)`. Pure function over yt-dlp metadata dict / stderr string. Capture real yt-dlp error strings into `tests/fixtures/ytdlp/*.txt` and assert each maps to the right class + friendly message. Commit: `feat(youtube): classify shorts/live/restricted from yt-dlp output`

## Task 2.4 — Wire classification into the pipeline  `[serialize: pipeline.py]`

**Files:** Modify `core/pipeline.py:_process_youtube_episode`; Test `tests/test_pipeline_youtube.py`.

**Detail:** before/at download, classify. `short` + show skips Shorts → `EpisodeStatus.SKIPPED` (reason). `live` → `DEFERRED`. restricted classes → `FAILED` with the friendly message. Otherwise proceed. Add `Show.skip_shorts` read (default from settings). Tests drive each branch with a patched downloader/classifier. Commit: `feat(pipeline): route shorts/live/restricted YouTube videos`

## Task 2.5 — Re-probe deferred on the daily check  `[serialize: worker_thread.py]`

**Files:** Modify `ui/worker_thread.py` (include `DEFERRED` in the per-check re-classification pass). Test `tests/test_worker_thread_youtube.py`.

**Detail:** on each scheduled check, re-classify `deferred` episodes; a now-finished premiere becomes `pending`. Bounded (only on the daily check). Commit: `feat(worker): re-probe deferred YouTube videos on the daily check`

**Phase 2 gate:** full suite + ruff. Dispatch 2.1/2.2/2.3 parallel; 2.4 after 2.1+2.3; 2.5 after 2.4.

---

# Phase 3 — CLI parity (WS5)  `[serialize: cli.py]`

## Task 3.1 — `add` uses the enumerator + flags
Modify `cli.py:cmd_add` (youtube branch enumerates via WS2 honouring `--backlog last:N|since:DATE|all`; add `--captions/--whisper`, `--skip-shorts/--include-shorts`). Tests in `tests/test_cli_add_youtube.py` (mock the enumerator; assert depth + flags map to model fields). Commit: `feat(cli): deep YouTube backfill + transcript/shorts flags on add`

## Task 3.2 — `cli.py backlog <slug> --backlog …`
Add subcommand to seed+queue older videos for an existing show via WS2. Test `tests/test_cli_backlog.py`. Commit: `feat(cli): backlog command to fetch more history headlessly`

**Phase 3 gate:** full suite + ruff.

---

# Phase 4 — Per-show window / episode browser (WS10, absorbs WS6)

Largest phase; mostly `ui/show_details_dialog.py` (or a new `ui/show_window.py`). Tasks are mostly serial (same file) but each is independently testable. Use one sub-agent in a worktree, code-reviewed per task.

## Task 4.1 — Make the dialog resizable + show all episodes
Drop `LIMIT 10` → all episodes (ordered, paged/batched); make the window resizable/maximizable; keep header/form/feed-health/Advanced. Test: > 10 rows render. Commit: `feat(show-window): full resizable episode list`

## Task 4.2 — Multi-select + per-row actions intact
Switch table to `ExtendedSelection`; keep Run-next/Run-now/Re-transcribe/Open. Test selection model. Commit: `feat(show-window): multi-select episode table`

## Task 4.3 — Bulk toolbar: "Queue selected"
Toolbar button → set selected guids `pending` + priority bump (reuse `ui/prioritize.py`/`retranscribe`). Test queues the right guids. Commit: `feat(show-window): queue selected episodes`

## Task 4.4 — "Queue all since <date>"
Date picker + button selecting episodes with `pub_date >= date`, then queue. Test the selection set. Commit: `feat(show-window): queue all episodes since a date`

## Task 4.5 — Status filter row
Filter the list by status (pending/failed/skipped/deferred/done). Test filtering. Commit: `feat(show-window): filter episodes by status`

## Task 4.6 — YouTube settings edit in the form (absorbed WS6)
For youtube shows, expose editable language / caption-pref / skip-Shorts in the settings form; persist via `save_watchlist`. Test round-trip. Commit: `feat(show-window): edit YouTube show settings`

## Task 4.7 — Paced background back-catalogue streaming
On open, show DB rows instantly; start the WS2 streaming enumerator off-thread, append older videos in throttled batches (cancel on close, cap + "load more"); unseeded rows render "available" and triggering seeds+queues them. Test: patched streaming enumerator appends rows; cancel stops it; triggering an unseeded row seeds+queues. Commit: `feat(show-window): paced background channel-history streaming`

**Phase 4 gate:** full suite + ruff; manual smoke via the isolated demo launcher.

---

# Phase 5 — Polish (WS7)

## Task 5.1 — Channel avatar with fallback chain  `[parallel-group: P5]`
`core/youtube_meta.fetch_channel_preview` (and/or resolve) returns an avatar via og:image → yt-dlp thumb → latest-video frame → "". Test the fallback order with mocked sources. Commit: `feat(youtube): channel avatar with fallback chain`

## Task 5.2 — Expanded language picker  `[serialize: add_show_dialog.py]`
Curated language list + `auto` in the dialog + `Settings.youtube_default_language`; strict-caption rule for `auto` (accept channel default manual track else whisper) wired in the pipeline. Tests for the list + the `auto` rule. Commit: `feat(youtube): broaden language options + auto strict-caption rule`

**Phase 5 gate:** full suite + ruff.

---

# Phase 6 — Docs, defaults & cleanup (WS9)  `[parallel-group: P6]`

## Task 6.1 — Global settings defaults
`Settings`: `youtube_skip_shorts_default`, strict-captions default, expanded language default. Migration-safe. Test round-trip. Commit: `feat(settings): global defaults for YouTube shorts/captions/language`

## Task 6.2 — Remove dead `auto-captions`
Drop `auto-captions` from settable values (`cli.py` `_SHOW_SETTABLE`, settings, prompt, dialog); tolerate legacy reads. Test `set … auto-captions` is rejected. Commit: `chore(youtube): remove the dead auto-captions option`

## Task 6.3 — Docs
README, AGENTS.md, settings help + example prompt, CHANGELOG (curated) — episode browser, Shorts, languages, new CLI flags + `backlog`. Update `tests/test_agents_doc.py` expectations if needed. Commit: `docs: YouTube hardening + episode browser`

**Phase 6 gate:** full suite + ruff + `git` clean.

---

## Final acceptance

- `.venv/bin/python -m pytest -q` green (run twice — guard the known QThread races).
- `ruff check . && ruff format --check .` clean.
- Manual smoke through the isolated demo launcher: add via `/c/` URL, paste a video → channel offer, dedup rejection, episode browser bulk + since-date, a deferred/live row, a skipped Short.
- Curated CHANGELOG entry under `Unreleased`.
