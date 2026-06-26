# Paragraphos Changelog

## Unreleased — YouTube hardening + per-show episode browser

The original "Add YouTube Channel" feature, hardened against the channels
people actually paste, and paired with a full per-show episode browser.

### Added
- **Add a channel by any URL form.** `/channel/UC…`, `/@handle`, `/c/Name`,
  `/user/Name`, and a bare `@handle` all resolve to the right channel. Paste a
  single **video** URL and Paragraphos offers to add the channel that posted
  it instead of rejecting it. Adding the **same channel twice** — even under a
  different slug or a different URL form — is refused, naming the show it
  already lives under. The Shows tab keeps its dedicated **"Add YouTube
  Channel…"** button: paste the link, the channel name + avatar + video count
  resolve, the slug pre-fills (editable), and you pick how much history to
  pull (only-new / last 5·20·100 / since a date).
- **Per-show episode browser** — double-click a show to open a resizable,
  maximizable window. It keeps everything Show Details had (artwork, settings,
  feed health) and lists **every** episode with status pills, plus:
  **multi-select** + **Queue selected**, a date picker + **Queue all since
  <date>**, and a **status filter** (pending / failed / skipped / deferred /
  done). YouTube shows stream their **entire back-catalogue** in paced
  background batches — not-yet-fetched videos appear as **"available"** rows
  you can trigger to seed + queue (capped, with **Load more**). YouTube
  language / caption preference / skip-Shorts are editable inline.
- **Expanded language picker** in the Add dialog — a curated list plus a new
  **Auto** option, seeded from the `youtube_default_language` setting.
- **Channel avatar** is now shown (og:image → yt-dlp thumbnail →
  latest-video-frame fallback) instead of a generic placeholder.
- **`cli.py backlog <slug> --backlog …`** deepens an existing YouTube show's
  history beyond the RSS window and queues the newly fetched videos.

### Changed
- **Shorts, live, and restricted videos are handled deliberately, not as
  generic failures.** Shorts are excluded by default (enumeration uses the
  channel's `/videos` tab); an **Include Shorts** per-show option opts in, and
  a Short that slips through is marked **skipped** (terminal, not a failure).
  Live / premiere / upcoming videos are **deferred** and re-probed on the
  daily check — once the stream finishes they auto-queue. Members-only /
  age-restricted / region-locked videos **fail with a specific, friendly
  message** instead of a raw error dump. `skipped` and `deferred` are
  first-class episode states with their own pills and filters.
- **Strict captions.** Only a manual/uploader subtitle in the chosen language
  is imported (auto-generated captions are never used); otherwise whisper. The
  new **Auto** language accepts the channel's default manual track, else
  whisper.
- **`cli.py add <youtube-url> --backlog …` does a deep channel backfill** —
  the whole archive honouring `--backlog`, not just the ~15-video RSS window —
  with new flags `--captions`/`--whisper` and `--skip-shorts`/
  `--include-shorts`. New settings `youtube_skip_shorts_default`,
  `youtube_default_language`, and `youtube_default_transcript_source` hold the
  global defaults.
- **The selectable "use auto-captions if no manual" transcript option is
  gone** (auto-generated captions were never actually used). Legacy stored
  values still load, but there is no UI or CLI path to set it.

### Fixed
- **New YouTube uploads are now actually discovered.** Channel feeds are
  Atom with no audio enclosure, so the feed poll had been yielding zero
  episodes — only the initial backfill ever ran. The manifest builder now
  recognises YouTube channel entries (keyed by the bare video id, pointing at
  the watch URL), so new uploads are picked up, downloaded, and transcribed
  on the regular check like any podcast episode.

## v1.5.0 — 2026-06-25 (AI-operator guardrails & background-load levels)

### Added
- **Background-load levels replace the raw parallelism knobs.** A single
  `load_level` (quiet / balanced / full, with a `background_priority`) now
  drives transcription worker count, whisper-cli threads, and process QoS —
  one dial instead of `parallel_transcribe` + `whisper_multiproc`. The
  Settings pane shows a Hintergrundlast level group; existing settings
  migrate automatically off the legacy knobs.
- **Blessed `add` CLI with a required `--backlog` choice.** `cli.py add …
  --backlog <all|recent|last:N|since:DATE>` is the supported way for scripts
  and AIs to add a show: it seeds episode state, applies the history-vs-future
  strategy, sets the show "decided", and writes `watchlist.yaml` atomically.
  The flag is **mandatory**, so an automated add can no longer silently
  transcribe a show's entire back-catalogue.
- **The running app no longer clobbers external `watchlist.yaml` edits.** It
  records a content hash on load and detects external changes (watchdog +
  checkpoints before every run and on app activation), then **union-merges**
  instead of overwriting — so an edit made while the app is running sticks
  rather than vanishing on the next save.
- **"New show detected" reconcile flow.** A show that appears outside the
  blessed paths is gated (its episodes aren't queued) and surfaced by a
  Shows-tab banner; "Choose…" opens a per-show backlog picker. Left
  unanswered, the full-history default is auto-applied after 24h so the app
  keeps running unattended.
- **`AGENTS.md`** at the repo root documenting the above for AIs operating
  Paragraphos headlessly.

## v1.4.0 — 2026-05-18 (App-activation catch-up & update check)

### Added
- **Missed daily check now caught up on app activation.** Paragraphos
  runs continuously in the tray, but the daily feed check only fired at
  the scheduled time and was lost if the Mac was asleep/off, the app was
  busy, or the check failed (offline). It is now re-run the next time the
  app is brought to the foreground — gated to once per missed slot via
  the existing `should_catch_up` logic, with a re-entrancy latch so a
  rapid refocus during the start delay can't double-fire or emit a
  spurious "already running" toast. A failed/offline/stopped check no
  longer falsely marks the slot done, so it is genuinely retried.
- **Periodic update check on app activation.** The GitHub-release update
  check previously ran only once at startup, so a long-lived tray session
  never noticed a new release. It now also re-checks when the app is
  foregrounded, gated to at most once per 24 h, fully decoupled from the
  catch-up path. A new **Settings → "Check for updates"** toggle (on by
  default) governs both the startup and activation checks; off means zero
  GitHub requests.
- **Update notification deduped per release.** The tray "update
  available" message now fires once per release tag instead of on every
  launch / every check while an update is pending; the in-window banner
  remains the persistent reminder.

### Fixed
- **Discovery routed through the shared httpx client.** iTunes podcast
  search and cover-art fetching now use the same pooled `httpx` client
  as the rest of the app instead of ad-hoc requests — consistent
  timeouts, headers, and connection reuse.
- **Worker orphan-claim scoped to the run-start snapshot.** The queue
  worker could reclaim episodes added after a run began, pushing the
  progress counter past the total (`done_idx > total`). Orphan-claim is
  now bounded to the snapshot taken at run start, so `done_idx ≤ total`
  always holds.

## v1.3.3 — 2026-05-04 (Library auto-refresh, install loop, log dates, Gatekeeper docs)

### Fixed
- **Library tab missed most-recent transcripts.** `_resolve_md_path`
  rebuilt the `.md` filename with `episode_number="0000"` and stat'd
  it. Real downloads write the file under the actual episode number
  from the feed (`_0314_`, `_0644_`, …), so the constructed path
  didn't exist and the row was silently dropped from the Library
  tree. Same slug-drift class as the v1.3.2 `download_phase` fix.
  Apply the same conservative recovery: try canonical path first,
  then glob the show dir for `<YYYY-MM-DD>_*<title-fragment>*.md`,
  refusing date-only fallthrough so two same-day episodes can't
  cross. Verified on a live install with **16 of the 50
  most-recent done episodes invisible** before the fix.
- **Library wasn't refreshed after transcripts completed.**
  `LibraryTab.refresh()` only fired on `__init__` and after a manual
  re-transcribe — long sessions showed a static snapshot from app
  launch. Wire the worker's `episode_done` signal into a 1-second
  debounced refresh; ShowsTab forwards it to a new `library_listener`
  slot the same way it forwards to `queue_listener`. The 1-second
  debounce coalesces a finish-burst (parallel_transcribe=N
  completing several episodes within seconds) into a single tree
  rebuild instead of N rebuilds. `MainWindow._on_nav` already
  refreshes on every Library click as defence-in-depth.
- **Install Homebrew loop.** Clicking the wizard's
  *Install Homebrew…* opened a Terminal that printed
  `curl: (77) error setting certificate verify locations:` and then
  `✓ Homebrew installer finished` despite the curl failure. Two
  bugs in the .command script: (a) py2app's
  `SSL_CERT_FILE` / `SSL_CERT_DIR` / `CURL_CA_BUNDLE` /
  `REQUESTS_CA_BUNDLE` / `OPENSSL_CONF` env vars leak into the
  Terminal child and point at non-existent paths inside the .app
  bundle (curl exits 77); (b) the `bash -c "$(curl …)"` pipe
  swallows curl's exit code, so even `set -e` saw a clean exit and
  printed "finished" anyway. Fix: `unset` the five TLS env vars at
  the top of the script; download `install.sh` to a `mktemp` file,
  check `curl`'s exit code explicitly, and only run
  `bash <tempfile>` on success.
- **In-app log timestamps now include the date.** Both `LogDock` and
  `LogsPane` stamped entries with `HH:MM:SS` only — long sessions had
  ambiguous lines (`08:23:14` could be from this morning or
  yesterday). Switch to `YYYY-MM-DD HH:MM:SS` so dock entries line
  up with the file handler for grepping.

### Docs
- New **First launch on macOS — opening an unsigned build** section
  in README. The old "right-click → Open" trick stopped working on
  macOS Sequoia (15)+. Three-step walkthrough with screenshots:
  (1) click **Done** on the "Paragraphos.app Not Opened" dialog,
  (2) System Settings → Privacy & Security → **Open Anyway**,
  (3) confirm with **Open Anyway** at re-launch. Includes a brief
  why-it-happens note (no $99/yr Apple Developer account → unsigned
  → one-time Gatekeeper challenge).

### Internal
- New tests: `test_library_resolve_md_path.py` (6),
  `test_first_run_brew_script.py` (2 — sniffs the script body and
  end-to-end runs the script with a fake `curl` that exits 77 to
  pin the failure-propagation behaviour).
- Suite: 438 → 446 passing.

---

## v1.3.2 — 2026-04-28 (failed-bucket fixes)

### Fixed
- **`whisper-cli exit 2` on slug-drift** (63 episodes in user's
  failed bucket). `download_phase` rebuilds the slug from
  `(pub_date, title, episode_number)`; `episode_number` defaults to
  `"0000"` when `ep_num_map` (current-run feed-fetch only) doesn't
  carry the guid. Earlier runs wrote `<date>_<real-num>_<title>.mp3`,
  this run rebuilt to `_0000_`, persisted `mp3_path` → ENOENT →
  whisper-cli "input not found" → exit 2 with usage banner. Fixed by
  globbing the audio dir for `<YYYY-MM-DD>_*<title-fragment>*` in
  any supported audio extension BEFORE attempting download
  (`_find_existing_audio` in `core/pipeline.py`); when found, persist
  the actual on-disk path and skip the network round-trip. Match is
  conservative — refuses to fall through to date-only when title
  scoping yields zero hits, so two same-day episodes can't cross.
- **`whisper-cli exit 0, no output` on M4A-as-mp3** (4 episodes:
  hausverwalter-inside MP4 podcasts whose feed advertised `.mp3` but
  the actual enclosure is iTunes ALAC inside an M4A box). Whisper.cpp
  1.8.4's bundled dr_libs decoder doesn't handle MP4 containers and
  doesn't auto-shell-out to ffmpeg even when on PATH. Fixed by
  sniffing the first 16 bytes for whisper-native magic (RIFF+WAVE /
  ID3 / MPEG sync / fLaC); anything else is pre-converted to 16 kHz
  mono PCM WAV via ffmpeg into the existing tempdir before
  whisper-cli is invoked (`_maybe_convert_to_wav` in
  `core/transcriber.py`). Trusting the file extension was unsafe —
  these files have `.mp3` extensions but ALAC content.
- **`refused scheme 'file'` on local-file ingest** (1 episode).
  `ingest_file` writes `mp3_url=file://…` plus a `local_path:<guid>`
  meta key, but the pipeline was sending the file:// URL to
  `download_mp3` → safe_url rejected the scheme. Fixed by reading
  `local_path:<guid>` when the URL starts with `file://` and using
  the path directly; raises a readable `LocalFileMissing` error if
  the source is gone.
- **`non-audio Content-Type` on YouTube-via-URL ingest** (1 episode).
  `ingest_url` tagged the show with `source="url"`, so the worker's
  YouTube branch (`pctx.source == "youtube"`) didn't fire and the
  watch URL went through `download_mp3` → fetched the watch HTML →
  rejected as `text/html`. Fixed by inspecting the yt-dlp extractor
  name in `ingest_url`; anything starting with `youtube` lands as
  `source="youtube"` so the existing captions-first / whisper
  pipeline picks it up.

### Internal
- 9 new tests in `tests/test_pipeline_existing_audio.py` covering
  the match-by-date+title rule (single hit, ambiguous → largest,
  refuses date-only fallthrough, accepts m4a/mp4 in addition to
  mp3), the `download_phase` short-circuit (no `download_mp3`
  invoked when shortcut fires, `mp3_path` persisted, outcome wired
  for transcribe), and both `file://` branches.
- Tests: 429 → 438 passing.

### Verified
- User's failed bucket went 69 → 0. 63 caught by the existing-audio
  shortcut (dedup-by-guid because the original transcripts already
  exist in the library). 4 caught by the magic-byte / ffmpeg
  pre-pass. 2 stranded test ingests (shows no longer in watchlist)
  were marked done manually.

---

## v1.3.1 — 2026-04-23 (Local Transcript tab + UX polish)

### Added
- **Local Transcript** tab — dedicated top-level workspace entry
  between Shows and Queue. Three visually separated zones: a big
  drop area for audio/video, a "Choose folder to import…" button,
  and a URL row. Replaces the v1.3.0 drop card that was embedded
  on the Shows page. A drop anywhere on the main window
  auto-navigates to Local Transcript and ingests there.
- **Shows search-as-you-type** in Add Podcast → By name: results
  populate ~350 ms after the last keystroke (Enter / Search button
  still work).
- **Single-click prefill** on Shows search — selecting a row (mouse
  or keyboard nav) immediately fills RSS / Title / Slug from the
  in-memory iTunes match. Double-click still runs the full fetch
  for the whisper prompt.
- **Inline ingest feedback** on Local Transcript — status line
  below the three zones confirms every drop / folder-pick / URL
  ingest ("Queued a.wav → sha256:… — open the Queue tab to see
  it."). Replaces the intrusive QMessageBox.

### Fixed
- **Local Transcript dark-mode contrast** — supported-formats hint
  now uses the theme-aware `ink_3` token (was unreadable
  `palette(mid)`).
- **File URIs on Drops** — `mp3_url` now uses `Path.as_uri()` so
  paths with spaces / umlauts (`Zoom Meetings/Büro 2026.wav`)
  produce valid RFC 3986 URIs.
- **Drop zone UI thread** — file ingest (SHA-256 hashing) and URL
  probe (yt-dlp up to 60 s) no longer block the main thread; both
  hoisted onto `QThreadPool.globalInstance()` via `QRunnable`.
- **Watch-folder auto-resume** — `check_for_resume()` + 30 s
  `QTimer` in `app.py` revives the paused observer when the
  watched root re-mounts (e.g. replugged external drive). No app
  restart required.
- **Pipeline orphan recovery for non-mp3 stages** — local-source
  episodes now call `set_mp3_path()` on the staged copy so the
  crash-recovery glob finds the real filename instead of guessing.

### Docs
- README refreshed for v1.3.1 (badges, Local Transcript bullet,
  three new screenshots, CLI table gains "Local ingest" row,
  architecture panel lists Local Transcript).
- Settings → Automation & remote control help gains a Local
  ingest section and two extra example agent tasks.

---

## v1.3.0 — 2026-04-23 (universal ingest + CLI parity)

### Added — Universal ingest
- **Universal ingest.** Beyond RSS podcasts and YouTube channels,
  Paragraphos now accepts any audio or video file — dropped on the
  Shows page, dropped anywhere on the main window, pasted as a URL,
  picked up from a watched folder, or batch-imported from an existing
  directory.
- **Drop zone** on the Shows page with a URL line-edit. Files
  land with default show `files`; URLs dispatch through yt-dlp's
  generic extractor (~1000 supported sites) and use the uploader as
  the show slug when known, `web` otherwise.
- **Watch folder** (Settings → Local sources). New files landing in
  top-level subfolders auto-queue against a show derived from the
  subfolder name. `~/Paragraphos/to-be-transcribed/zoom/*.mp4` → show
  `zoom`.
- **Folder import** (File → Import folder…). One-shot scan + queue of
  every supported file in a chosen directory tree.
- **CLI parity:** `paragraphos ingest file | url | folder`,
  `paragraphos watch add | remove | list`.

### Added — Headless / agent control
- **Full GUI parity in the CLI** (23 commands). Inspection commands
  (`status`, `shows`, `show <slug>`, `episodes <slug>`, `failed`,
  `settings`, `feed-health`) accept `--json` for parseable output.
  Queue control (`pause`, `resume`, `stop`, `clear-queue`,
  `priority <guid> <N>`, `run-next <guid>`, `retranscribe <guid>`,
  `retry-failed`). Show admin (`enable`, `disable`, `remove`,
  `set <slug> key=value`). Feed retry (`retry-feed`,
  `retry-all-feeds`). Settings (`set-setting <key> <value>`).
- **Agent prompt** in Settings → Automation & remote control rewritten
  to enumerate every command + example task chains.

### Added — Feed-health diagnosis
- **Categorised feed failures** (`dns / timeout / tls / forbidden / gone /
  server / malformed / redirect_loop / ssrf / too_large / other`) with
  per-category recommendation. Surfaced in the Shows-tab pill
  (`fail · dns`), the new Show Details "Feed health" panel (full
  message, timestamp, backoff state, suggested fix, **Retry now**
  button), and the CLI (`feed-health --json` carries the full payload).
- **Retry failed feeds** toolbar button on the Shows tab clears
  backoff for every fail-marked feed and re-fetches synchronously.

### Added — Performance + reliability
- **Parallel transcribe pool** — `parallel_transcribe` setting now
  actually spawns N `_TranscribeWorker` threads sharing the same
  download queue + a lock-guarded `done_idx` counter. Pre-v1.3 the
  setting was read everywhere but always ran one worker.
- **ffmpeg PATH augmentation** — Paragraphos.app launched from
  /Applications has PATH=/usr/bin:/bin only, so whisper-cli's internal
  ffmpeg call failed silently on m4a / mp4 podcast inputs (`exit 0,
  no transcript`). Locator finds Homebrew ffmpeg and prepends its
  directory to whisper-cli's subprocess env.
- **NAT64 / IPv4-mapped IPv6 SSRF unwrap.** Resolvers on macOS
  DNS64 LANs synthesise addresses in `64:ff9b::/96` (RFC 6052) and
  `::ffff:0:0/96` (RFC 4291); both classify as `is_reserved=True` so
  `_is_private_ip` rejected every public host as "private-network".
  Now unwraps the embedded IPv4 and screens that. Fixed a wave of
  feed failures users were silently hitting.
- **Persisted `mp3_path`** in state.sqlite so the orphan-recovery
  path (download crash → next-launch retry) reads the authoritative
  on-disk filename instead of guessing the slug, with a glob fallback
  for legacy rows.
- **Slot exception handler** (`sys.excepthook`) — uncaught Python
  exceptions inside Qt slots now log + show a QMessageBox instead of
  PyQt6's default `qFatal` → SIGABRT.
- **Connection probe + auto-resume** — already shipped earlier but
  refined: offline state no longer pauses the queue; downloaded items
  keep transcribing while feed-fetch is offline. Network-failed
  episodes from the last 24h re-queue on reconnect.

### UX
- **Queue tab toolbar consolidated to the top** (Start / Pause / Stop /
  Refresh / Remove all). Hero card no longer carries duplicate
  Pause/Stop buttons. Status column header cycles
  priority → asc → desc → priority on click. Default sort follows
  pipeline stage (transcribing → downloading → downloaded → pending).
- **Shows tab toolbar at the top** (matches Queue + Failed). Bulk-on-
  selection row beneath. New "Retry failed feeds" button.
- **Settings value widgets** (QSpinBox / QComboBox / QSlider) ignore
  scroll-wheel events so users don't bump values while scrolling.
- **Library page** (sidebar entry) — tree | list | preview view of all
  transcripts on disk.
- **Workspace** sidebar group rename (was "Library").
- **Persistent hero card** (idle = grey ring + dashes; active = colored).

### Observability
- **Startup fingerprint** — single log line per launch with version,
  macOS, Python, CPU/RAM, whisper-cli + yt-dlp + ffmpeg versions, and
  every user-tunable setting. Replays into the in-app LogDock on first
  window-open so users see it without tailing the file.
- **Humanised exit codes** in TranscriptionError messages
  (`whisper-cli exit -9 (killed (SIGKILL — usually the Stop button's
  force-kill, or macOS OOM))`).

### Fixed
- ShowDetailsDialog `Retry now` no longer crashes the app on success
  (attribute aliasing in the rebuild path).
- `feed-health` for old podcast feeds with `.mp4` / `.m4a` enclosures
  no longer silently fails when ffmpeg is missing from the .app PATH.
- Resizable header crash on initial layout (sectionResized burst).

### Internal
- New modules: `core/feed_errors.py`,
  `tests/test_cli_parser.py`, `tests/test_feed_errors.py`,
  `tests/test_show_details_feed_health_panel.py`,
  `tests/test_transcriber_ffmpeg_path.py`.
- Tests: 99 → 386 passing.
- New modules: `core/local_source.py`, `core/watch_folder.py`,
  `ui/drop_zone.py`, `ui/import_folder_dialog.py`.
- `core/pipeline.process_episode` gains a `local` source branch that
  bypasses `download_mp3` (source files are copied into staging).
- `Show.source` adds `local-folder | local-drop | url` values alongside
  `podcast | youtube`.
- `Settings` gains `watch_folder_enabled / watch_folder_root /
  watch_folder_post / local_max_duration_hours`.

## v1.2.0 — 2026-04-22 (YouTube ingestion)

### Added
- **YouTube channels as first-class shows.** Subscribe to a channel
  and Paragraphos polls its hidden RSS feed; new videos transcribe
  automatically. Channel discovery + backfill via yt-dlp.
- **Captions-first transcript path.** Uploader-provided captions are
  fetched and converted (VTT → SRT) instantly; whisper takes over
  when no captions are available.
- **Per-channel transcript-source override** in Show Details:
  Captions / Always whisper / Use auto-captions if no manual.
- **yt-dlp lazy install + weekly self-update.** Installed to
  `~/Library/Application Support/Paragraphos/bin/yt-dlp` on first
  YouTube use; `yt-dlp -U` runs once a week on launch.
- **Sources filter in Settings.** Uncheck YouTube to hide all
  YouTube UI and skip the yt-dlp install. At least one source must
  remain checked.
- **Re-run setup guide button** in Settings (mirrors the existing
  Help → Re-run setup guide menu entry).

### Changed
- `core/export.py` gains a unified `render_episode_markdown()` used
  by the YouTube transcript writer; the existing podcast renderer
  in `core/transcriber.py` is unchanged.
- `core/pipeline.PipelineContext` gains optional `source`,
  `youtube_channel_id`, `youtube_transcript_pref`, and
  `youtube_default_transcript_source` fields.

### Internal
- New modules: `core/sources.py`, `core/youtube.py`,
  `core/youtube_meta.py`, `core/youtube_captions.py`,
  `core/youtube_audio.py`, `core/ytdlp.py`,
  `ui/ytdlp_install_dialog.py`.

## v1.1.9 — 2026-04-22 (onboarding + search polish)

### Added
- **Setup guide.** After the first-run wizard, a 3-page dialog asks
  where transcripts should go (default `~/Desktop/Paragraphos/transcripts`)
  and whether you use Obsidian. Picks up `.obsidian/`-marked vaults and
  can co-locate transcripts inside them. Re-runnable via
  Help → Re-run setup guide.
- **Rich search-results table.** Name-mode results now show cover,
  title, author, episode count, newest episode date + title. Feed
  probes run lazily in the background, viewport-aware.
- **Scroll-triggered auto-load.** Reaching the bottom of the result
  list auto-fetches the next 50, up to iTunes' 200-item cap.
- **Output formats toggle.** New Settings → Output formats group.
  Markdown (.md) is always saved; SRT (.srt) is opt-out. Useful
  reminder that SRT carries per-segment timestamps for timestamped
  quotes.
- **HW-aware first-run defaults.** On a truly fresh install (no prior
  settings file), `parallel_transcribe` and `whisper_multiproc` are
  pre-filled from `core.hw.recommended_*()`. Saved settings are never
  overridden.

### Changed
- Folder pickers default to `~/Desktop` when the current field is empty.
- Obsidian settings consolidated into a dedicated group box.
- New-install defaults no longer point at author-specific paths.
- Slug auto-fill uses proper Unicode-aware slugify on every add path
  (CLI, OPML import, UI add-show).

### Fixed
- Apple Podcasts add path now sets a slug (previously empty).
- Wiki-compile banner no longer shows for users who aren't using
  Obsidian — it made no sense outside an Obsidian workflow.
- Deleting a show or episode now preserves `.md` + `.srt`; only the
  `.mp3` is removed. Transcription costs compute; re-downloading
  audio from the feed is free.

## v1.1.8 — 2026-04-22 (wizard v2)

### Fixed
- **First-run wizard — whisper detection on non-standard brew prefixes.**
  The dep check now searches `/opt/homebrew`, `/usr/local`, and
  `/opt/local` for `whisper-cli`. Previously, a successful install on a
  non-default prefix was reported as "not found".
- **First-run wizard — `brew` lookup inside the `.app`.** `brew install`
  commands now run with an expanded PATH (Homebrew bin dirs prepended
  to the user's existing PATH) so a Finder-launched `.app` finds `brew`
  immediately after Homebrew is installed, without needing a restart.

### Added
- **Hardware compatibility pre-check.** Wizard rejects Intel Macs and
  macOS < 13 (Ventura) before wasting time on installs. Also warns on
  < 8 GB RAM or < 3 GB free disk.
- **Auto-start + serialization.** Model download starts on wizard open
  (no sudo required); whisper-cpp and ffmpeg install automatically one
  after another once Homebrew is detected. No user clicks in between.
- **Live install feedback.** Each running dep row shows an elapsed
  seconds counter and the latest line of `brew`'s stdout, so installs
  never sit on a silent "installing…" pill.
- **Retry on install failure.** If whisper-cpp, ffmpeg, or the model
  download fails, the row shows a Retry button wired back to the
  original install — previously the user was stuck on the "fail" pill
  with no way to try again.

## v1.1.3 — 2026-04-21 (live progress + UX polish)

### Queue & transcription
- **Live transcribe %** — whisper-cli's segment timestamps are tailed
  from a redirected stdout log via a daemon poller; Queue status
  column shows `transcribing · 42%` on the active row.
- **Duration-based ETA** — pending audio × realtime factor replaces
  episodes × avg-per-episode; Queue hero + status bar + tray all
  converged on the same calculation.
- **Active stages on top** — SQL CASE sort in Queue table puts
  transcribing → downloaded → downloading before pending; the 500-row
  LIMIT is gone so the full backlog is visible.
- **Per-row Audio / Whisper / Finish columns** in Queue with
  cumulative completion time (row N = sum of all rows above).
- **304 "feed unchanged" still processes pending** — earlier the
  conditional GET short-circuit skipped orphaned pending episodes
  from prior runs.
- **Run next / Run now** context-menu actions (priority 5 / 10) in
  Queue and Show Details.
- **Parallel download pool** with per-host cap actually visible in
  the table now that the sort honours active stages.
- **Resumable `.mp3.part`** via HTTP Range.

### UI polish
- **Auto-start queue** on launch (Settings checkbox, default on);
  clears any leftover `queue_paused` flag so it actually runs.
- **Land on Queue tab** when work is pending, else Shows.
- **Window size persists** across sessions via QSettings; first
  launch fills 95% of the available primary screen.
- **Auto-fit Queue columns** so `transcribing · 42%` isn't clipped.
- **Scroll + selection preserved** across Shows-tab refresh.
- **Dark-mode QComboBox popup + QMenu** styled via theme tokens.
- **Section headlines** in Settings readable in dark mode.
- **Sidebar count chip** no longer renders as a black box.
- **Show Details**: 'Refresh from feed' persists changes + refreshes
  Shows table in place; artwork auto-loads from `<itunes:image>`
  with on-disk cache.
- **In-window Logs + About** panes (no more Finder / popup detour);
  Log title bar click-to-copy; About grows a live Changelog tab
  fetched from GitHub releases.
- **Keyboard cheatsheet** via `?` / `Cmd+/`.
- **Context menus**: Details / Informationen reachable from right-
  click in Shows (not just double-click).
- **Notification icon**: app icon in every tray push notification.
- **Multi-processor split**: HW-based recommendation seeded + hint.
- **Tuning hint banner** in Queue when parallel/multiproc diverge.

### Fixes
- **Signal delivery** child → parent in `CheckAllThread` is now
  `DirectConnection`; queued delivery silently dropped because
  CheckAllThread has no event loop. Hero counter now increments.
- **Queue table refresh** runs every 1 s (3 s coalesce) — status
  transitions (downloaded → transcribing) no longer stay invisible
  until an episode fully completes.
- **Feed-status Pill** seeded from `feed_health` meta on load; each
  check writes ok/fail via backoff.
- **Settings hint text** no longer clipped (heightForWidth container);
  Whisper-prompt edit + hint no longer overlap.

### Infra
- **Node 24 actions + FORCE_JAVASCRIPT_ACTIONS_TO_NODE24** — no more
  Node 20 deprecation warnings.
- **`contents: write` permission** in build-release.yml so release
  notes + DMG asset upload actually work.
- **CHANGELOG tab** pulls from GitHub releases (madevmuc/paragraphos)
  off-thread; falls back to bundled CHANGELOG.md.
- **Vendor-neutral compile banner** ("your AI assistant" not "Claude").
- **Pre-commit ruff pinned to v0.15.11** to match CI.

## v1.1.0 — 2026-04-21 (perf + UX polish)

### Performance
- **Parallel downloads** — `_DownloadPool` spawns N worker threads
  (`settings.download_concurrency`); per-host cap (`download_concurrency_per_host`)
  now actually parallelizes across CDNs.
- **Resumable downloads** — interrupted `.mp3.part` files resume via HTTP
  `Range: bytes=N-`; falls back cleanly when the server ignores the
  header (returns 200 instead of 206).

### UX
- **Episode priority UI** — right-click in Queue / Show Details exposes
  "Run next" (priority=5) and "Run now" (priority=10). Queue sort key
  now includes `priority DESC`.
- **Keyboard shortcut cheatsheet** — press `?` or `Cmd+/` to see every
  shortcut, harvested from the menu bar so it can't drift.
- **In-window update banner** — when a new release is available, the
  banner shows a `Download <tag>` button that opens the GitHub release.
  Dismissed per-tag via QSettings.

### Settings
- **Model health row** — shows file size, first 8 hex of the pinned
  TOFU hash, and flags partial downloads / size drift vs. the pinned
  entry. `model_hashes.yaml` now records size alongside sha256.
- **Engine-drift detection** — transcripts carry `whisper_version` and
  `model_sha256` in frontmatter; Settings surfaces a
  "Re-transcribe all" button when either changes since the last batch.

### Dark-mode polish
- Banner, status bar, Show Details, Add dialog, First-run wizard no
  longer depend on inline `palette(mid)` — all flow through
  `ui.themes.current_tokens()`. Banner re-paints live on appearance
  change instead of freezing on whichever mode was active at startup.

## v1.0.1 — 2026-04-21 (design polish)

- Proper macOS dark mode — `ThemeManager` follows system appearance,
  shared QSS template with light/dark token dicts, all custom-paint
  widgets (Pill, ProgressRing, tray icon) repaint on `colorSchemeChanged`.
  Accent flips from ochre (light) to Apple-Podcasts purple (dark).
- App icon (Concept A "Pilcrow") — bundled `AppIcon.icns`, wired into
  `QApplication.setWindowIcon` and every `py2app` config as `iconfile`.
- Menu-bar tray icon uses `MenuBarIconTemplate.png` with
  `QIcon.setIsMask(True)` so macOS auto-tints against the menu bar.

## v1.0.0 — 2026-04-21 (ship v1.0)

First public release. Closes every deferred item from the Phase 0–6 roadmap.

### Foundations
- `core/version.py` as the single source of truth for the app version;
  every `setup*.py`, `pyproject.toml`, About dialog, DMG script, and
  test asserts against this symbol.
- `Settings.github_repo` makes the update-check endpoint configurable
  for forks.
- `core/http.py` threaded through downloader/rss/scrape/model_download/
  updater: one thread-safe, HTTP/2-gated `httpx.Client` for the whole
  app, closed on `QApplication.aboutToQuit`.
- Spot-check tray notification now respects `notify_mode="off"`.
- Integration suite gets a 5-s silent MP3 fixture and graceful skip
  when the ggml-base model isn't installed locally.

### Design refresh (Phase 6 screens)
- Sidebar + `QStackedWidget` replaces the top `QTabWidget`. Live
  Shows/Queue/Failed counts.
- Shows tab filter toolbar with a popover, `QSettings`-persisted state,
  active-filter count `Pill`, and `Pill`-based Feed column that
  actually filters on feed health now.
- Queue hero dashboard with `ProgressRing` + human-framed finish time
  ("before lunch", "this afternoon", "tomorrow morning").
- Failed tab restyle — humanised error reasons + per-row ⋯ action menu
  (Retry · Mark resolved · Show log · Copy error · Skip forever).
- Settings inline hints per field with `"info"` (muted/italic) and
  `"good"` (green/check) kinds; Hardware recommendation split into
  seeder value + hint label.
- First-run wizard restyle: pills per check, line-soft dividers, muted
  sub-copy, Continue disabled until all four deps are ok.
- Add Podcast: 3-mode segmented dialog (By name · By URL · Paste Apple
  link) with off-thread feed fetch.
- Show Details restyle — 620×440 with artwork header, recent-episodes
  table with status pills, Advanced disclosure for title / whisper
  prompt / language.
- Tray menu rebuilds per `episode_done` with a rich `QWidgetAction`
  status block (pill · fraction · ETA · progress bar · current ep).

### Performance
- Concurrent RSS refresh via `ThreadPoolExecutor`, capped at
  `settings.rss_concurrency`.
- Parallel download + transcribe — two-thread pipeline sharing a
  bounded `queue.Queue` for backpressure and per-host download cap.
- RSS conditional GET (ETag / If-Modified-Since): 304 short-circuits
  the parse step for unchanged feeds.
- Queue table rebuild throttled to 3 s with coalesced refresh requests.

### Features
- Re-transcribe a single episode from Queue or Show Details:
  status → pending, priority → 10, existing `.md` → `.md.bak` for
  diffing later.
- Bulk actions in Shows tab: Disable / Enable / Mark stale / Delete
  (with confirm) across multi-selected rows.
- Transcript diff dialog (`difflib.HtmlDiff`) available wherever a
  `.md.bak` sibling exists.

### Housekeeping
- Ruff auto-fixes + formatter pass across the codebase.
- Real F821 fix in first-run wizard model-download fallback and
  unused-var cleanup in `tests/test_state.py`.

## v0.7.0 — 2026-04-20 (Phase 6 design foundation)

- `ui/widgets/`: `_tokens.py`, `pill.py`, `sidebar.py`,
  `filter_popover.py`, `progress_ring.py`, `tray_icon_renderer.py`.
  Single stylesheet installed via `apply_app_qss()`.
- Tray icon now renders a live `done/total` fraction during a run, ✓
  for 5 s on completion, then idle `P`.
- Remaining screens (sidebar-nav swap, Shows filter toolbar, Queue
  hero, Failed restyle, Settings hints, First-run restyle, Add dialog
  3-mode, Show Details restyle, menu-bar rich block) deferred to
  dedicated follow-up commits — the widget foundation is the
  prerequisite that lets those ship independently.

## v0.6.2 — 2026-04-20 (Phase 5 dev experience)

- `pyproject.toml` (ruff + pytest markers), `.pre-commit-config.yaml`.
- `.github/workflows/test.yml` + `build-release.yml`.
- `tests/integration/` opt-in end-to-end regression harness.
- `core/README.md`, `ui/README.md`, `docs/ARCHITECTURE.md`.

## v0.6.1 — 2026-04-20 (Phase 4 distribution)

- `core/updater.py` — non-blocking GitHub-releases version check.
- `scripts/build-dmg.sh` — hdiutil wrapper for a DMG.
- `setup-full-universal.py` — arch=universal2 config for Intel Macs.

## v0.6.0 — 2026-04-20 (Phase 3 UX polish)

- Shows tab: search filter, sortable columns, ExtendedSelection.
- Daily-summary notification mode: one tray message per run instead of
  per-episode. Spot-check notification still fires once per show.
- Notification frequency picker in Settings (per_episode / daily_summary
  / off).

## v0.5.2 — 2026-04-20 (Phase 2 features)

- Per-show pause (right-click → Pause '<slug>'). Separate from the
  global queue pause.
- Failed tab: "Play MP3" button opens partial audio in the default
  macOS audio app for spot-checking corrupt episodes.
- `core/http.py` module-level `httpx.Client` scaffold for connection
  pooling (to be wired into rss/downloader/scrape).

## v0.5.1 — 2026-04-20 (Phase 1.5 performance)

- `whisper_fast_mode` toggle: adds `-bs 1 -bo 1 -ac 0 --no-fallback`
  for ~2-3× speedup on turbo.
- `whisper_multiproc` (1-8): enables `whisper-cli -p N` audio-split
  parallelism for long episodes.
- SQLite PRAGMA `journal_mode=WAL` + `synchronous=NORMAL`.
- `LibraryIndex` mtime cache: sub-second startup on 1000+ transcript
  vaults.

## v0.5.0 — 2026-04-20 (Phase 1 reliability)

Five reliability improvements from the ROADMAP:

- **Whisper timeout** (Task 1.1) — `subprocess.run(timeout=600)` with a
  clean `TranscriptionError` on hang. Corrupt MP3s no longer block the
  queue indefinitely.
- **Download retry with exponential backoff** (Task 1.2) — 3 attempts,
  delays 1 / 5 / 20 s, retries on 5xx / 429 / timeouts / network errors.
  Never retries 4xx (permanently gone).
- **TOFU model SHA256** (Task 1.3) — trust-on-first-use replaces the
  v0.4 placeholders that would have blocked every non-default model
  download. First download pins the hash; subsequent mismatches raise
  with clear remediation copy.
- **Feed redirect auto-update** (Task 1.4) — canonical URL after 301
  is saved to watchlist.yaml; subsequent daily checks hit the new URL
  directly.
- **Whisper prompt coverage feedback** (Task 1.5) — ⚠ tooltip on the
  title when less than 20% of prompt terms appear in the last 10
  transcripts. Non-blocking hint.

99 tests green.

## v0.4.4 — 2026-04-20 (better errors)

Every failure path now carries enough context to debug without a
reproducer. The dotted-slug bug that cost hours today would have been
obvious in seconds from this output.

- **whisper-cli non-zero exit**: error includes mp3 filename, model,
  slug, last 400 chars of stderr, last 200 chars of stdout.
- **whisper-cli exited 0 but no output files**: error lists the paths
  we expected, the actual contents of the temp dir (so mismatches jump
  out), plus stdout/stderr tails, mp3 name and slug.
- **Hallucination / silence guard**: error includes the observed word
  count, threshold, mp3 name, slug, and first 200 chars of the produced
  text (so you can tell apart silence, foreign-language misdetection,
  and whisper-loop hallucination at a glance).
- **Download failures** (pipeline): show exception type + message,
  show slug, guid, source URL, destination path.
- **Transcribe failures** (pipeline): show multi-line propagated error
  plus show/guid/mp3 path.
- **Log dock rendering**: failures now span multiple indented lines
  instead of being truncated at 100 chars — the previous truncation
  literally hid the filename that would have revealed the dot bug.
- **Root-logger errors**: download + transcribe failures are also
  logged to `~/Library/Application Support/Paragraphos/logs/` via
  `logger.error(..., exc_info=True)` so future issues leave a traceable
  trail.

## v0.4.3 — 2026-04-20 (transcriber path bug)

**Fix:** whisper-cli output lookup was using `Path.with_suffix(".txt")` on
the `-of` prefix. For slugs containing a dot mid-title — e.g.
`"… Co. (Kein) Plädoyer …"` or `"Nachhaltigkeit & Co. müssen …"` —
`with_suffix` truncates at the last dot, so we looked for `Co.txt` while
whisper-cli had actually written the full-length filename. Result: every
episode with a dot in the title raised *"whisper-cli produced no output
files"* even though whisper succeeded. Root cause reproduced with a
focused regression test; fixed by constructing the path via string
append (`stem.parent / (stem.name + ".txt")`).

Affected shows observed: 5 limmo episodes (title pattern journalistic,
heavy use of `.` as a separator). All 893 previously-transcribed
episodes were unaffected because they don't exhibit the pattern
(or were transcribed by the pre-Paragraphos `scripts/transcribe.py`).

Migration: all `failed` episodes with this error were reset to
`pending` in state.sqlite so the next Check Now will retry them.

Test coverage: new `test_transcribe_slug_with_dots_in_title` locks in
the regression; both transcriber + pipeline fakes updated to mimic
whisper-cli's actual "append suffix" behaviour.

84 tests green (83 + 1 new regression test).

## v0.4.2 — 2026-04-20 (safe quit)

- **Quit-confirmation dialog** when the queue is still running. Fires
  from tray menu "Quit", Cmd+Q, Dock → Quit — all routed through
  `quit_with_confirm()`. Default button is "Stay" to avoid accidental
  data loss. "Quit anyway" is the destructive button.
- Busy check also reads the DB directly — catches in-flight episodes
  whose status is `downloading` or `transcribing` even if the thread
  state briefly disagrees.
- `ParagraphosQApplication` now intercepts `QEvent.Quit` so ⌘Q goes
  through the confirm dialog instead of hard-killing subprocesses.

## v0.4.1 — 2026-04-20 (ETA from t=0)

- **Queue finish-time shown immediately on start**, not only after the
  first live episode completes. At `start_check()` we compute a
  historical average from the last 50 successful transcriptions in
  `state.sqlite` and use that as the ETA seed.
- Label distinguishes live vs. estimated: `ETA 1h 12m` (live rolling
  average) vs. `ETA (est.) 2h 58m` (DB-derived). Same for Queue tab's
  `avg/ep:` vs. `est/ep:`.
- New `QueueRunState.effective_avg_sec` property returns live average
  if available, historical fallback otherwise.
- `core/stats.historical_avg_transcribe_sec()` averages the wall-clock
  delta (attempted_at → completed_at) across the 50 most recent DONE
  episodes, filtering out dedup-skips (<5 s) and crashed jobs (>1 h).

## v0.4 — 2026-04-20 (hardening)

**Security — defences against malicious feeds, pages, and models.**

- `core/security.py`: central `safe_url()` (blocks `file://`, `data:`,
  `javascript:`, and private-IP hosts via SSRF-guard),
  `safe_path_within()` (traversal guard), `verify_model()` (pinned
  SHA-256 per whisper.cpp GGML model), and size caps:
  MP3 ≤ 2 GB, RSS ≤ 50 MB, HTML ≤ 10 MB.
- Downloader rejects non-audio Content-Type (refuses HTML/JSON blobs
  delivered to `<slug>.mp3`) and aborts streams exceeding the cap.
- Scraper revalidates every extracted MP3 URL against `safe_url` —
  a malicious `og:audio` pointing at `file:///…` is refused.
- OPML parser switched to `defusedxml` (blocks XXE, billion-laughs).
- Sanitizer neutralises `..` components (belt for path-traversal
  defence; `safe_path_within` is the braces).
- Pipeline verifies final `.mp3` and `.md` paths stay inside
  `output_root` before writing.
- Model downloader deletes a mismatched `.part` rather than moving it
  into place.
- About dialog gains a **Security tab** explaining the threat model,
  mitigations, residual risks, and vulnerability-reporting path.
- 20 new tests in `test_security.py`.

**Bugfix — Settings usability.**
- Settings pane wrapped in a `QScrollArea`; all 6 sections + agent
  prompt remain accessible at any window height.

## v0.3.2 — 2026-04-20 (polish 2)

- **Focus-clear on background click**: clicking on the gray background of
  any tab now removes the cursor/selection from a previously-active
  input field. Previously clicking outside a QLineEdit left it still
  looking "focused". App-level `QEvent.MouseButtonPress` filter — only
  clears focus from text/number inputs, buttons/menus behave normally.

## v0.3.1 — 2026-04-20 (polish)

- **Queue timestamps now show weekday + date** — started and expected
  finish times are rendered as `ddd, dd.mm.yyyy HH:mm` in the status
  bar and Queue tab. Uses `QLocale.system()`, so the date order
  (dd.mm vs mm.dd) matches your macOS region setting automatically.
- **Settings now organized by theme**: Library & output · Schedule &
  monitoring · Notifications · Transcription engine · Storage &
  retention · Automation & remote control.
- **AI-agent prompt template** in Settings → Automation — a ready-to-
  paste briefing for Claude Code / Gemini CLI / any agent with shell
  access. "Copy to clipboard" button included.
- **About dialog now has a Credits & Licenses tab** — full table of
  runtime dependencies with SPDX license identifiers and project
  URLs (Python, Qt/PyQt6, whisper.cpp, OpenAI Whisper model,
  APScheduler, watchdog, feedparser, httpx, pydantic, bs4, lxml,
  PyYAML, ffmpeg, Homebrew) + explanation of permissive vs. GPL
  implications and a note on podcast audio rights.

## v0.3 — 2026-04-20 (renamed)

- **Renamed to Paragraphos** (from Podtext).
  Bundle: `/Applications/Paragraphos.app`, bundle id `com.m4ma.paragraphos`,
  user data `~/Library/Application Support/Paragraphos/`.
- Automatic migration of existing state from the previous
  `~/Library/Application Support/Podtext/` and from the dev-mode
  `scripts/podcast-studio/data/` dirs — no manual data move needed.

## v0.2.4 — 2026-04-20 (late night)

- **Global queue status in status bar** — visible from every tab. Shows
  running/idle/paused, done/total counter, started-at, elapsed, ETA,
  expected finish time. Updates every second via QTimer.
- **Start / Pause / Stop buttons on both Shows and Queue tabs** (previously
  only the Shows tab had them). Queue tab's Start button turns into
  "Resume" when the queue is paused.
- **Failed tab**: new "Add failed to queue" and "Push failed on top of
  queue" buttons. The latter uses the new `episodes.priority` column —
  items with higher priority are processed first in `list_by_status`.
- **Notifications setting**: `notify_on_success` toggle now gates the
  spot-check notification too (was always firing before). New
  "Open macOS Notification settings…" button jumps straight to
  System Settings → Notifications for re-authorizing Paragraphos.
- **QueueRunState** on AppContext — shared live state so any tab can
  render the running check.

## v0.2.3 — 2026-04-20 (night)

- **Portable standalone bundle** (`setup-full.py py2app`): 310 MB `.app`
  with Python + all Python deps inside — runs on any Mac with no repo
  and no `.venv`. The first-run wizard still handles the non-Python
  system deps (Homebrew / whisper-cpp / ffmpeg / model).
- **User data moved to `~/Library/Application Support/Paragraphos/`**
  (macOS convention) — one-time lazy migration from the old
  `scripts/podcast-studio/data/` location on first launch. Watchlist is
  no longer git-tracked — per-user state.
- `scripts_legacy_shows` gracefully falls back to an empty prompts
  dict when running from a bundle on a machine without `transcribe.py`.

## v0.2.2 — 2026-04-20 (evening)

- **OPML drag-&-drop onto Dock icon** — drop an `.opml` file on
  Paragraphos in Finder or the Dock and it imports the feeds directly,
  no menu traversal needed. `Info.plist` declares Paragraphos as an
  OPML handler; `QFileOpenEvent` is intercepted and routed to the
  same import logic used by the File menu.

## v0.2.1 — 2026-04-20 (late afternoon)

- **Global library stats** on Shows tab header: transcript count,
  total audio duration (days / hours / minutes), total word count.
- **Per-show Details dialog** on row double-click: stats, episodes
  with status/words/duration, inline editor for title / RSS URL /
  language / whisper_prompt.
- **Rescan library** button: counts words in every `.md` under
  `output_root` and reads duration from sibling `.srt` files —
  one-time for historical transcripts.
- **Feed backoff wired into worker**: 3/4/5+ consecutive feed fails
  pause that feed 1/3/7 days; reset on next success.
- `state.episodes` gets `duration_sec` + `word_count` columns
  (idempotent ALTER on startup).
- Pipeline records word count + `.srt`-derived duration on completion.

## v0.2 — 2026-04-20

- **Renamed** from Podcast Studio → Paragraphos.
- **Menu bar**: full File / Edit / View / Actions / Window / Help with shortcuts.
- **⌘,** opens Settings; **⌘R** triggers Check Now; **⌘.** stops; **⌘L** toggles log dock.
- **Log dock** now timestamps every line.
- **Banner** adapts to dark/light mode.
- **Notifications** now read `done/total — Show — Episode`.
- **Settings auto-save** on every change (Save button removed).
- **Parallel workers hint** with hardware-based recommendation.
- **Terminal commands help** inline in Settings.
- **Failed tab**: added Retry all + Clear older than 30 days.
- **Queue pause/resume** (persists across app restart).
- **About + Changelog dialogs** accessible from Help menu.

## v0.1 — 2026-04-20

- Initial end-to-end build: menu-bar app, watchlist, daily monitor, curated
  episodes, library dedup (GUID + filename), umlaut-preserving sanitizer,
  MP3 retention policy, backlog filter, RSS health check, OPML import,
  spot-check notification, first-run verification against 16 real-estate
  podcast feeds (2.023 reference episodes, 0 misses).
