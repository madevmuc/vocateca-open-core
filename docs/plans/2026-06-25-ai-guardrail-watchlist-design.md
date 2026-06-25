# AI-operator guardrail for watchlist edits & backlog — Design

**Datum:** 2026-06-25
**Status:** Approved, ready for implementation plan

## Problem

On 2026-06-25 the user added three podcasts by having an AI edit
`watchlist.yaml` directly while Paragraphos (PID 902) was running. Two
distinct failures surfaced — both are systemic, not one-off:

1. **In-memory clobber.** `AppContext.load()` (`ui/app_context.py:67`) reads
   `watchlist.yaml` **once at startup** into `ctx.watchlist`. There is no
   file-watcher on it (`start_watching` watches the transcript output dir,
   not the watchlist). Every tab reads the in-memory object. So an external
   edit is (a) invisible to the running UI, and (b) silently overwritten the
   next time any in-app action calls `ctx.watchlist.save()` (toggle/edit a
   show, feed-redirect during a check at `ui/worker_thread.py:623`, OPML
   import, …).

2. **Silent full-archive backfill.** The "history vs. future" choice
   (backlog: All / Most recent / Last N, default "Last 5") lives **only** in
   the GUI Add-show dialog (`ui/add_show_dialog.py:1353`), which seeds
   `state.sqlite` and marks the back-catalog `done`. Neither a raw YAML edit
   **nor** `cli.py add` (`cli.py:120`) applies any backlog strategy — both
   upsert every feed episode as `pending` (`core/state.py:139`). The next
   check then transcribes the **entire archive**. For the three shows added,
   that was 531 episodes (45 / 242 / 244) — many hours of whisper time, with
   no prompt.

3. **No discoverability.** There is no `AGENTS.md` / operator doc, so an AI
   has no signpost telling it the right way to add a show.

## Goal

Make both pitfalls **automatically apparent** to an AI (or human) operating
Paragraphos, via **defense-in-depth**: a blessed CLI path that forces the
backlog choice, an app-side guard that detects external edits and prevents
the clobber + the silent backfill, and an operator doc. Decisions below are
from the brainstorming session.

## Brainstorming decisions

- **Strategy:** Defense-in-depth — blessed CLI **and** app-side guard **and** docs.
- **App reconcile:** Gate + ask (hold a newly-detected undecided show's
  episodes back; surface a banner) — *with* a 24h auto-accept default of
  **full history**, and the gate must be **per-show** so the daily check +
  transcription of all other shows keeps running.
- **CLI backlog:** **Mandatory** `--backlog` flag, no default (hard-fail if omitted).
- **Detection:** Both watchdog (near-instant) **and** a content-hash/mtime
  checkpoint poll (hard guarantee), sharing one content-hash baseline.

## The spine — two meta keys

A single durable concept drives everything, stored in the existing `meta`
table of `state.sqlite` (same pattern as `show_paused:<slug>`):

- `backlog_decided:<slug> = "1"` — a backlog choice has been made by *some*
  blessed path. A show **without** this marker is "undecided" → gated +
  surfaced.
- `backlog_detected_at:<slug> = <ISO8601 UTC>` — when the show was first seen
  undecided. Drives the 24h auto-accept.

Set by: GUI Add dialog, CLI `add`, the Reconcile dialog, the 24h auto-accept,
and the one-time grandfather migration.
Checked by: the worker fetch loop (gate) and the reconcile detector (prompt).

**Grandfathering:** On first launch of this version, mark **all shows already
in `watchlist.yaml`** as `backlog_decided=1` (guarded by meta
`backlog_grandfathered=1`; same idea as `backfill_setup_completed`). The
user's current 3 shows (531 pending, full archive deliberately chosen) keep
running untouched.

## Layer 1 — CLI (`paragraphos add`)

Non-interactive, the blessed AI path:

```
paragraphos add <name|rss-url|youtube-url> \
    --backlog <all|recent|last:N|since:YYYY-MM-DD> \
    [--slug X] [--lang de] [--yes]
```

- `--backlog` is **required**. Omitting it exits non-zero with a plaintext
  message listing the options. A silent backfill is impossible on this path.
- Steps, atomic: resolve feed → write `watchlist.yaml` atomically (temp +
  `os.replace`) → seed episodes → apply backlog (mark back-catalog `done` for
  `recent`/`last:N`/`since`) → **set `backlog_decided=1`**. A CLI-added show
  therefore never trips the app banner.
- If the app is running: no conflict — the app-guard sees the hash change and
  reloads (no clobber). `add` prints "App is running — change will hot-reload."
- The existing interactive `cmd_add` stays as the human path (refactored to
  call the same core). `remove`/`enable`/`disable` become clobber-safe for
  free via the app reload + save-side gate (Layer 2).

## Layer 2 — App-guard

**Detection (shared baseline):**
- After *every* in-app `watchlist.save()`, record `sha256` of the file bytes
  in `ctx._watchlist_hash` — the "that-was-me" baseline.
- **watchdog Observer** on the data dir (alongside the existing library
  observer): on change to `watchlist.yaml`, compare file hash vs.
  `ctx._watchlist_hash`. Equal → own save, ignore. Different → external edit
  → reconcile.
- **Checkpoint poll** backstop: on window focus-in, the existing timer tick,
  and **hard inside `_run_check()` before any feed is fetched**. Same hash
  check. If the watcher missed an event (fsevents coalescing) or its thread
  died, the pre-run checkpoint still catches it → **never a run with a stale
  watchlist.**

**Save-side gate (closes the last clobber race):** Route *every* in-app
`watchlist.save()` through a helper that, **before writing**, compares the
on-disk hash to the baseline. If an un-reconciled external edit exists →
reload/merge first, **then** write. This shuts the tight race where a save
fires before the watcher reload — the actual root cause, hard-closed.

**Reconcile (on detected external edit):**
1. `Watchlist.load()` into `ctx.watchlist` (no clobber — the app now knows the
   new state). Parse failure (half-written file) → log, do **not** crash, do
   **not** save, retry at next checkpoint.
2. Diff slugs. For each new show **without** `backlog_decided`: stamp
   `backlog_detected_at` (if unset) and leave it gated.
3. Duplicate-slug detection on reload → banner warning (the "no slug dupes"
   check from the incident) instead of silent corruption.

**Gate (per-show, never a global stop):** In the worker fetch loop (next to
the existing `show_paused` skip at `ui/worker_thread.py:561`): if a show is
not grandfathered and lacks `backlog_decided` → `skip <slug> (backlog
undecided)`. Only that show is held; **all decided shows are checked and
transcribed normally** — the app's daily function is never blocked. The
marker lives in `state.sqlite`, so the gate survives crash/restart.

**24h auto-accept (default = full history):** At each checkpoint (daily tick,
reconcile, startup) any undecided show whose `backlog_detected_at` is older
than 24h is auto-decided: set `backlog_decided=1`, leave **all episodes
pending (full archive)**, drop the gate → the next daily check ingests it.
The auto-accept path is trivial (set a flag); no special seeding. If the app
is closed >24h, it fires on the next startup reconcile.

**UX — banner, not a blocking modal:** A non-blocking banner in the Shows tab
("1 new show detected — choose backlog (default in 24h: full history)"), same
pattern as the existing knowledge-hub / connectivity banners, plus an
optional tray notification. Click opens the **Reconcile dialog**: per show, a
backlog choice **pre-selected to "full history"** (consistent with the 24h
default). Choosing `last:N`/`recent` fetches the manifest and marks the
back-catalog `done` (reusing the GUI Add-dialog logic), sets the marker, and
ungates. Ignoring the banner is safe — the gate holds until the 24h default.

**Deliberate implication:** an ignored banner ⇒ full archive after 24h. The
*hard* enforcement stays on the AI/CLI path (`--backlog` required, no
default); the app banner is the human-friendly safety net with an autonomous
default, because the app is meant to keep running unattended.

## Layer 3 — `AGENTS.md` (repo root)

A short, prominent block — this is the "automatically apparent" piece:

> **Adding shows: always `paragraphos add … --backlog …` — never edit
> `watchlist.yaml` directly.** Why: (1) the running app holds the watchlist
> in memory and overwrites raw edits; (2) without `--backlog` the entire
> archive would be transcribed. Use `paragraphos status` to verify.

## Error handling & edge cases

- Atomic CLI write (`temp + os.replace`) → the app never reads a half file.
- Half-written YAML on reload → guarded parse; log, no crash, no save, retry.
- Externally-removed show → reload drops it; orphan episodes in `state.sqlite`
  remain (harmless).
- Grandfather migration runs exactly once (`backlog_grandfathered=1`).
- App offline >24h → auto-accept fires at next startup reconcile.

## Testing (TDD — failing test first for each)

- **Incident repro:** raw YAML edit against a stale in-memory state → assert
  **no clobber** (save-side gate reloads first) + show **gated** + after 24h
  auto-accept → full archive.
- **CLI:** `add` without `--backlog` → exit ≠ 0; each mode (`all` / `recent` /
  `last:N` / `since`) yields the right pending count + sets the marker; atomic
  write.
- **Worker gate:** an undecided show is skipped while **other shows keep
  running** (non-blocking).
- **Guard:** external edit → reload (hash differs); own save → no reconcile
  (hash equal); 24h auto-accept (time injected).
- **Reconcile dialog:** applies backlog, sets marker, ungates.
- **Grandfather:** runs once, marks existing shows decided.

## Out of scope (YAGNI)

- No general two-way live sync of arbitrary watchlist fields — only add /
  reload / clobber-safety / backlog gating.
- No new IPC/signal channel (content-hash detection covers both vectors).
- No rework of `remove`/`enable`/`disable` beyond the free clobber-safety they
  inherit from the save-side gate.
- Deletion tombstones — the save-side union-merge can resurrect an in-app delete if the same slug was externally re-added since the baseline. Acceptable under single-writer use; revisit with the reconcile work if it ever bites.
