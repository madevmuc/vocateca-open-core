# Agent / automation guide for Paragraphos

For AIs and scripts operating Paragraphos headlessly. **Read this before changing the watchlist.**

## Adding shows — use the CLI, never edit `watchlist.yaml` directly

```
PYTHONPATH=. .venv/bin/python cli.py add "<name | rss-url | youtube-url>" \
    --backlog <all|recent|last:N|since:YYYY-MM-DD> --yes
```

`--backlog` is **required** — it decides how much history to transcribe:

| value             | effect                                                            |
|-------------------|-------------------------------------------------------------------|
| `all`             | the entire archive (can be hundreds of episodes / many hours)     |
| `recent`          | only the newest episode                                           |
| `last:N`          | the newest N episodes (e.g. `last:5`)                             |
| `since:YYYY-MM-DD`| episodes published on/after that date                            |

### YouTube channels

`cli.py add` auto-detects a YouTube URL (any form — `/channel/UC…`, `/@handle`,
`/c/Name`, `/user/Name`, or a bare `@handle` — or a video URL, which adds the
posting channel) and tags it `source=youtube`. `--backlog` then drives a
**deep** channel backfill (the whole archive, not just the RSS window). The
same channel can't be added twice. Extra YouTube-only flags:

| flag                              | effect                                                       |
|-----------------------------------|--------------------------------------------------------------|
| `--captions` / `--whisper`        | import manual uploader captions (whisper fallback) / always whisper |
| `--skip-shorts` / `--include-shorts` | exclude Shorts (default) / include them                   |

To deepen an **existing** YouTube show's history later and queue the new
videos, use:

```
PYTHONPATH=. .venv/bin/python cli.py backlog <slug> \
    --backlog <all|recent|last:N|since:YYYY-MM-DD>
```

Shorts are marked `skipped`; live/premiere videos are `deferred` and re-probed
on the next daily check; members-only / age-restricted / region-locked videos
`fail` with a specific message. None of these count as generic failures.

### Why not edit `watchlist.yaml` directly?

1. **The running app holds the watchlist in memory and overwrites a raw file edit** on its
   next save — your additions silently vanish and don't appear in the UI until a restart.
   The CLI writes atomically and the running app hot-reloads it without clobbering.
2. **A raw edit makes no backlog decision**, so the next check transcribes the show's
   *entire* back-catalogue. `--backlog` forces that choice up front.

If a show *does* slip in via a raw edit, the app gates it (its episodes aren't queued) and
shows a "new show detected" banner offering a per-show backlog choice. Left unanswered, the
**full-history default is auto-applied after 24h**, so the app keeps running unattended.

## Tuning shows & settings

```
cli.py set <slug> auto_vocab=true            # seed --prompt from past transcripts
cli.py set <slug> min_duration_sec=600       # skip episodes shorter than 10 min
cli.py set <slug> max_duration_sec=0         # 0 = no upper limit
cli.py set <slug> notify=false               # silence desktop notifications for a show
cli.py set-setting queue_order newest_first  # oldest_first | newest_first | shortest_first
cli.py set-setting caption_fallback_mode manual_auto_whisper  # YouTube caption chain
cli.py set-setting confidence_marking_enabled true           # mark low-confidence words
cli.py set-setting disk_guard_min_free_gb 10  # auto-pause when free space drops below
```

**Webhooks** (event-driven, 10.1) are configured in `settings.yaml` —
`webhooks_enabled: true` plus a `webhooks:` list of
`{events: [..], kind: command|post, target: <path|url>, enabled: true}`. `events`
accepts exact types (`episode.transcribed`), prefixes (`episode.`), or `[]` (all).
POST targets pass an SSRF guard (no private/loopback hosts).

Per-show settable keys: `enabled`, `language`, `whisper_prompt`, `output_override`,
`youtube_transcript_pref`, `source`, `title`, `rss`, `artwork_url`, `auto_vocab`,
`min_duration_sec`, `max_duration_sec`, `notify`. Any top-level field in `settings.yaml`
is settable via `cli.py set-setting <key> <value>`.

## Verifying

```
cli.py shows --json     # shows + per-show pending/done/failed counts
cli.py status --json    # queue depth, in-flight, by-status counts
cli.py health --json    # deps / model-hash / data-dir / disk-space self-check
cli.py bug-report --out report.zip   # redacted diagnostics bundle
cli.py stats --json     # throughput / realtime-factor / success-rate / counts
cli.py logs --type episode. --show <slug> --json   # query the event log
cli.py logs --export run.json                       # export events to JSON/CSV
cli.py backfill-dates <slug>                         # real YouTube upload dates
cli.py export <slug> --format md|json|pdf            # bulk-export transcripts
cli.py publish [--slug X] --out site/                # static searchable site + RSS
cli.py import-opml subs.opml --backlog recent        # import podcast subscriptions
cli.py find-duplicates <slug> --json                 # report likely re-uploads
cli.py serve --port 8723                             # localhost JSON API (token-guarded)
```

The CLI shares `state.sqlite` + `watchlist.yaml` with the GUI; changes are picked up live.
Full command reference: see the **CLI** section of `README.md`.
