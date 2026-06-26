# Paragraphos

**Local podcast + YouTube → `whisper.cpp` transcription pipeline for macOS.**

Paragraphos runs entirely on your Mac — no cloud APIs, no telemetry, no
account. Point it at a podcast name, RSS URL, or YouTube channel, it finds
the feed, downloads episodes, transcribes them with the OpenAI Whisper
(`large-v3-turbo`) model via
[`whisper.cpp`](https://github.com/ggerganov/whisper.cpp), and deposits
Markdown + SRT files into a folder of your choice. YouTube tries the
uploader's captions first (requested language → English → any available)
and falls back to whisper when no usable captions exist.

It's built for building a searchable personal knowledge base from long-form
audio — a podcast archive you can grep, link between, and feed into an LLM
later.

> The name **Paragraphos** comes from the ancient Greek punctuation mark
> that signalled a change of speaker in a text — the job Paragraphos does
> for every episode it transcribes.

![Status](https://img.shields.io/badge/status-v1.4.0-green)
![Platform](https://img.shields.io/badge/platform-macOS_Apple_Silicon-lightgrey)
![Python](https://img.shields.io/badge/python-3.12-blue)
![Tests](https://img.shields.io/badge/tests-472_passing-success)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## What it does

- 🎧 **Finds podcast feeds** from a name (via iTunes Search) or a URL
  (RSS auto-detect from `<link rel="alternate">`).
- 📺 **Adds YouTube channels** by any URL form — `/channel/UC…`, `/@handle`,
  `/c/Name`, `/user/Name`, or a bare `@handle`; paste a single video URL and
  it offers to add the channel that posted it. The same channel can't be added
  twice. Shorts are excluded by default; live / premiere videos are deferred
  and re-tried once they finish. `yt-dlp` lazy-installs on first use and
  self-updates weekly.
- 📥 **Ingests any file or URL** — the dedicated **Local Transcript**
  tab has a big drop zone for audio / video files (`.mp3` / `.m4a` /
  `.wav` / `.mp4` / `.mov` / `.mkv` / `.webm` / …), a folder-import
  button for one-shot bulk scans, and a URL field that routes through
  yt-dlp's generic extractor (SoundCloud, Vimeo, any site it
  recognises). A watched folder at `~/Paragraphos/to-be-transcribed/`
  auto-queues new drops; a drop anywhere on the main window navigates
  to Local Transcript and ingests there.
- 🗒 **Captions-first for YouTube** — a manual uploader subtitle in the
  chosen language is imported straight into the library (auto-generated
  captions are never used), with whisper as the fallback. The **Auto**
  language accepts the channel's default manual track, else whisper.
- ⬇ **Downloads new episodes** resumably, with retry + backoff on transient
  failures.
- 📝 **Transcribes locally** with `whisper.cpp` (`large-v3-turbo`),
  with throughput governed by a single **background-load level**
  (`load_level`: quiet / balanced / full — drives worker count, whisper
  threads, and process QoS). Your audio never leaves the machine.
- 📅 **Monitors daily** at a time you choose. Catches up automatically
  after sleep + offline; downloaded items keep transcribing while
  feed-fetch is offline.
- 🗂 **Dedupes** against your existing transcript library so dropping in
  old files doesn't re-transcribe.
- 🩺 **Diagnoses feed failures** — every failed feed is bucketed (DNS /
  TLS / 404-gone / 5xx server / NAT64 SSRF / etc.) and surfaced with a
  per-category recommendation + one-click Retry-now in the Show details
  dialog.
- 🛡 **Hardened inputs** — SSRF guards on every URL (incl. NAT64
  unwrap), size caps on every download, XXE-safe XML, path-traversal
  checks, TOFU SHA-256 on model files.
- 🔎 **Observable** — startup fingerprint with versions + tunables,
  full-context error messages with humanised exit codes (`exit -9
  (killed (SIGKILL — Stop button))`), live queue ETA, rotating log
  files, macOS notifications.
- 🤖 **Headless / LLM-controllable** — a full-parity CLI with `--json`
  inspection (`status`, `episodes`, `failed`, `feed-health`, `set`,
  `priority`, `retranscribe`, `retry-failed`, …) so an agent can drive
  the whole app without touching the GUI. See **CLI** below.

## Screenshots

**Shows — watchlist overview**
![Shows tab](docs/screenshots/shows-tab.png)

**Local Transcript — drag-drop, folder-pick, or URL**
Top-level tab between Shows and Queue. Three zones: a big drop area for
audio/video files, a **Choose folder to import…** button for bulk
scans, and a URL field for anything yt-dlp recognises. Inline status
line confirms each ingest.
![Local Transcript](docs/screenshots/local-transcript.png)

**Add show — search-as-you-type**
Name-mode search fires 350 ms after the last keystroke; rich results
table shows cover, title, author, episode count, and latest date.
Single-click a row to pre-fill RSS / Title / Slug; double-click to
kick off the full metadata fetch + whisper prompt generation.
![Add show — name search](docs/screenshots/add-show-search.png)

**Queue — live transcribe dashboard**
Hero with progress ring, per-row Audio / Whisper / Finish columns, status
cell shows live `transcribing · X%` on the active row.
![Queue tab](docs/screenshots/queue-tab.png)

**Show details — artwork, feed refresh, recent episodes**
![Show details](docs/screenshots/show-details.png)

**Settings — Local sources group (watch folder + duration cap)**
Enable the watch folder, pick a root (top-level subfolders become show
slugs), choose keep / move / delete after transcribing, and cap the
per-file duration so an accidentally-dropped movie doesn't monopolise
whisper for an afternoon.
![Settings — Local sources](docs/screenshots/settings-local-sources.png)

**Settings — hardware-aware recommendations**
Inline hints (`✓ recommended: N (16 GB RAM, 8 perf cores detected)`),
auto-detected on macOS via `sysctl`. Full dark-mode polish.
![Settings](docs/screenshots/settings.png)

## Installation

### Prerequisites

- macOS 14+ (Apple Silicon; Intel universal build is on the roadmap)
- ~2 GB free disk space for the Whisper model
- [Homebrew](https://brew.sh) (the first-run wizard will install
  `whisper-cpp` and `ffmpeg` for you)

### Option A — Download the `.app`

1. Grab the latest `Paragraphos-x.y.z.dmg` from the
   [Releases page](../../releases).
2. Open the `.dmg`, drag `Paragraphos.app` into `/Applications`.
3. **First launch — three clicks through Gatekeeper** (see below).
4. The first-run wizard handles the rest (Homebrew + `whisper-cpp` +
   `ffmpeg` + ~1.5 GB model download).

#### First launch on macOS — opening an unsigned build

Paragraphos isn't notarised by Apple (no developer account). On macOS
Sequoia (15) and later, the old right-click → **Open** trick no longer
works — you have to go through System Settings once. Three clicks,
then it's launchable normally forever.

**Step 1.** Double-click `Paragraphos.app` in `/Applications`. macOS
shows this dialog. Click **Done** (do **not** click Move to Bin).

<img src="docs/screenshots/gatekeeper-1-blocked.png" alt="Gatekeeper block dialog" width="320">

**Step 2.** Open **System Settings → Privacy & Security**, scroll
down to **Security**. You'll see *"Paragraphos.app" was blocked to
protect your Mac.* Click **Open Anyway**.

<img src="docs/screenshots/gatekeeper-2-settings.jpeg" alt="Privacy & Security — Open Anyway" width="640">

**Step 3.** macOS asks one more time, with **Open Anyway** as an
explicit choice. Click it (you may be prompted for your password /
Touch ID).

<img src="docs/screenshots/gatekeeper-3-confirm.png" alt="Final Open Anyway confirmation" width="320">

That's it — the app launches and from then on opens normally from
the Dock / Spotlight / Launchpad without any prompts. macOS remembers
your decision per-app.

> **Why the song and dance?** Apple charges $99/yr for a Developer
> account to notarise apps. Paragraphos is a personal-tools project
> with no commercial revenue, so it ships unsigned. The Gatekeeper
> warning is macOS's standard "I haven't seen this developer before"
> screen — it doesn't mean the app is unsafe, just unverified by
> Apple's notarisation service. The full source is in this repo if
> you'd rather build it yourself (see Option B).

### Option B — Build from source

```bash
git clone https://github.com/madevmuc/paragraphos.git
cd paragraphos

python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt -r dev-requirements.txt

# Run from source (live-reload dev mode):
PYTHONPATH=. .venv/bin/python app.py

# Or build a standalone .app bundle:
.venv/bin/python setup-full.py py2app
open dist/Paragraphos.app
```

## Quick start

1. Launch the app. A 🎙 icon appears in the menu bar and the main window
   opens.
2. **Add Podcast / Show** — search by name (iTunes), paste an RSS URL, or
   paste a YouTube channel / handle URL (`yt-dlp` lazy-installs on first
   YouTube use).
3. Choose your **backlog** mode: all episodes / only new / last 20 / last 50.
4. Paragraphos downloads + transcribes in the background. Watch the Queue
   tab for live ETA. At a higher `load_level` (balanced / full) multiple
   episodes transcribe at once.
5. Completed transcripts land as `.md` + `.srt` files under the
   `Output root` you configured (Settings tab).

## CLI

Full GUI parity for headless / agent control. From `~/dev/paragraphos`:

```bash
PYTHONPATH=. .venv/bin/python cli.py <command> [args]
```

Most inspection commands accept `--json` for machine-readable output, so
an LLM agent can pipe through `jq`. The CLI shares state with the GUI
via SQLite WAL — mutations show up live in a running window.

| Group         | Commands                                                                                |
|---------------|-----------------------------------------------------------------------------------------|
| Inspection    | `status`, `shows`, `show <slug>`, `episodes <slug>`, `failed`, `settings`, `feed-health` |
| Queue control | `pause`, `resume`, `stop`, `clear-queue`, `priority <guid> <N>`, `run-next <guid>`, `retranscribe <guid>`, `retry-failed` |
| Show admin    | `add <name-or-url> --backlog <all\|recent\|last:N\|since:YYYY-MM-DD> [--yes]` (backlog **required**; never edit `watchlist.yaml` directly; YouTube adds accept `--captions`/`--whisper` + `--skip-shorts`/`--include-shorts`), `backlog <slug> --backlog …` (deepen a YouTube show's history + queue it), `enable <slug>`, `disable <slug>`, `remove <slug>`, `set <slug> key=value`, `import-feeds` |
| Local ingest  | `ingest file <path> [--show SLUG]`, `ingest url <url> [--show SLUG]`, `ingest folder <path> [--show SLUG] [--no-recursive]`, `watch add <path>`, `watch remove`, `watch list [--json]` |
| Feed retry    | `retry-feed <slug>`, `retry-all-feeds`                                                  |
| Settings      | `set-setting <key> <value>`                                                             |
| Pipeline      | `check [--show <slug>] [--limit N]`                                                     |

Example agent task chain:

```bash
# Find feed-health=fail shows, retry them, then re-queue the last 24 h
# of network-failed episodes:
cli.py feed-health --json | jq -r '.[] | select(.feed_health=="fail").slug'
cli.py retry-all-feeds
cli.py retry-failed --window-hours 24
cli.py status --json
```

The full agent prompt lives in **Settings → Automation & remote control**
inside the app — paste it into your agent's system prompt to give it
domain knowledge of every command + flag.

## Architecture at a glance

```
       ┌───────────────────────────────────────────────────────┐
       │                  Paragraphos.app (PyQt6)              │
       │                                                       │
 tray  ├──► MainWindow (Shows / Local Transcript / Queue /    │
       │              Failed / Library / Settings)             │
 icon  │         │                                             │
       │         └─► CheckAllThread (QThread)                  │
       │                │                                      │
       │                ├─► build_manifest()  ──► RSS feeds    │
       │                ├─► download_mp3()     ──► podcast CDN │
       │                └─► transcribe_episode ──► whisper.cpp │
       │                                             (Metal)   │
       │                        │                              │
       │                        └─► .md + .srt ──► output root │
       │                                                       │
       │  State: SQLite (~/Library/Application Support/        │
       │         Paragraphos/state.sqlite)                     │
       │  Config: watchlist.yaml + settings.yaml in the same   │
       │          directory                                    │
       │  Daily trigger: APScheduler cron, with catch-up on    │
       │                 app startup                           │
       └───────────────────────────────────────────────────────┘
```

Full module walk-through: `docs/ROADMAP.md` (Phase 5.23).

## Privacy & security

- **Nothing leaves the machine** for transcription. `whisper.cpp` runs
  local; no OpenAI API key is involved.
- **SSRF guards** reject `file://`, `data:`, `javascript:`, and
  private-range IPs (RFC1918, loopback, link-local, multicast) on every
  URL the app fetches.
- **Size caps** abort runaway streams (MP3 ≤ 2 GB, RSS ≤ 50 MB,
  HTML ≤ 10 MB).
- **Path-traversal defence** at two layers (sanitiser + `safe_path_within`
  before every write).
- **Model integrity** pinned via TOFU SHA-256; mismatch raises loudly.
- **No shell execution** — all subprocess calls use list-form arguments.
- **Content-Type sniff** rejects non-audio blobs delivered as `.mp3`.
- **XXE-safe OPML parsing** via `defusedxml`.

See `About Paragraphos → Security` in the app for the full threat model.

## Usage

### GUI workflows

- **Add Podcast** dialog supports four modes: *By name* (iTunes
  search; search-as-you-type with 350 ms debounce, single-click a row
  to pre-fill RSS/Title/Slug, double-click to run the full metadata
  fetch + whisper-prompt suggestion), *By URL* (RSS with rich preview),
  *Paste Apple link* (one-step auto-detect), and **YouTube URL**
  (any channel-URL form, a bare `@handle`, or a video URL — it offers
  the posting channel — with a backfill segmented control, a curated
  language picker incl. **Auto**, and an Include-Shorts toggle). The
  YouTube mode appears only when *Settings → Sources → YouTube* is
  enabled.
- **Per-show episode browser** — double-click any show to open a
  resizable window listing every episode with status pills. Multi-select
  + **Queue selected**, a date picker + **Queue all since <date>**, and a
  status filter (pending / failed / skipped / deferred / done). YouTube
  shows stream their whole back-catalogue in the background; not-yet-fetched
  videos show as **available** rows you can trigger to seed + queue (with
  **Load more**). YouTube language / caption preference / skip-Shorts are
  editable from the same window.
- **Local Transcript tab** — dedicated top-level tab for one-off
  ingest. Drop audio/video on the big panel, pick a folder to bulk-
  scan, or paste a URL. Every ingest emits an inline status line; the
  episode appears in the Queue within a few seconds. The **Local
  sources** group in Settings exposes the watch-folder root, the
  after-transcribing action (keep / move / delete), and the max-
  duration cap.
- **Sources** in Settings: independent toggles for Podcasts (RSS) and
  YouTube channels. At least one must stay on. Disabling YouTube
  hides the YouTube UI and skips the lazy yt-dlp install.
- **Queue tab** shows live progress: `3/12 · started 09:14 · elapsed
  18m 02s · ETA 52m · finish ≈ 10:24 (before lunch)`.
- **Failed tab** lists every failure with humanised reason + retry /
  mark-resolved / clear-old-than-30-days buttons.
- **Settings** are auto-saved on every change; inline hints explain
  each field. The "Re-run setup guide" button at the bottom re-opens
  the guided onboarding (same as Help → Re-run setup guide).
- **OPML drag-and-drop**: drop an `.opml` file on the Dock icon to bulk
  import podcast subscriptions.

### Headless CLI

Paragraphos ships a headless CLI for automation. v1.2.0+ accepts both
RSS and YouTube channel URLs through the same `add` command.

```bash
cd ~/dev/paragraphos
export PYTHONPATH=.

# Podcasts — --backlog is REQUIRED (how much history to transcribe);
# --yes makes it non-interactive (takes the first iTunes match).
.venv/bin/python cli.py add "Odd Lots" --backlog last:5 --yes      # by name (iTunes)
.venv/bin/python cli.py add https://feeds.acast.com/public/shows/… --backlog all

# YouTube channels (yt-dlp auto-installs to
# ~/Library/Application Support/Paragraphos/bin/yt-dlp on first use).
# --backlog drives a DEEP channel backfill, not just the RSS window.
# Any URL form works: /channel/UC…, /@handle, /c/Name, /user/Name, @handle.
.venv/bin/python cli.py add https://www.youtube.com/@TED --backlog last:10
.venv/bin/python cli.py add @veritasium --backlog all --include-shorts --whisper

# Deepen an existing YouTube show's history and queue the new videos:
.venv/bin/python cli.py backlog ted --backlog since:2024-01-01

.venv/bin/python cli.py list                    # source col: podcast | youtube
.venv/bin/python cli.py check --show odd-lots --limit 5
.venv/bin/python cli.py import-feeds            # seed from built-in list
```

YouTube transcripts go through **captions-first** by default — a manual
uploader subtitle in the chosen language is converted (VTT → SRT) and moved
straight into the library; whisper takes over when no manual caption exists.
Auto-generated captions are never used. Override per channel via the episode
browser (*Captions / Always whisper*) or globally via
`youtube_default_transcript_source` in `settings.yaml`; Shorts are skipped by
default (`youtube_skip_shorts_default`) and the default language comes from
`youtube_default_language`.

The Settings pane ships a ready-to-paste **agent prompt** you can give
to Claude Code / Gemini CLI / any coding agent with shell access. The
prompt now includes YouTube-specific examples like "switch all YouTube
shows to always-whisper mode" and "list every YouTube episode that
fell back to whisper".

## Development

### Run tests

```bash
cd ~/dev/paragraphos
PYTHONPATH=. .venv/bin/pytest -q
```

### Run the app from source

```bash
PYTHONPATH=. .venv/bin/python app.py
```

Changes to Python source take effect on next launch. No rebuild of the
`.app` required during dev (the alias-mode bundle references this
source tree).

### Rebuild the `.app` bundle

```bash
# Dev (alias-mode, ~3 MB, fast rebuild):
.venv/bin/python setup.py py2app -A

# Distribution (standalone, ~310 MB):
.venv/bin/python setup-full.py py2app
```

### Project layout

```
paragraphos/
├── app.py                  # Qt entry point + tray + scheduler
├── cli.py                  # Headless CLI
├── core/                   # Domain logic — no Qt imports here
│   ├── rss.py              # feed parsing, build_manifest
│   ├── downloader.py       # resumable MP3 fetch with retry
│   ├── transcriber.py      # whisper.cpp subprocess wrapper
│   ├── pipeline.py         # ties download → transcribe → save
│   ├── state.py            # SQLite store
│   ├── models.py           # Pydantic Watchlist + Settings
│   ├── library.py          # existing-transcript index (watchdog)
│   ├── security.py         # URL guards, path guards, SHA-256 TOFU
│   ├── backoff.py          # per-feed failure backoff
│   ├── stats.py            # global + per-show statistics
│   ├── paths.py            # ~/Library/Application Support/Paragraphos
│   ├── deps.py             # whisper-cpp / ffmpeg / model presence checks
│   ├── model_download.py   # Hugging Face model fetch
│   ├── scrape.py           # episode landing-page scraping
│   ├── opml.py             # OPML import (defusedxml)
│   ├── export.py           # show → ZIP
│   ├── scheduler.py        # APScheduler daily cron
│   ├── logger.py           # rotating file logger
│   ├── workers.py          # WorkerPool wrapper
│   └── prompt_gen.py       # whisper_prompt auto-suggestion
├── ui/                     # Qt widgets — everything visible
├── tests/                  # pytest suite (429 tests)
├── docs/
│   ├── ROADMAP.md          # v0.5→v1.0 plan, 6 phases
│   └── design-handoff/     # mockups for the Phase 6 design refresh
├── data/
│   └── default_prompts.yaml  # seed prompts for 16 real-estate feeds
├── setup.py                # dev alias build
├── setup-full.py           # standalone distribution build
├── requirements.txt
└── dev-requirements.txt
```

## Roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full plan. TL;DR:

| Phase | Version | Focus | Status |
|---|---|---|---|
| 0 | — | Repo extraction from knowledge-hub | ✅ done |
| 1 | v0.5.0 | Reliability (timeout, retry, TOFU, redirect, prompt-coverage) | ✅ done |
| 1.5 | v0.5.1 | Performance (HTTP/2, concurrent RSS, ETag, WAL, `-p N`) | planned |
| 2 | v0.6.0 | Parallel download+transcribe, play-preview, per-show pause | planned |
| 3 | v0.6.x | Search/sort, re-transcribe single, bulk select, daily summary, diff | planned |
| 4 | v1.0 rc | Auto-update (GitHub Releases), DMG, universal2 | planned |
| 5 | v1.0 | Integration tests, pre-commit, CI, architecture diagram | planned |
| 6 | v0.7 | Full UI refresh per `docs/design-handoff/` | planned |

**Not planned** (out of scope): Ollama summarisation, SQLite FTS5
full-text search, Apple Developer code-signing / notarisation.

## Contributing

Contributions welcome, but please:

- **No new runtime dependencies** without a clear justification.
- **TDD** for every behaviour change — new failing test first, then the
  fix.
- **Preserve the privacy guarantee** — nothing in `core/` may make
  outbound network calls to third parties beyond the RSS / MP3 /
  Hugging Face hosts already used.

Open an issue before starting anything large so we can agree on the
approach.

## License

[MIT](LICENSE). See the full text in `LICENSE`.

Paragraphos bundles / depends on these projects, whose licenses are
credited in the in-app `About → Credits & Licenses` dialog:

Python (PSF-2.0), PyQt6 (GPL-3.0 / Riverbank Commercial), `whisper.cpp`
(MIT), OpenAI Whisper model weights (MIT), APScheduler (MIT), watchdog
(Apache-2.0), feedparser (BSD-2), httpx (BSD-3), pydantic (MIT),
beautifulsoup4 (MIT), lxml (BSD-3), PyYAML (MIT), ffmpeg (LGPL-2.1/GPL),
Homebrew (BSD-2), defusedxml (PSF-2.0), yt-dlp (Unlicense / public
domain — lazy-installed at runtime, not bundled in the .app).

For a fuller breakdown including transitive deps and distribution
notes, see [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Acknowledgements

- Built by [Matthias Maier](https://github.com/mm) for a personal
  real-estate-podcast knowledge base.
- Transcription quality entirely thanks to
  [ggerganov/whisper.cpp](https://github.com/ggerganov/whisper.cpp) and
  the OpenAI Whisper team.
- Inspired by the Karpathy "LLM Wiki" pattern — a knowledge base
  compiled once by an LLM from raw sources.
