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

### Why not edit `watchlist.yaml` directly?

1. **The running app holds the watchlist in memory and overwrites a raw file edit** on its
   next save — your additions silently vanish and don't appear in the UI until a restart.
   The CLI writes atomically and the running app hot-reloads it without clobbering.
2. **A raw edit makes no backlog decision**, so the next check transcribes the show's
   *entire* back-catalogue. `--backlog` forces that choice up front.

If a show *does* slip in via a raw edit, the app gates it (its episodes aren't queued) and
shows a "new show detected" banner offering a per-show backlog choice. Left unanswered, the
**full-history default is auto-applied after 24h**, so the app keeps running unattended.

## Verifying

```
cli.py shows --json     # shows + per-show pending/done/failed counts
cli.py status --json    # queue depth, in-flight, by-status counts
```

The CLI shares `state.sqlite` + `watchlist.yaml` with the GUI; changes are picked up live.
Full command reference: see the **CLI** section of `README.md`.
