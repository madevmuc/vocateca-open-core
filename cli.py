"""Headless CLI for Paragraphos — full GUI parity for LLM agent control.

Run from ``~/dev/paragraphos``::

    PYTHONPATH=. .venv/bin/python cli.py <command> [args]

The CLI shares state with the GUI via ``state.sqlite`` (WAL mode, safe
concurrent reads/writes) and ``watchlist.yaml`` / ``settings.yaml``.
SQLite-backed mutations (priority bumps, status changes, queue toggles)
are picked up live by a running GUI's worker thread; YAML edits land on
disk immediately but the GUI re-reads them only on its next refresh /
restart, so for show-list edits prefer running CLI with the GUI closed.

Most ``status`` / ``list`` / ``show`` style commands accept ``--json``
for machine-readable output; that's the format LLM agents should ask
for.
"""

from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from core.discovery import find_rss_from_url, search_itunes
from core.library import LibraryIndex
from core.models import Settings, Show, Watchlist
from core.paths import migrate_from_legacy, user_data_dir
from core.pipeline import PipelineContext, process_episode
from core.prompt_gen import suggest_whisper_prompt
from core.rss import build_manifest, feed_metadata
from core.sanitize import slugify
from core.state import EpisodeStatus, StateStore

PKG = Path(__file__).resolve().parent
_legacy = PKG / "data"
migrate_from_legacy(_legacy)
DATA = user_data_dir()


# ────────────────────────────────────────────────────────────────────────
# helpers
# ────────────────────────────────────────────────────────────────────────


def _settings() -> Settings:
    return Settings.load(DATA / "settings.yaml")


def _watchlist() -> Watchlist:
    return Watchlist.load(DATA / "watchlist.yaml")


def _state() -> StateStore:
    s = StateStore(DATA / "state.sqlite")
    s.init_schema()
    return s


def _emit(payload: Any, *, as_json: bool, human: str) -> None:
    """Print ``payload`` as JSON when ``as_json`` is True, otherwise print
    ``human``. Centralised so every command honours --json the same way."""
    if as_json:
        print(json.dumps(payload, indent=2, default=str, ensure_ascii=False))
    else:
        print(human)


def _find_show(wl: Watchlist, slug: str) -> Show | None:
    return next((s for s in wl.shows if s.slug == slug), None)


def _episode_dict(row: dict) -> dict:
    """Project a sqlite row into the JSON shape we expose to agents."""
    return {
        "guid": row.get("guid"),
        "show_slug": row.get("show_slug"),
        "title": row.get("title"),
        "pub_date": row.get("pub_date"),
        "status": row.get("status"),
        "priority": row.get("priority", 0),
        "duration_sec": row.get("duration_sec"),
        "word_count": row.get("word_count"),
        "mp3_path": row.get("mp3_path"),
        "transcript_path": row.get("transcript_path"),
        "attempted_at": row.get("attempted_at"),
        "completed_at": row.get("completed_at"),
        "error_text": row.get("error_text"),
    }


def _coerce_value(default: Any, raw: str) -> Any:
    """Coerce a CLI string to the type of ``default`` (bool/int/float/str).
    Used by ``set`` and ``set-setting`` so agents can pass plain strings
    and we keep the YAML schema honest."""
    if isinstance(default, bool):
        v = raw.strip().lower()
        if v in ("1", "true", "yes", "on"):
            return True
        if v in ("0", "false", "no", "off"):
            return False
        raise ValueError(f"expected bool, got {raw!r}")
    if isinstance(default, int) and not isinstance(default, bool):
        return int(raw)
    if isinstance(default, float):
        return float(raw)
    return raw


# ────────────────────────────────────────────────────────────────────────
# add / list / check / import-feeds (existing commands, lightly updated)
# ────────────────────────────────────────────────────────────────────────


def cmd_add(args: argparse.Namespace) -> int:
    from core.backlog import BacklogError, apply_backlog, parse_backlog
    from core.stats import _parse_duration as _pd
    from core.watchlist_guard import mark_decided

    # Parse the backlog mode FIRST — before any network/IO — so a bad
    # --backlog value fails fast without touching feeds or state.
    try:
        mode = parse_backlog(args.backlog)
    except BacklogError as e:
        print(e, file=sys.stderr)
        return 2

    inp = args.name_or_url.strip()
    if inp.startswith("http"):
        rss = find_rss_from_url(inp) or inp
    else:
        matches = search_itunes(inp)
        if not matches:
            print("no matches", file=sys.stderr)
            return 2
        if args.yes:
            rss = matches[0].feed_url
        else:
            for i, m in enumerate(matches[:5]):
                print(f"[{i}] {m.title} — {m.author}  ({m.feed_url})")
            choice = input("pick index: ").strip()
            rss = matches[int(choice)].feed_url

    meta = feed_metadata(rss)
    manifest = build_manifest(rss)
    slug = args.slug or slugify(meta["title"])
    if not args.yes:
        slug = input(f"slug [{slug}]: ").strip() or slug

    prompt = suggest_whisper_prompt(
        title=meta["title"],
        author=meta["author"],
        episodes=[{"title": e["title"], "description": e["description"]} for e in manifest[-20:]],
    )
    if not args.yes:
        print(f"suggested prompt:\n  {prompt}")
        custom = input("override prompt (enter to keep): ").strip()
        if custom:
            prompt = custom

    wl = _watchlist()
    if any(s.slug == slug for s in wl.shows):
        print(f"show {slug!r} already in watchlist", file=sys.stderr)
        return 3
    wl.shows.append(
        Show(
            slug=slug,
            title=meta["title"],
            rss=rss,
            whisper_prompt=prompt,
            language=(args.lang or "de"),
        )
    )
    wl.save_atomic(DATA / "watchlist.yaml")

    state = _state()
    for ep in manifest:
        state.upsert_episode(
            show_slug=slug,
            guid=ep["guid"],
            title=ep["title"],
            pub_date=ep["pubDate"],
            mp3_url=ep["mp3_url"],
            duration_sec=_pd(ep.get("duration", "")),
        )
    apply_backlog(state, slug, mode, manifest)
    mark_decided(state, slug)
    print(f"added '{slug}' ({len(manifest)} episodes, backlog={args.backlog})")
    return 0


def cmd_shows(args: argparse.Namespace) -> int:
    """List shows in the watchlist. Replaces the old ``list`` (which still
    works as an alias)."""
    wl = _watchlist()
    state = _state()
    rows = []
    for s in wl.shows:
        with state._conn() as c:
            cnt = c.execute(
                "SELECT "
                "  SUM(CASE WHEN status='pending'      THEN 1 ELSE 0 END) AS pending, "
                "  SUM(CASE WHEN status='done'         THEN 1 ELSE 0 END) AS done, "
                "  SUM(CASE WHEN status='failed'       THEN 1 ELSE 0 END) AS failed, "
                "  COUNT(*)                                                 AS total "
                "FROM episodes WHERE show_slug=?",
                (s.slug,),
            ).fetchone()
        rows.append(
            {
                "slug": s.slug,
                "title": s.title,
                "rss": s.rss,
                "source": s.source,
                "enabled": s.enabled,
                "language": s.language,
                "whisper_prompt": s.whisper_prompt,
                "youtube_transcript_pref": s.youtube_transcript_pref,
                "output_override": s.output_override,
                "feed_health": state.get_meta(f"feed_health:{s.slug}") or "unknown",
                "total": cnt["total"] or 0,
                "pending": cnt["pending"] or 0,
                "done": cnt["done"] or 0,
                "failed": cnt["failed"] or 0,
            }
        )
    if args.json:
        _emit(rows, as_json=True, human="")
        return 0
    if not rows:
        print("(empty)")
        return 0
    print(f"{'on':2} {'src':7} {'slug':28} {'pend':>4} {'done':>5} {'fail':>4}  title")
    for r in rows:
        print(
            f" {'✓' if r['enabled'] else ' '} "
            f"{r['source']:7} {r['slug']:28} "
            f"{r['pending']:>4} {r['done']:>5} {r['failed']:>4}  {r['title']}"
        )
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    settings = _settings()
    wl = _watchlist()
    state = _state()
    state.recover_in_flight()
    out_root = Path(settings.output_root).expanduser()
    lib = LibraryIndex(out_root)
    lib.scan()

    targets = [s for s in wl.shows if s.enabled and (not args.show or s.slug == args.show)]
    if not targets:
        print("no enabled shows match")
        return 0

    for show in targets:
        print(f"\n# {show.slug}")
        try:
            manifest = build_manifest(show.rss, timeout=60)
        except Exception as e:
            print(f"  feed error: {e}")
            continue
        for ep in manifest:
            state.upsert_episode(
                show_slug=show.slug,
                guid=ep["guid"],
                title=ep["title"],
                pub_date=ep["pubDate"],
                mp3_url=ep["mp3_url"],
            )
        ep_num_map = {e["guid"]: e["episode_number"] for e in manifest}

        pending = state.list_by_status(show.slug, EpisodeStatus.PENDING)
        if args.limit:
            pending = pending[-args.limit :]
        if not pending:
            print("  no pending")
            continue

        ctx = PipelineContext(
            state=state,
            library=lib,
            output_root=out_root,
            whisper_prompt=show.whisper_prompt,
            retention_days=settings.mp3_retention_days,
            delete_mp3_after=settings.delete_mp3_after_transcribe,
        )
        for ep in pending:
            r = process_episode(ep["guid"], ctx, episode_number=ep_num_map.get(ep["guid"], "0000"))
            print(f"  [{r.action:11s}] {ep['title'][:70]} — {r.detail[:60]}")
    return 0


def cmd_import_feeds(args: argparse.Namespace) -> int:
    """Bulk-import the curated real-estate podcast list."""
    from scripts_legacy_shows import SHOWS_PROMPTS

    feeds = [
        ("one-a-lage", "https://1alage.podigee.io/feed/mp3"),
        ("immocation", "https://immocation.podigee.io/feed/mp3"),
        ("limmo", "https://haufe-immobilienpodcast.podigee.io/feed/mp3"),
        ("hausverwalter-inside", "https://divmpodcast.libsyn.com/rss"),
        ("immobileros", "https://immobileros.podigee.io/feed/mp3"),
        ("real-estate-pioneers", "https://feeds.buzzsprout.com/1997738.rss"),
        ("dmrex", "https://feeds.buzzsprout.com/2078041.rss"),
        ("grundgedanken", "https://gvh.podcaster.de/grundeigentuemerverband.rss"),
        ("faz-finanzen-immobilien", "https://fazfinanzen.podigee.io/feed/mp3"),
        ("lagebericht", "https://feeds.acast.com/public/shows/61e97e498ad1d30012c50117"),
        ("immopreneur", "https://anchor.fm/s/10204d0b4/podcast/rss"),
        ("denkmalimmobilien", "https://denkmalimmobilien-marcelkeller.podigee.io/feed/mp3"),
        (
            "beyond-buildings",
            "https://letscast.fm/podcasts/beyond-buildings-der-podcast-fuer-die-immobilienwelt-im-wandel-0bcfcb5f/feed",
        ),
        ("immokaiser", "https://immokaiser.podigee.io/feed/mp3"),
        ("vermieter-probleme", "https://16qkrph.podcaster.de/Vermietershop-de.rss"),
        ("gluecklich-wohnen", "https://buwog.podigee.io/feed/mp3"),
    ]
    wl = _watchlist()
    state = _state()
    existing = {s.slug for s in wl.shows}
    for slug, rss in feeds:
        if slug in existing:
            print(f"skip {slug} (already in watchlist)")
            continue
        try:
            meta = feed_metadata(rss)
            manifest = build_manifest(rss, timeout=60)
        except Exception as e:
            print(f"! {slug}: {e}")
            continue
        prompt = SHOWS_PROMPTS.get(slug, "")
        wl.shows.append(
            Show(slug=slug, title=meta["title"] or slug, rss=rss, whisper_prompt=prompt)
        )
        for ep in manifest:
            state.upsert_episode(
                show_slug=slug,
                guid=ep["guid"],
                title=ep["title"],
                pub_date=ep["pubDate"],
                mp3_url=ep["mp3_url"],
            )
        print(f"+ {slug}: {len(manifest)} episodes")
    wl.save(DATA / "watchlist.yaml")
    return 0


# ────────────────────────────────────────────────────────────────────────
# inspection
# ────────────────────────────────────────────────────────────────────────


def cmd_status(args: argparse.Namespace) -> int:
    """Top-level snapshot: queue depth, in-flight, by-status counts +
    queue-paused flag. The first thing an agent should call."""
    state = _state()
    with state._conn() as c:
        rows = c.execute("SELECT status, COUNT(*) AS n FROM episodes GROUP BY status").fetchall()
    by_status = {r["status"]: r["n"] for r in rows}
    by_status.setdefault("pending", 0)
    by_status.setdefault("downloading", 0)
    by_status.setdefault("downloaded", 0)
    by_status.setdefault("transcribing", 0)
    by_status.setdefault("done", 0)
    by_status.setdefault("failed", 0)
    by_status.setdefault("stale", 0)

    queue_paused = (state.get_meta("queue_paused") or "0") == "1"
    paused_reason = state.get_meta("paused_reason") or ""

    payload = {
        "by_status": by_status,
        "queue_paused": queue_paused,
        "paused_reason": paused_reason,
        "in_flight": by_status["downloading"] + by_status["downloaded"] + by_status["transcribing"],
        "queue_depth": by_status["pending"]
        + by_status["downloading"]
        + by_status["downloaded"]
        + by_status["transcribing"],
    }
    if args.json:
        _emit(payload, as_json=True, human="")
        return 0
    print(f"queue: {'PAUSED' if queue_paused else 'running'}", end="")
    if queue_paused and paused_reason:
        print(f" (reason: {paused_reason})")
    else:
        print()
    print(f"depth: {payload['queue_depth']}  (in-flight: {payload['in_flight']})")
    print("by status:")
    for k in (
        "pending",
        "downloading",
        "downloaded",
        "transcribing",
        "done",
        "failed",
        "stale",
    ):
        print(f"  {k:14}{by_status[k]}")
    return 0


def cmd_episodes(args: argparse.Namespace) -> int:
    """List episodes for a show, optionally filtered by status."""
    state = _state()
    sql = "SELECT * FROM episodes WHERE show_slug=?"
    params: list[Any] = [args.slug]
    if args.status:
        sql += " AND status=?"
        params.append(args.status)
    sql += " ORDER BY pub_date DESC"
    if args.limit:
        sql += f" LIMIT {int(args.limit)}"
    with state._conn() as c:
        rows = [dict(r) for r in c.execute(sql, params).fetchall()]
    eps = [_episode_dict(r) for r in rows]
    if args.json:
        _emit(eps, as_json=True, human="")
        return 0
    if not eps:
        print("(none)")
        return 0
    print(f"{'status':13} {'pub_date':25} {'pri':>4}  guid / title")
    for e in eps:
        print(
            f"{e['status']:13} {e['pub_date'][:25]:25} {e['priority']:>4}  "
            f"{e['guid'][:36]}  {e['title'][:60]}"
        )
    return 0


def cmd_failed(args: argparse.Namespace) -> int:
    """List failed episodes (cross-show by default), with their error text."""
    state = _state()
    sql = "SELECT * FROM episodes WHERE status='failed'"
    params: list[Any] = []
    if args.show:
        sql += " AND show_slug=?"
        params.append(args.show)
    sql += " ORDER BY attempted_at DESC NULLS LAST"
    if args.limit:
        sql += f" LIMIT {int(args.limit)}"
    with state._conn() as c:
        rows = [dict(r) for r in c.execute(sql, params).fetchall()]
    eps = [_episode_dict(r) for r in rows]
    if args.json:
        _emit(eps, as_json=True, human="")
        return 0
    if not eps:
        print("(none)")
        return 0
    for e in eps:
        print(
            f"\n[{e['show_slug']}] {e['title'][:80]}\n"
            f"  guid: {e['guid']}\n"
            f"  attempted: {e['attempted_at']}\n"
            f"  error: {(e['error_text'] or '')[:200]}"
        )
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    """Full detail for a single show: settings + episode counts + feed health."""
    wl = _watchlist()
    show = _find_show(wl, args.slug)
    if not show:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    state = _state()
    with state._conn() as c:
        cnt = c.execute(
            "SELECT "
            "  SUM(CASE WHEN status='pending'      THEN 1 ELSE 0 END) AS pending, "
            "  SUM(CASE WHEN status='downloading'  THEN 1 ELSE 0 END) AS downloading, "
            "  SUM(CASE WHEN status='downloaded'   THEN 1 ELSE 0 END) AS downloaded, "
            "  SUM(CASE WHEN status='transcribing' THEN 1 ELSE 0 END) AS transcribing, "
            "  SUM(CASE WHEN status='done'         THEN 1 ELSE 0 END) AS done, "
            "  SUM(CASE WHEN status='failed'       THEN 1 ELSE 0 END) AS failed, "
            "  COUNT(*)                                                 AS total "
            "FROM episodes WHERE show_slug=?",
            (args.slug,),
        ).fetchone()
    from core.feed_errors import recommendation as _rec

    cat = state.get_meta(f"feed_fail_category:{args.slug}") or ""
    payload = {
        **show.model_dump(),
        "counts": {k: cnt[k] or 0 for k in cnt.keys()},
        "feed_health": state.get_meta(f"feed_health:{args.slug}") or "unknown",
        "feed_fail_count": int(state.get_meta(f"feed_fail_count:{args.slug}") or 0),
        "feed_backoff_until": state.get_meta(f"feed_backoff_until:{args.slug}") or "",
        "feed_fail_category": cat,
        "feed_fail_message": state.get_meta(f"feed_fail_message:{args.slug}") or "",
        "feed_fail_at": state.get_meta(f"feed_fail_at:{args.slug}") or "",
        "feed_fail_recommendation": _rec(cat) if cat else "",
    }
    if args.json:
        _emit(payload, as_json=True, human="")
        return 0
    print(f"slug:           {show.slug}")
    print(f"title:          {show.title}")
    print(f"source:         {show.source}")
    print(f"rss:            {show.rss}")
    print(f"enabled:        {show.enabled}")
    print(f"language:       {show.language}")
    print(f"whisper_prompt: {show.whisper_prompt or '(none)'}")
    if show.source == "youtube":
        print(f"youtube_transcript_pref: {show.youtube_transcript_pref or '(default)'}")
    if show.output_override:
        print(f"output_override: {show.output_override}")
    print(f"feed_health:    {payload['feed_health']}")
    if payload["feed_fail_count"] > 0:
        print(f"feed_fail_count: {payload['feed_fail_count']}")
        if payload["feed_backoff_until"]:
            print(f"feed_backoff_until: {payload['feed_backoff_until']}")
    if cat:
        print(f"feed_fail_category: {cat}")
        if payload["feed_fail_at"]:
            print(f"feed_fail_at:   {payload['feed_fail_at']}")
        if payload["feed_fail_message"]:
            print(f"feed_fail_message: {payload['feed_fail_message'][:200]}")
        print(f"recommendation: {payload['feed_fail_recommendation']}")
    print("counts:")
    for k, v in payload["counts"].items():
        print(f"  {k:14}{v}")
    return 0


def cmd_settings(args: argparse.Namespace) -> int:
    """Print all settings (with HW-aware recommendations alongside)."""
    s = _settings()
    payload = s.model_dump()
    try:
        from core.hw import recommended_multiproc_split, recommended_parallel_workers

        payload["_recommendations"] = {
            "parallel_transcribe": recommended_parallel_workers(),
            "whisper_multiproc": recommended_multiproc_split(),
        }
    except Exception:
        pass
    if args.json:
        _emit(payload, as_json=True, human="")
        return 0
    rec = payload.get("_recommendations", {})
    for k in sorted(payload):
        if k.startswith("_"):
            continue
        v = payload[k]
        suffix = ""
        if k in rec and rec[k] != v:
            suffix = f"   (rec={rec[k]})"
        print(f"  {k:38}{v!r}{suffix}")
    return 0


def cmd_feed_health(args: argparse.Namespace) -> int:
    """Per-show feed health (last known + backoff window + categorised
    last error + suggested fix). Use --json if you want the
    `recommendation` field too — the human view trims to one line."""
    from core.feed_errors import label, recommendation

    state = _state()
    wl = _watchlist()
    targets = [s for s in wl.shows if not args.show or s.slug == args.show]
    out = []
    for s in targets:
        cat = state.get_meta(f"feed_fail_category:{s.slug}") or ""
        out.append(
            {
                "slug": s.slug,
                "feed_health": state.get_meta(f"feed_health:{s.slug}") or "unknown",
                "fail_count": int(state.get_meta(f"feed_fail_count:{s.slug}") or 0),
                "backoff_until": state.get_meta(f"feed_backoff_until:{s.slug}") or "",
                "category": cat,
                "message": state.get_meta(f"feed_fail_message:{s.slug}") or "",
                "failed_at": state.get_meta(f"feed_fail_at:{s.slug}") or "",
                "recommendation": recommendation(cat) if cat else "",
            }
        )
    if args.json:
        _emit(out, as_json=True, human="")
        return 0
    if not out:
        print("(no shows)")
        return 0
    print(f"{'slug':28} {'health':10} {'category':14} {'fails':>5}  backoff_until")
    for r in out:
        cat_pretty = label(r["category"]) if r["category"] else ""
        print(
            f"{r['slug']:28} {r['feed_health']:10} {cat_pretty:14} "
            f"{r['fail_count']:>5}  {r['backoff_until']}"
        )
        if r["message"] and args.show:
            print(f"  msg: {r['message'][:120]}")
            print(f"  fix: {r['recommendation']}")
    return 0


# ────────────────────────────────────────────────────────────────────────
# queue control
# ────────────────────────────────────────────────────────────────────────


def cmd_pause(_args: argparse.Namespace) -> int:
    """Set queue_paused=1. The running GUI's worker thread polls this each
    iteration and stops claiming new work."""
    state = _state()
    state.set_meta("queue_paused", "1")
    state.set_meta("paused_reason", "cli")
    print("queue paused")
    return 0


def cmd_resume(_args: argparse.Namespace) -> int:
    state = _state()
    state.set_meta("queue_paused", "0")
    state.set_meta("paused_reason", "")
    print("queue resumed")
    return 0


def cmd_stop(_args: argparse.Namespace) -> int:
    """Force-stop: kill in-flight whisper-cli + yt-dlp processes, set
    queue_paused=1, recover any in-flight episodes back to pending."""
    state = _state()
    state.set_meta("queue_paused", "1")
    state.set_meta("paused_reason", "cli-stop")
    killed = 0
    for proc in ("whisper-cli", "yt-dlp"):
        try:
            r = subprocess.run(["pkill", "-9", proc], capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                killed += 1
                print(f"killed {proc}")
        except Exception as e:  # noqa: BLE001
            print(f"pkill {proc}: {e}", file=sys.stderr)
    n = state.recover_in_flight()
    print(f"recovered {n} in-flight episode(s) → pending")
    return 0 if killed >= 0 else 1


def cmd_clear_queue(_args: argparse.Namespace) -> int:
    state = _state()
    n = state.clear_pending()
    print(f"cleared {n} queued episode(s)")
    return 0


def cmd_priority(args: argparse.Namespace) -> int:
    """Set the priority for one episode. Priority is a tie-breaker in the
    DB-claim ORDER (higher first); 100 is the run-next/run-now level."""
    state = _state()
    if state.get_episode(args.guid) is None:
        print(f"unknown guid: {args.guid}", file=sys.stderr)
        return 2
    state.set_priority(args.guid, args.value)
    print(f"priority {args.value} → {args.guid}")
    return 0


def cmd_run_next(args: argparse.Namespace) -> int:
    """Bump priority to 100 (== Shows tab 'Run next' button)."""
    state = _state()
    if state.get_episode(args.guid) is None:
        print(f"unknown guid: {args.guid}", file=sys.stderr)
        return 2
    state.set_priority(args.guid, 100)
    print(f"run-next: bumped {args.guid}")
    return 0


def cmd_retranscribe(args: argparse.Namespace) -> int:
    """Re-transcribe an episode: status → pending, priority → 100."""
    state = _state()
    if state.get_episode(args.guid) is None:
        print(f"unknown guid: {args.guid}", file=sys.stderr)
        return 2
    state.set_status(args.guid, EpisodeStatus.PENDING)
    state.set_priority(args.guid, 100)
    print(f"retranscribe: {args.guid} → pending @ priority=100")
    return 0


def cmd_retry_failed(args: argparse.Namespace) -> int:
    """Re-queue failed episodes. Without --show, retries everything; with
    --show <slug>, only that show. Without --all-time, only retries
    episodes that failed within the last ``--window-hours`` hours
    (default 24, matching the auto-resume window)."""
    state = _state()
    if args.all_time:
        sql = "UPDATE episodes SET status='pending', error_text=NULL WHERE status='failed'"
        params: list[Any] = []
    else:
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=args.window_hours)).isoformat()
        sql = (
            "UPDATE episodes SET status='pending', error_text=NULL "
            "WHERE status='failed' AND attempted_at >= ?"
        )
        params = [cutoff]
    if args.show:
        sql += " AND show_slug=?"
        params.append(args.show)
    with state._conn() as c:
        cur = c.execute(sql, params)
        n = cur.rowcount or 0
    print(f"re-queued {n} failed episode(s)")
    return 0


# ────────────────────────────────────────────────────────────────────────
# show management
# ────────────────────────────────────────────────────────────────────────


def _toggle_enabled(slug: str, enabled: bool) -> int:
    wl = _watchlist()
    show = _find_show(wl, slug)
    if not show:
        print(f"unknown slug: {slug}", file=sys.stderr)
        return 2
    show.enabled = enabled
    wl.save(DATA / "watchlist.yaml")
    print(f"{slug}: enabled={enabled}")
    return 0


def cmd_enable(args: argparse.Namespace) -> int:
    return _toggle_enabled(args.slug, True)


def cmd_disable(args: argparse.Namespace) -> int:
    return _toggle_enabled(args.slug, False)


def cmd_remove(args: argparse.Namespace) -> int:
    """Drop a show from the watchlist + mark all its non-done episodes
    'done' so the worker stops picking them up. Transcripts on disk are
    untouched (use ``--purge-state`` to also delete the episode rows)."""
    wl = _watchlist()
    show = _find_show(wl, args.slug)
    if not show:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    if not args.yes:
        try:
            answer = input(f"remove '{args.slug}'? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer != "y":
            print("aborted")
            return 1
    wl.shows = [s for s in wl.shows if s.slug != args.slug]
    wl.save(DATA / "watchlist.yaml")
    state = _state()
    with state._conn() as c:
        if args.purge_state:
            cur = c.execute("DELETE FROM episodes WHERE show_slug=?", (args.slug,))
            print(f"deleted {cur.rowcount or 0} episode row(s)")
        else:
            cur = c.execute(
                "UPDATE episodes SET status='done', priority=0 "
                "WHERE show_slug=? AND status NOT IN ('done')",
                (args.slug,),
            )
            print(f"marked {cur.rowcount or 0} episode(s) as done")
    print(f"removed '{args.slug}' from watchlist")
    return 0


_SHOW_SETTABLE = {
    "enabled": True,
    "language": "de",
    "whisper_prompt": "",
    "output_override": "",
    "youtube_transcript_pref": "",
    "source": "podcast",
    "title": "",
    "rss": "",
    "artwork_url": "",
}


def cmd_set(args: argparse.Namespace) -> int:
    (
        """Set a per-show field. Format: ``set <slug> key=value``. Allowed
    keys: """
        + ", ".join(sorted(_SHOW_SETTABLE))
        + "."
    )
    if "=" not in args.assignment:
        print("expected key=value", file=sys.stderr)
        return 2
    key, _, raw = args.assignment.partition("=")
    key = key.strip()
    if key not in _SHOW_SETTABLE:
        print(f"unsettable key {key!r}; allowed: {sorted(_SHOW_SETTABLE)}", file=sys.stderr)
        return 2
    wl = _watchlist()
    show = _find_show(wl, args.slug)
    if not show:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    try:
        coerced = _coerce_value(_SHOW_SETTABLE[key], raw)
    except ValueError as e:
        print(f"bad value: {e}", file=sys.stderr)
        return 2
    setattr(show, key, coerced)
    wl.save(DATA / "watchlist.yaml")
    print(f"{args.slug}.{key} = {coerced!r}")
    return 0


# ────────────────────────────────────────────────────────────────────────
# feed retry (clear backoff + force-fetch)
# ────────────────────────────────────────────────────────────────────────


def _clear_feed_backoff(state: StateStore, slug: str) -> None:
    state.set_meta(f"feed_fail_count:{slug}", "0")
    state.set_meta(f"feed_backoff_until:{slug}", "")
    state.set_meta(f"feed_health:{slug}", "unknown")
    state.set_meta(f"feed_fail_category:{slug}", "")
    state.set_meta(f"feed_fail_message:{slug}", "")
    state.set_meta(f"feed_fail_at:{slug}", "")


def _record_feed_failure(state: StateStore, slug: str, exc: BaseException) -> None:
    """Persist failure detail for the manual retry-feed/retry-all-feeds
    paths. Mirrors what core.backoff.on_failure does without the
    backoff timer (the user just asked us to retry — don't punish them
    by re-arming a 7-day pause)."""
    from datetime import datetime as _dt
    from datetime import timezone as _tz

    from core.feed_errors import categorize

    state.set_meta(f"feed_health:{slug}", "fail")
    state.set_meta(f"feed_fail_category:{slug}", categorize(exc))
    state.set_meta(f"feed_fail_message:{slug}", str(exc)[:500])
    state.set_meta(f"feed_fail_at:{slug}", _dt.now(_tz.utc).isoformat())


def cmd_retry_feed(args: argparse.Namespace) -> int:
    """Clear backoff for one feed and immediately attempt a fetch. Useful
    after fixing connectivity, a feed-URL change, or DNS issues."""
    wl = _watchlist()
    show = _find_show(wl, args.slug)
    if not show:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    state = _state()
    _clear_feed_backoff(state, args.slug)
    print(f"cleared backoff for {args.slug}; fetching feed…")
    try:
        manifest = build_manifest(show.rss, timeout=30)
    except Exception as e:
        _record_feed_failure(state, args.slug, e)
        print(f"  fetch failed: {e}")
        return 1
    state.set_meta(f"feed_health:{args.slug}", "ok")
    new = 0
    for ep in manifest:
        existing = state.get_episode(ep["guid"])
        state.upsert_episode(
            show_slug=args.slug,
            guid=ep["guid"],
            title=ep["title"],
            pub_date=ep["pubDate"],
            mp3_url=ep["mp3_url"],
        )
        if existing is None:
            new += 1
    print(f"  ok — {len(manifest)} episodes ({new} new)")
    return 0


def cmd_retry_all_feeds(_args: argparse.Namespace) -> int:
    """Clear backoff + retry for every feed currently marked fail."""
    wl = _watchlist()
    state = _state()
    failed = [s for s in wl.shows if (state.get_meta(f"feed_health:{s.slug}") or "") == "fail"]
    if not failed:
        print("no failed feeds")
        return 0
    print(f"retrying {len(failed)} failed feed(s)…")
    rc = 0
    for show in failed:
        _clear_feed_backoff(state, show.slug)
        try:
            manifest = build_manifest(show.rss, timeout=30)
        except Exception as e:
            _record_feed_failure(state, show.slug, e)
            print(f"  ✗ {show.slug}: {e}")
            rc = 1
            continue
        state.set_meta(f"feed_health:{show.slug}", "ok")
        for ep in manifest:
            state.upsert_episode(
                show_slug=show.slug,
                guid=ep["guid"],
                title=ep["title"],
                pub_date=ep["pubDate"],
                mp3_url=ep["mp3_url"],
            )
        print(f"  ✓ {show.slug}: {len(manifest)} episodes")
    return rc


# ────────────────────────────────────────────────────────────────────────
# one-off ingest (file / url / folder) — stdout = GUID(s) for agent chains
# ────────────────────────────────────────────────────────────────────────


def cmd_ingest_file(args: argparse.Namespace) -> int:
    from core.local_source import IngestError, ingest_file

    state = _state()
    try:
        guid = ingest_file(
            Path(args.path),
            show_slug=args.show,
            state=state,
            watchlist_path=DATA / "watchlist.yaml",
            source="local-drop",
            max_duration_hours=_settings().local_max_duration_hours,
        )
    except IngestError as e:
        print(f"ingest failed: {e}", file=sys.stderr)
        return 2
    print(guid)
    return 0


def cmd_ingest_url(args: argparse.Namespace) -> int:
    from core.local_source import IngestError, ingest_url

    try:
        guid = ingest_url(
            args.url,
            show_slug=args.show,
            state=_state(),
            watchlist_path=DATA / "watchlist.yaml",
        )
    except IngestError as e:
        print(f"ingest failed: {e}", file=sys.stderr)
        return 2
    print(guid)
    return 0


def cmd_ingest_folder(args: argparse.Namespace) -> int:
    from core.local_source import ingest_folder

    guids = ingest_folder(
        Path(args.path),
        show_slug=args.show,
        state=_state(),
        watchlist_path=DATA / "watchlist.yaml",
        recursive=args.recursive,
        max_duration_hours=_settings().local_max_duration_hours,
    )
    for g in guids:
        print(g)
    return 0


# ────────────────────────────────────────────────────────────────────────
# watch-folder management
# ────────────────────────────────────────────────────────────────────────


def cmd_watch_add(args: argparse.Namespace) -> int:
    """Enable the watch-folder source and set the root path. v1.3 supports
    a single root via Settings.watch_folder_root; multi-root is follow-up."""
    s = _settings()
    s.watch_folder_enabled = True
    s.watch_folder_root = str(Path(args.path).expanduser().resolve())
    s.save(DATA / "settings.yaml")
    print(f"watch folder: {s.watch_folder_root} (enabled)")
    return 0


def cmd_watch_remove(_args: argparse.Namespace) -> int:
    """Disable the watch-folder source. The root path is preserved on disk
    so re-enabling with `watch add` is not required if the path is unchanged."""
    s = _settings()
    s.watch_folder_enabled = False
    s.save(DATA / "settings.yaml")
    print("watch folder disabled")
    return 0


def cmd_watch_list(args: argparse.Namespace) -> int:
    """Show current watch-folder config (enabled / root / post-action /
    max-duration gate)."""
    s = _settings()
    payload = {
        "enabled": s.watch_folder_enabled,
        "root": str(Path(s.watch_folder_root).expanduser()),
        "post": s.watch_folder_post,
        "max_duration_hours": s.local_max_duration_hours,
    }
    _emit(
        payload,
        as_json=getattr(args, "json", False),
        human=f"{'on' if payload['enabled'] else 'off':3} {payload['root']}",
    )
    return 0


# ────────────────────────────────────────────────────────────────────────
# settings management
# ────────────────────────────────────────────────────────────────────────


def cmd_set_setting(args: argparse.Namespace) -> int:
    """Set a top-level setting in settings.yaml. Type-coerced from the
    Settings model default."""
    s = _settings()
    if not hasattr(s, args.key):
        print(f"unknown setting: {args.key}", file=sys.stderr)
        return 2
    try:
        coerced = _coerce_value(getattr(s, args.key), args.value)
    except ValueError as e:
        print(f"bad value: {e}", file=sys.stderr)
        return 2
    setattr(s, args.key, coerced)
    s.save(DATA / "settings.yaml")
    print(f"{args.key} = {coerced!r}")
    return 0


# ────────────────────────────────────────────────────────────────────────
# entrypoint
# ────────────────────────────────────────────────────────────────────────


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    p = argparse.ArgumentParser(
        prog="paragraphos",
        description="Headless control for Paragraphos. Most inspection commands "
        "support --json for machine-readable output.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    # — existing
    a = sub.add_parser("add", help="add a show by name / RSS / YouTube URL (interactive)")
    a.add_argument("name_or_url")
    a.add_argument("--backlog", required=True, help="all | recent | last:N | since:YYYY-MM-DD")
    a.add_argument("--slug", default=None, help="override the derived slug")
    a.add_argument("--lang", default=None, help="whisper language code (default de)")
    a.add_argument(
        "--yes",
        action="store_true",
        help="non-interactive: accept the first iTunes match / derived slug",
    )
    a.set_defaults(fn=cmd_add)

    s_shows = sub.add_parser("shows", help="list all shows in the watchlist")
    s_shows.add_argument("--json", action="store_true")
    s_shows.set_defaults(fn=cmd_shows)
    # Back-compat alias
    s_list = sub.add_parser("list", help="alias for 'shows'")
    s_list.add_argument("--json", action="store_true")
    s_list.set_defaults(fn=cmd_shows)

    c = sub.add_parser("check", help="refresh feeds + drain queue")
    c.add_argument("--limit", type=int, default=0)
    c.add_argument("--show", type=str, default=None)
    c.set_defaults(fn=cmd_check)

    sub.add_parser("import-feeds", help="bulk-import the curated podcast list").set_defaults(
        fn=cmd_import_feeds
    )

    # — inspection
    s_status = sub.add_parser("status", help="snapshot: queue depth, in-flight, by-status counts")
    s_status.add_argument("--json", action="store_true")
    s_status.set_defaults(fn=cmd_status)

    s_eps = sub.add_parser("episodes", help="list episodes for a show")
    s_eps.add_argument("slug")
    s_eps.add_argument(
        "--status",
        choices=[
            "pending",
            "downloading",
            "downloaded",
            "transcribing",
            "done",
            "failed",
            "stale",
        ],
        default=None,
    )
    s_eps.add_argument("--limit", type=int, default=0)
    s_eps.add_argument("--json", action="store_true")
    s_eps.set_defaults(fn=cmd_episodes)

    s_failed = sub.add_parser("failed", help="list failed episodes (cross-show by default)")
    s_failed.add_argument("--show", type=str, default=None)
    s_failed.add_argument("--limit", type=int, default=0)
    s_failed.add_argument("--json", action="store_true")
    s_failed.set_defaults(fn=cmd_failed)

    s_show = sub.add_parser("show", help="full detail for one show")
    s_show.add_argument("slug")
    s_show.add_argument("--json", action="store_true")
    s_show.set_defaults(fn=cmd_show)

    s_set = sub.add_parser("settings", help="print all settings + recommendations")
    s_set.add_argument("--json", action="store_true")
    s_set.set_defaults(fn=cmd_settings)

    s_fh = sub.add_parser("feed-health", help="per-show feed health + backoff state")
    s_fh.add_argument("--show", type=str, default=None)
    s_fh.add_argument("--json", action="store_true")
    s_fh.set_defaults(fn=cmd_feed_health)

    # — queue control
    sub.add_parser("pause", help="pause the queue").set_defaults(fn=cmd_pause)
    sub.add_parser("resume", help="resume the queue").set_defaults(fn=cmd_resume)
    sub.add_parser("stop", help="force-stop: kill whisper/yt-dlp + recover in-flight").set_defaults(
        fn=cmd_stop
    )
    sub.add_parser("clear-queue", help="mark every pending episode as done").set_defaults(
        fn=cmd_clear_queue
    )

    s_pri = sub.add_parser("priority", help="set an episode's priority")
    s_pri.add_argument("guid")
    s_pri.add_argument("value", type=int)
    s_pri.set_defaults(fn=cmd_priority)

    s_rn = sub.add_parser("run-next", help="bump an episode to priority=100")
    s_rn.add_argument("guid")
    s_rn.set_defaults(fn=cmd_run_next)

    s_rt = sub.add_parser("retranscribe", help="set status=pending + priority=100")
    s_rt.add_argument("guid")
    s_rt.set_defaults(fn=cmd_retranscribe)

    s_rf = sub.add_parser("retry-failed", help="re-queue failed episodes")
    s_rf.add_argument("--show", type=str, default=None)
    s_rf.add_argument("--all-time", action="store_true", help="ignore --window-hours")
    s_rf.add_argument("--window-hours", type=int, default=24)
    s_rf.set_defaults(fn=cmd_retry_failed)

    # — show management
    s_en = sub.add_parser("enable", help="enable a show")
    s_en.add_argument("slug")
    s_en.set_defaults(fn=cmd_enable)

    s_di = sub.add_parser("disable", help="disable a show")
    s_di.add_argument("slug")
    s_di.set_defaults(fn=cmd_disable)

    s_rm = sub.add_parser("remove", help="remove a show from the watchlist")
    s_rm.add_argument("slug")
    s_rm.add_argument("-y", "--yes", action="store_true", help="skip confirmation")
    s_rm.add_argument(
        "--purge-state",
        action="store_true",
        help="also delete the show's episode rows from state.sqlite",
    )
    s_rm.set_defaults(fn=cmd_remove)

    s_se = sub.add_parser(
        "set",
        help="set a per-show field (key=value). Allowed: " + ", ".join(sorted(_SHOW_SETTABLE)),
    )
    s_se.add_argument("slug")
    s_se.add_argument("assignment", help="key=value")
    s_se.set_defaults(fn=cmd_set)

    # — feed retry
    s_rfe = sub.add_parser("retry-feed", help="clear backoff + immediate fetch for one show")
    s_rfe.add_argument("slug")
    s_rfe.set_defaults(fn=cmd_retry_feed)

    sub.add_parser(
        "retry-all-feeds", help="clear backoff + retry every feed marked fail"
    ).set_defaults(fn=cmd_retry_all_feeds)

    # — settings
    s_ss = sub.add_parser("set-setting", help="set a top-level setting in settings.yaml")
    s_ss.add_argument("key")
    s_ss.add_argument("value")
    s_ss.set_defaults(fn=cmd_set_setting)

    # — one-off ingest
    s_ing = sub.add_parser("ingest", help="one-off ingest of a file / URL / folder")
    ing_sub = s_ing.add_subparsers(dest="ingest_what", required=True)

    s_if = ing_sub.add_parser("file", help="ingest one local media file")
    s_if.add_argument("path")
    s_if.add_argument("--show", default=None)
    s_if.set_defaults(fn=cmd_ingest_file)

    s_iu = ing_sub.add_parser("url", help="ingest a URL via yt-dlp generic extractor")
    s_iu.add_argument("url")
    s_iu.add_argument("--show", default=None)
    s_iu.set_defaults(fn=cmd_ingest_url)

    s_ifo = ing_sub.add_parser("folder", help="ingest every supported file in a folder")
    s_ifo.add_argument("path")
    s_ifo.add_argument("--show", default=None)
    s_ifo.add_argument("--recursive", action="store_true", default=True)
    s_ifo.add_argument(
        "--no-recursive",
        dest="recursive",
        action="store_false",
        help="only scan the top-level directory",
    )
    s_ifo.set_defaults(fn=cmd_ingest_folder)

    # — watch-folder source
    s_w = sub.add_parser("watch", help="manage the watch-folder source")
    w_sub = s_w.add_subparsers(dest="watch_cmd", required=True)

    s_wa = w_sub.add_parser("add", help="enable watching + set the root path")
    s_wa.add_argument("path")
    s_wa.set_defaults(fn=cmd_watch_add)

    w_sub.add_parser("remove", help="disable the watcher").set_defaults(fn=cmd_watch_remove)

    s_wl = w_sub.add_parser("list", help="show watch-folder config")
    s_wl.add_argument("--json", action="store_true")
    s_wl.set_defaults(fn=cmd_watch_list)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
