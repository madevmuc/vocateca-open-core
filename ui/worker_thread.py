"""QThread-based runner for the 'Check Now' action.

Two-pass design:

* Pass 1 — refresh feeds concurrently (ThreadPoolExecutor), persist
  manifests, size the queue, and emit ``queue_sized``.
* Pass 2 — two cooperating QThreads drive the per-episode work:
  ``_DownloadPool`` fans out MP3 downloads across ``N`` worker threads
  (``settings.download_concurrency``) subject to a per-host concurrency
  cap (``settings.download_concurrency_per_host``), and pushes
  ``DownloadOutcome``s onto a bounded ``queue.Queue`` that provides
  natural backpressure. ``_TranscribeWorker`` drains the queue and runs
  whisper serially (it is CPU-bound). The two phases overlap so the
  next episode is downloading while the previous one is being
  transcribed.

All outward signals emitted by ``CheckAllThread`` (``progress``,
``queue_sized``, ``episode_done``, ``finished_all``) are preserved exactly
so the existing UI / tray / queue-listener wiring in ``app.py`` and
``ui/shows_tab.py`` keeps working.
"""

from __future__ import annotations

import os
import queue as _queue
import threading
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from PyQt6.QtCore import Qt, QThread, pyqtSignal

from core import events
from core.events import Event, EventType
from core.hw import detect as hw_detect
from core.load import resolve_load_profile
from core.models import Settings, Watchlist
from core.pipeline import (
    DownloadOutcome,
    PipelineContext,
    PipelineResult,
    download_phase,
    process_episode,
    transcribe_phase,
)
from core.rss import build_manifest_with_url, conditional_validators
from core.state import EpisodeStatus, claim_order_by
from core.watchlist_io import save_watchlist

# Sentinel pushed onto the queue to tell the transcribe worker "no more work".
_SHUTDOWN = object()

# Bound per-show per-check so a channel with many parked premieres can't
# hammer yt-dlp by re-probing every deferred video on a single pass.
_DEFERRED_REPROBE_CAP = 25


def show_is_gated(state, slug: str) -> bool:
    """A show is skipped this pass if it is per-show paused OR has no backlog
    decision yet (an externally-added show awaiting the reconcile choice)."""
    from core.watchlist_guard import is_decided

    if state.get_meta(f"show_paused:{slug}") == "1":
        return True
    return not is_decided(state, slug)


class _DownloadPool(QThread):
    """Dispatches `pending` episodes across ``N`` download worker threads.

    The dispatcher is itself a ``QThread`` so the orchestrator can
    ``wait()`` on it exactly like before, but the per-episode work runs
    on plain ``threading.Thread`` workers pulling from a shared input
    queue. A per-host counter (``host_counter`` + ``host_lock``) still
    caps concurrent downloads against the same CDN at ``host_cap`` —
    that used to be trivially satisfied (one download at a time) and now
    actually throttles parallel fan-out across multi-CDN watchlists.

    The first emitted progress line for a show (``# slug``) previously
    relied on serial ordering. With parallel workers we guard the
    "already announced" set with a lock and emit each slug at most once,
    on whichever worker picks it up first.

    End-of-stream handling: each worker decrements a shared
    ``remaining`` counter when it exits; the worker that drops it to
    zero pushes the single ``_SHUTDOWN`` sentinel onto the transcribe
    queue. That keeps the transcribe-side drain logic unchanged (it
    still breaks on exactly one sentinel).

    ``out_q.put()`` blocking on a full queue still provides backpressure
    from the (serial) transcribe phase.
    """

    progress = pyqtSignal(str)

    def __init__(
        self,
        *,
        ctx,
        show_by_slug: dict,
        ep_num_map: dict,
        scope_slugs: list,
        pctx_for,
        out_q,
        host_counter,
        host_lock,
        host_cap: int,
        stop_flag: threading.Event,
        workers: int,
        orphan_guids: list | None = None,
        queue_order: str = "oldest_first",
    ):
        super().__init__()
        self._ctx = ctx
        self._queue_order = queue_order
        self._show_by_slug = show_by_slug  # slug -> Show
        self._ep_num_map = ep_num_map  # guid -> "0042" / "0000"
        self._scope_slugs = list(scope_slugs)  # which shows this pass touches
        # Snapshot of orphan ('downloaded' status at run-start) guids. Without
        # this scoping the orphan-claim path would race with the in-pass
        # staging usage of 'downloaded' (set by download_phase before the
        # transcribe worker drains the queue): a second download worker
        # could re-claim a just-downloaded row as an orphan and push a
        # duplicate outcome, inflating done_idx past total.
        self._orphan_guids = list(orphan_guids or [])
        self._pctx_for = pctx_for  # callable(show) -> PipelineContext
        self._out_q = out_q
        self._host_counter = host_counter
        self._host_lock = host_lock
        self._host_cap = max(int(host_cap or 1), 1)
        self._stop = stop_flag
        self._n_workers = max(int(workers or 1), 1)

        # Shared dispatcher state.
        self._announced: set[str] = set()
        self._announced_lock = threading.Lock()
        self._remaining_lock = threading.Lock()
        self._remaining = self._n_workers
        # Single SQLite writer-claim lock — UPDATE…RETURNING is atomic at
        # the SQL level but we serialise the Python-side claim too so we
        # never burn cycles racing on the writer lock.
        self._claim_lock = threading.Lock()

    def _claim_next_processable(self) -> tuple[dict, str] | None:
        """Atomically claim the highest-priority processable episode.

        Returns ``(row, prior_status)`` or None when nothing is left.

        Two states are claimable:

        * ``pending`` — never started. Marked ``downloading`` on claim;
          the worker runs download_phase + transcribe.
        * ``downloaded`` — file on disk but transcribe never ran. This
          is the orphan-state left by app crashes / forced quits between
          download_phase and the in-memory _out_q drain by the
          TranscribeWorker. With the old code these rows sat forever
          because nothing claimed them. Marked ``transcribing`` on
          claim; the worker skips download_phase and pushes a synthetic
          DownloadOutcome so transcribe_phase runs against the existing
          mp3 on disk. Restores 'Run next/now' semantics for episodes
          that completed download but were stranded.

        Pending wins over downloaded at the same priority because
        downloading can run in parallel with transcribing — keeps both
        stages busy. Within each, ordered by priority DESC then
        pub_date ASC.
        """
        if not self._scope_slugs:
            return None
        placeholders = ",".join("?" for _ in self._scope_slugs)
        # Two-step claim: try pending first (cheapest path forward),
        # fall back to downloaded (orphan recovery). Each step is a
        # single atomic UPDATE…RETURNING.
        order_by = claim_order_by(self._queue_order)
        with self._claim_lock, self._ctx.state._conn() as c:
            row = c.execute(
                "UPDATE episodes SET status='downloading' "
                "WHERE guid = ("
                "  SELECT guid FROM episodes "
                f"  WHERE status='pending' AND show_slug IN ({placeholders}) "
                f"  ORDER BY {order_by} LIMIT 1"
                ") "
                "RETURNING *",
                tuple(self._scope_slugs),
            ).fetchone()
            if row is not None:
                return dict(row), "pending"
            # Orphan branch: only claim rows that were ALREADY 'downloaded'
            # at run-start (the snapshot in _orphan_guids). Without this
            # filter the branch races with the in-pass staging usage of
            # 'downloaded' (set by download_phase between download and the
            # transcribe-worker dequeue) — a second download worker would
            # see those rows and re-push a synthetic outcome, double-emitting
            # episode_done past `total`.
            if not self._orphan_guids:
                return None
            orphan_phs = ",".join("?" for _ in self._orphan_guids)
            row = c.execute(
                "UPDATE episodes SET status='transcribing' "
                "WHERE guid = ("
                "  SELECT guid FROM episodes "
                f"  WHERE status='downloaded' AND show_slug IN ({placeholders}) "
                f"    AND guid IN ({orphan_phs}) "
                "  ORDER BY priority DESC, pub_date ASC LIMIT 1"
                ") "
                "RETURNING *",
                tuple(self._scope_slugs) + tuple(self._orphan_guids),
            ).fetchone()
            if row is not None:
                return dict(row), "downloaded"
        return None

    def _acquire_host_slot(self, host: str) -> bool:
        """Wait (sleeping briefly) until the host has a free slot.

        Returns False if stop was requested while waiting. Called from
        plain ``threading.Thread`` workers, so we sleep on the stop
        event rather than calling ``QThread.msleep``.
        """
        while True:
            if self._stop.is_set():
                return False
            with self._host_lock:
                if self._host_counter[host] < self._host_cap:
                    self._host_counter[host] += 1
                    return True
            # Wake early if stop is set.
            if self._stop.wait(0.1):
                return False

    def _release_host_slot(self, host: str) -> None:
        with self._host_lock:
            self._host_counter[host] = max(0, self._host_counter[host] - 1)

    def _announce_show(self, slug: str) -> None:
        with self._announced_lock:
            if slug in self._announced:
                return
            self._announced.add(slug)
        self.progress.emit(f"# {slug}")

    def _worker_loop(self) -> None:
        try:
            while True:
                if self._stop.is_set():
                    self.progress.emit("stopped between episodes")
                    return
                # Claim the highest-priority processable episode. New
                # priority bumps take effect on the very next claim.
                claimed = self._claim_next_processable()
                if claimed is None:
                    return
                ep, prior_status = claimed
                show = self._show_by_slug.get(ep["show_slug"])
                if show is None:
                    # Show no longer in scope (deleted mid-pass). Reset
                    # status so we don't leave it stuck in 'downloading'.
                    self._ctx.state.set_status(ep["guid"], EpisodeStatus.PENDING)
                    continue
                ep_num = self._ep_num_map.get(ep["guid"], "0000")

                self._announce_show(show.slug)

                pctx = self._pctx_for(show)

                # ── Orphan-recovery path ─────────────────────────────
                # Episode was already downloaded by an earlier pass that
                # crashed before transcribe ran. Skip download_phase and
                # synthesise a DownloadOutcome from the on-disk file so
                # the transcribe worker picks it up. If the file is
                # missing (cleaned up, retention pruned), fall back to
                # the normal pending path by resetting status.
                if prior_status == "downloaded":
                    from core.pipeline import build_slug

                    show_dir = pctx.output_root / show.slug
                    # Prefer the persisted mp3_path (set by download_phase
                    # 2026-04-23+); fall back to slug-rebuild for legacy
                    # rows downloaded before the column was wired. If
                    # neither exists, glob the audio dir as a last-resort
                    # — covers the case where the original ep_num is
                    # unknown to this run.
                    persisted = (ep.get("mp3_path") or "").strip()
                    mp3_path = Path(persisted) if persisted else None
                    if mp3_path is None or not mp3_path.exists():
                        guess_slug = build_slug(ep["pub_date"], ep["title"], ep_num)
                        cand = show_dir / "audio" / f"{guess_slug}.mp3"
                        if cand.exists():
                            mp3_path = cand
                        else:
                            # Glob: same date prefix + same title suffix,
                            # any episode_number in between. Catches the
                            # downloaded-with-real-ep-num / orphan-recovery-
                            # rebuilds-with-0000 mismatch.
                            from core.sanitize import slugify as _slugify

                            date_prefix = (ep["pub_date"] or "")[:10]
                            title_part = _slugify(ep["title"] or "")[:60]
                            audio_dir = show_dir / "audio"
                            if audio_dir.is_dir():
                                hits = sorted(audio_dir.glob(f"{date_prefix}_*.mp3"))
                                # Prefer matches that also contain the title's
                                # leading slug fragment so two episodes from
                                # the same date don't get crossed.
                                titled = [
                                    p for p in hits if title_part and title_part[:20] in p.name
                                ]
                                hit = (titled or hits)[0] if (titled or hits) else None
                                if hit is not None:
                                    mp3_path = hit
                                    # Backfill the persisted path so the next
                                    # orphan-recovery doesn't have to glob.
                                    self._ctx.state.set_mp3_path(ep["guid"], str(mp3_path))
                    if mp3_path is None or not mp3_path.exists():
                        self._ctx.state.set_status(ep["guid"], EpisodeStatus.PENDING)
                        continue
                    # Slug derived from the actual filename so transcribe
                    # writes <slug>.md / .srt next to a consistent name.
                    slug = mp3_path.stem
                    self.progress.emit(f"  ↻ {ep['title'][:80]} (orphan → transcribe)")
                    self._out_q.put(
                        (
                            show,
                            ep,
                            DownloadOutcome(
                                guid=ep["guid"],
                                mp3_path=mp3_path,
                                show_dir=show_dir,
                                slug=slug,
                                ep=ep,
                            ),
                        )
                    )
                    continue

                # YouTube source-dispatch: the standard download path
                # would fetch the watch URL as if it were an MP3 enclosure
                # → text/html → "refusing non-audio Content-Type". Route
                # YouTube items through the captions-first / whisper-
                # fallback pipeline instead and synthesise a
                # DownloadOutcome carrying the terminal result so the
                # downstream transcribe worker just records it.
                if getattr(pctx, "source", "podcast") == "youtube":
                    self.progress.emit(f"  ⮕ {ep['title'][:80]} (youtube)")
                    try:
                        result = process_episode(ep["guid"], pctx, episode_number=ep_num)
                    except Exception as e:  # noqa: BLE001
                        result = PipelineResult("failed", ep["guid"], str(e))
                    self._out_q.put((show, ep, DownloadOutcome(guid=ep["guid"], result=result)))
                    continue

                # Podcast path — same as before, with per-host throttling.
                host = urlparse(ep["mp3_url"]).netloc or "?"
                if not self._acquire_host_slot(host):
                    return
                try:
                    self.progress.emit(f"  ↓ {ep['title'][:80]}")
                    outcome: DownloadOutcome = download_phase(
                        ep["guid"], pctx, episode_number=ep_num
                    )
                finally:
                    self._release_host_slot(host)

                # Attach show/ep metadata the transcribe worker needs
                # for progress reporting (episode_done payload).
                self._out_q.put((show, ep, outcome))
        finally:
            # Only the last download-worker standing pushes end-of-stream
            # sentinels — one per transcribe consumer (set externally as
            # `consumer_count`, default 1 for backward compat). Multiple
            # transcribe workers each block on `in_q.get()`; each needs
            # its own sentinel to exit cleanly.
            with self._remaining_lock:
                self._remaining -= 1
                last = self._remaining == 0
            if last:
                for _ in range(getattr(self, "consumer_count", 1)):
                    self._out_q.put(_SHUTDOWN)

    def run(self) -> None:
        # No pre-priming: workers claim from DB on each iteration so a
        # mid-pass priority bump (Run next / Run now) takes effect
        # immediately on the next claim.
        threads: list[threading.Thread] = []
        for i in range(self._n_workers):
            t = threading.Thread(
                target=self._worker_loop,
                name=f"dl-worker-{i}",
                daemon=True,
            )
            t.start()
            threads.append(t)

        for t in threads:
            t.join()


class _TranscribeWorker(QThread):
    """Consumes ``DownloadOutcome``s and runs whisper sequentially.

    Emits ``episode_done`` with exactly the same 7-tuple the old serial
    code emitted — UI consumers don't know there's a new pipeline.
    """

    progress = pyqtSignal(str)
    # slug, guid, action, done_idx, total_pending, show_title, ep_title
    episode_done = pyqtSignal(str, str, str, int, int, str, str)

    def __init__(
        self,
        *,
        in_q,
        pctx_for,
        total: int,
        stop_flag: threading.Event,
        done_counter: list | None = None,
        done_lock: threading.Lock | None = None,
    ):
        super().__init__()
        self._in_q = in_q
        self._pctx_for = pctx_for
        self._total = total
        self._stop = stop_flag
        # Shared atomic counter so N parallel workers report a coherent
        # done_idx to the UI. List wrapper because ints are immutable;
        # lock guards the increment so no two workers ever emit the
        # same index. Default to a private counter for backwards-compat
        # with single-worker callers.
        self._done_counter = done_counter if done_counter is not None else [0]
        self._done_lock = done_lock if done_lock is not None else threading.Lock()

    def run(self) -> None:
        while True:
            # A timeout-based get so we periodically notice stop_flag even
            # when the download side is stuck.
            try:
                item = self._in_q.get(timeout=0.5)
            except _queue.Empty:
                if self._stop.is_set():
                    break
                continue
            if item is _SHUTDOWN:
                break

            show, ep, outcome = item

            if outcome.result is not None:
                # Terminal already (skipped via dedup, or download failed).
                r: PipelineResult = outcome.result
            else:
                self.progress.emit(f"  → {ep['title'][:80]}")
                pctx = self._pctx_for(show)
                try:
                    r = transcribe_phase(outcome, pctx)
                except Exception as e:  # defensive — transcribe_phase
                    # should turn errors into PipelineResult, but guard.
                    r = PipelineResult("failed", outcome.guid, str(e))

            with self._done_lock:
                self._done_counter[0] += 1
                done_idx = self._done_counter[0]
            if r.action == "failed":
                self.progress.emit(f"    [{r.action}]")
                for line in r.detail.splitlines():
                    self.progress.emit(f"        {line}")
            else:
                self.progress.emit(f"    [{r.action}] {r.detail[:160]}")
            self.episode_done.emit(
                show.slug,
                ep["guid"],
                r.action,
                done_idx,
                self._total,
                show.title,
                ep["title"],
            )

            if self._stop.is_set():
                # Drain without processing further work items, but keep
                # reading until the sentinel so the download worker can
                # exit cleanly.
                while True:
                    try:
                        nxt = self._in_q.get(timeout=0.5)
                    except _queue.Empty:
                        continue
                    if nxt is _SHUTDOWN:
                        return


class CheckAllThread(QThread):
    progress = pyqtSignal(str)
    # slug, guid, action, done_idx, total_pending, show_title, ep_title
    episode_done = pyqtSignal(str, str, str, int, int, str, str)
    queue_sized = pyqtSignal(int)
    finished_all = pyqtSignal()
    pause_state_changed = pyqtSignal()  # Pause pressed mid-run (drain begins)

    def __init__(
        self,
        ctx,
        settings: Settings,
        *,
        only_slug: str | None = None,
        limit: int = 0,
        force: bool = False,
    ):
        super().__init__()
        self.ctx = ctx
        self.settings = settings
        # Resolve the load-management profile once per run — it drives the
        # transcribe worker count, the whisper -t thread count, and the macOS
        # scheduling tier (see core/load.py). detect() shells out to sysctl,
        # so do it once here rather than per-episode.
        _mem, _perf = hw_detect()
        self._load_profile = resolve_load_profile(
            self.settings.load_level,
            perf_cores=_perf or (os.cpu_count() or 4),
            background_priority=self.settings.background_priority,
        )
        self.only_slug = only_slug
        self.limit = limit
        # force=True bypasses the per-feed backoff filter in pass 1a so a
        # user-initiated Start click can retry a parked feed immediately.
        # Scheduler / background callers leave this False so the 1/3/7-day
        # backoff still protects against hammering broken feeds.
        self.force = force
        self._stop = False
        self._stop_event = threading.Event()

    def request_stop(self) -> None:
        self._stop = True
        self._stop_event.set()

    def _resolve_prompt(self, show) -> str:
        """Effective whisper prompt: manual wins, else auto-vocab (1.2), else ""."""
        from core import vocab

        output_root = Path(self.settings.output_root).expanduser()
        show_dir = (
            Path(show.output_override).expanduser()
            if getattr(show, "output_override", None)
            else output_root / show.slug
        )

        def _read_transcripts() -> list[str]:
            texts: list[str] = []
            try:
                mds = sorted(show_dir.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)[
                    :30
                ]
            except Exception:
                return texts
            for p in mds:
                try:
                    texts.append(p.read_text(encoding="utf-8", errors="replace"))
                except OSError:
                    pass
            return texts

        auto_vocab = bool(getattr(show, "auto_vocab", False))
        count = 0
        if auto_vocab and not (show.whisper_prompt or "").strip():
            count = len(self.ctx.state.list_by_status(show.slug, EpisodeStatus.DONE))
        return vocab.resolve_whisper_prompt(
            whisper_prompt=show.whisper_prompt or "",
            auto_vocab=auto_vocab,
            slug=show.slug,
            state=self.ctx.state,
            transcript_count=count,
            build=_read_transcripts,
        )

    def _pctx_for(self, show) -> PipelineContext:
        """Build a PipelineContext customised for a specific show."""
        kwargs = dict(
            state=self.ctx.state,
            library=self.ctx.library,
            output_root=Path(self.settings.output_root).expanduser(),
            whisper_prompt=self._resolve_prompt(show),
            retention_days=self.settings.mp3_retention_days,
            delete_mp3_after=self.settings.delete_mp3_after_transcribe,
            language=show.language,
            model_name=self.settings.whisper_model,
            fast_mode=self.settings.whisper_fast_mode,
            processors=1,  # whisper_multiproc retired; level controls load
            threads=self._load_profile.threads,
            launch_prefix=tuple(self._load_profile.command_prefix()),
            save_srt=self.settings.save_srt,
            confidence_marking=bool(getattr(self.settings, "confidence_marking_enabled", False)),
            confidence_threshold=float(getattr(self.settings, "confidence_threshold", 0.5)),
        )
        from core.filters import resolve_duration_bounds

        emin, emax = resolve_duration_bounds(
            show_min=int(getattr(show, "min_duration_sec", 0) or 0),
            show_max=int(getattr(show, "max_duration_sec", 0) or 0),
            def_min=int(getattr(self.settings, "default_min_duration_sec", 0) or 0),
            def_max=int(getattr(self.settings, "default_max_duration_sec", 0) or 0),
        )
        kwargs["min_duration_sec"] = emin
        kwargs["max_duration_sec"] = emax
        if getattr(show, "source", "podcast") == "youtube":
            # Pull the channel id straight off the canonical channel-RSS URL
            # (`…?channel_id=UC…`). The Watchlist always stores YouTube shows
            # with this exact RSS shape, but defend against malformed input
            # by falling back to "" — the pipeline's youtube branch will then
            # raise rather than silently mis-route to the podcast path.
            channel_id = ""
            try:
                qs = parse_qs(urlparse(show.rss).query)
                channel_id = (qs.get("channel_id") or [""])[0]
            except Exception:
                pass
            kwargs["source"] = "youtube"
            kwargs["youtube_channel_id"] = channel_id
            kwargs["youtube_transcript_pref"] = getattr(show, "youtube_transcript_pref", "") or ""
            kwargs["youtube_default_transcript_source"] = getattr(
                self.settings, "youtube_default_transcript_source", "captions"
            )
            kwargs["caption_fallback_mode"] = getattr(
                self.settings, "caption_fallback_mode", "manual_whisper"
            )
            # Per-show Shorts policy: prefer the show's own skip_shorts, else
            # the global Settings default. The getattr fallbacks keep legacy
            # shows/settings (written before these fields existed) working.
            kwargs["skip_shorts"] = bool(
                getattr(
                    show,
                    "skip_shorts",
                    getattr(self.settings, "youtube_skip_shorts_default", True),
                )
            )
        return PipelineContext(**kwargs)

    def _reprobe_deferred(self, show) -> int:
        """Re-classify a youtube show's DEFERRED episodes; promote any that are
        no longer live/premiere back to PENDING so this same check processes
        them. Bounded by _DEFERRED_REPROBE_CAP per call. Returns promoted count."""
        if getattr(show, "source", "podcast") != "youtube":
            return 0
        from core.youtube import parse_youtube_url
        from core.youtube_audio import probe_video_meta
        from core.youtube_classify import classify_video

        deferred = self.ctx.state.list_by_status(show.slug, EpisodeStatus.DEFERRED)
        promoted = 0
        for ep in deferred[:_DEFERRED_REPROBE_CAP]:
            if self._stop:
                break
            try:
                parsed = parse_youtube_url(ep["mp3_url"])
                if parsed.kind != "video":
                    continue
                meta = probe_video_meta(parsed.value)
            except Exception:  # noqa: BLE001 — leave deferred; retry next check
                continue
            category, _msg = classify_video(meta)
            if category != "live":
                self.ctx.state.set_status(ep["guid"], EpisodeStatus.PENDING)
                promoted += 1
        if promoted:
            self.progress.emit(f"{show.slug}: {promoted} deferred video(s) now ready")
        return promoted

    def _finish(self) -> None:
        """Emit the run.finished event then the Qt finished signal."""
        events.emit(Event(type=EventType.RUN_FINISHED, ts=events.now_iso()))
        self.finished_all.emit()

    def run(self) -> None:
        wl: Watchlist = self.ctx.watchlist
        targets = [
            s for s in wl.shows if s.enabled and (not self.only_slug or s.slug == self.only_slug)
        ]
        events.emit(
            Event(
                type=EventType.RUN_STARTED,
                ts=events.now_iso(),
                payload={"scope": self.only_slug or "all", "shows": len(targets)},
            )
        )

        # Respect a persisted "paused" flag — if set, bail out cleanly.
        if self.ctx.state.get_meta("queue_paused") == "1":
            self.progress.emit("queue is paused — click Resume in Shows tab")
            self._finish()
            return

        from core import backoff

        # Pass 1a: filter out skipped shows, then fetch feeds concurrently.
        fetch_targets = []
        for show in targets:
            if self._stop:
                break
            if not self.force and backoff.in_backoff(self.ctx.state, show.slug):
                self.progress.emit(f"skip {show.slug} (in backoff after repeated feed failures)")
                continue
            if show_is_gated(self.ctx.state, show.slug):
                self.progress.emit(f"skip {show.slug} (paused or backlog undecided)")
                continue
            fetch_targets.append(show)

        fetch_results: dict[str, tuple] = {}
        max_workers = min(max(int(self.settings.rss_concurrency or 1), 1), 16)
        if fetch_targets:
            with ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="rss") as ex:
                future_to_show = {}
                for show in fetch_targets:
                    if self._stop:
                        break
                    stored_etag, stored_modified = conditional_validators(
                        self.ctx.state.get_meta(f"feed_etag:{show.slug}"),
                        self.ctx.state.get_meta(f"feed_modified:{show.slug}"),
                        use_cache=bool(getattr(self.settings, "use_etag_cache", True)),
                    )
                    future_to_show[
                        ex.submit(
                            build_manifest_with_url,
                            show.rss,
                            timeout=60,
                            etag=stored_etag,
                            modified=stored_modified,
                        )
                    ] = show
                for f in as_completed(future_to_show):
                    show = future_to_show[f]
                    if self._stop:
                        continue
                    try:
                        canonical, manifest, new_etag, new_modified = f.result()
                    except Exception as e:
                        fails = backoff.on_failure(self.ctx.state, show.slug, exc=e)
                        self.progress.emit(f"feed error {show.slug} (fail #{fails}): {e}")
                        events.emit(
                            Event(
                                type=EventType.FEED_ERROR,
                                ts=events.now_iso(),
                                show_slug=show.slug,
                                payload={"error": str(e), "fails": fails},
                            )
                        )
                        continue
                    backoff.on_success(self.ctx.state, show.slug)
                    if manifest is None:
                        # 304 Not Modified — feed unchanged. The DB may
                        # still hold pending episodes from an earlier run;
                        # pass 1b picks those up via list_by_status(PENDING).
                        self.progress.emit(f"{show.slug}: feed unchanged")
                        events.emit(
                            Event(
                                type=EventType.FEED_UNCHANGED,
                                ts=events.now_iso(),
                                show_slug=show.slug,
                            )
                        )
                        fetch_results[show.slug] = (show, canonical, None)
                        continue
                    events.emit(
                        Event(
                            type=EventType.FEED_CHECKED,
                            ts=events.now_iso(),
                            show_slug=show.slug,
                            payload={"episodes": len(manifest)},
                        )
                    )
                    if new_etag:
                        self.ctx.state.set_meta(f"feed_etag:{show.slug}", new_etag)
                    if new_modified:
                        self.ctx.state.set_meta(f"feed_modified:{show.slug}", new_modified)
                    fetch_results[show.slug] = (show, canonical, manifest)

        # Pass 1b: persist redirects, upsert episodes, gather pending.
        from core.stats import _parse_duration as _pd

        all_pending: list[tuple] = []
        for show in fetch_targets:
            if self._stop:
                break
            res = fetch_results.get(show.slug)
            if res is None:
                continue
            _, canonical, manifest = res
            if canonical and canonical != show.rss:
                self.progress.emit(f"feed moved: {show.rss} → {canonical} — updating watchlist")
                show.rss = canonical
                save_watchlist(self.ctx)
            # manifest is None on a 304 — skip the upsert pass (nothing new
            # to add) but still collect existing pending episodes below.
            if manifest is not None:
                for ep in manifest:
                    self.ctx.state.upsert_episode(
                        show_slug=show.slug,
                        guid=ep["guid"],
                        title=ep["title"],
                        pub_date=ep["pubDate"],
                        mp3_url=ep["mp3_url"],
                        duration_sec=_pd(ep.get("duration", "")),
                    )
                ep_num_map = {e["guid"]: e["episode_number"] for e in manifest}
            else:
                ep_num_map = {}
            # Re-probe parked live/premiere videos: any that have finished get
            # promoted to PENDING *before* we gather pending below, so a
            # just-finished stream is picked up by this very pass.
            self._reprobe_deferred(show)
            pending = self.ctx.state.list_by_status(show.slug, EpisodeStatus.PENDING)
            if self.limit:
                pending = pending[-self.limit :]
            for ep in pending:
                all_pending.append((show, ep_num_map.get(ep["guid"], "0000"), ep))

        # Cross-show priority sort: a 'Run next' / 'Run now' bump on an
        # episode in show X must actually run next, even if show X comes
        # later in the per-show iteration order. Sort by:
        #   priority DESC (10 = run-now > 5 = run-next > 0 = normal)
        #   pub_date ASC (oldest first within same priority — matches the
        #                 per-show fetch order so behaviour stays
        #                 consistent for non-bumped queues).
        all_pending.sort(
            key=lambda triple: (
                -int(triple[2].get("priority") or 0),
                triple[2].get("pub_date") or "",
            )
        )

        # Count orphaned `downloaded` rows too — these are episodes whose
        # download completed in a prior pass but whose transcribe was lost
        # (app crash / SIGKILL between out_q.put and TranscribeWorker
        # drain). They need to be processed this pass via the worker's
        # orphan-recovery path. Without counting them here, total=0 +
        # we'd skip the pipeline entirely for the recovery case.
        scope_target_slugs = [s.slug for s in fetch_targets]
        orphan_guids: list[str] = []
        if scope_target_slugs:
            placeholders = ",".join("?" for _ in scope_target_slugs)
            with self.ctx.state._conn() as c:
                rows = c.execute(
                    f"SELECT guid FROM episodes "
                    f"WHERE status='downloaded' AND show_slug IN ({placeholders})",
                    tuple(scope_target_slugs),
                ).fetchall()
                orphan_guids = [r["guid"] for r in rows]
        orphan_count = len(orphan_guids)

        total = len(all_pending) + orphan_count
        self.queue_sized.emit(total)
        events.emit(
            Event(
                type=EventType.QUEUE_SIZED,
                ts=events.now_iso(),
                payload={"total": total, "pending": len(all_pending), "orphan": orphan_count},
            )
        )
        self.progress.emit(
            f"queue sized: {len(all_pending)} pending + {orphan_count} orphan-downloaded"
        )

        if total == 0 or self._stop:
            self._finish()
            return

        # Check the persisted pause flag one more time before kicking
        # off the pipeline (matches pre-existing behaviour).
        if self.ctx.state.get_meta("queue_paused") == "1":
            self.progress.emit("queue paused mid-run — halting before pipeline")
            self._finish()
            return

        # Disk guard (6.3): if free space is below the threshold, auto-pause the
        # queue rather than filling the disk mid-transcribe.
        from core import diskguard

        if diskguard.should_pause(self.settings, Path(self.settings.output_root).expanduser()):
            self.ctx.state.set_meta("queue_paused", "1")
            free = diskguard.free_gb(Path(self.settings.output_root).expanduser())
            self.progress.emit(
                f"⚠ low disk: {free:.1f} GB free — queue auto-paused "
                f"(guard {self.settings.disk_guard_min_free_gb} GB)"
            )
            self._finish()
            return

        # Pass 2: parallel download + transcribe.
        dl_conc = max(int(self.settings.download_concurrency or 1), 1)
        host_cap = max(int(self.settings.download_concurrency_per_host or 1), 1)
        host_counter: defaultdict[str, int] = defaultdict(int)
        host_lock = threading.Lock()
        q: _queue.Queue = _queue.Queue(maxsize=dl_conc)

        # Build slug→Show + guid→ep_num maps so the DB-claim loop can
        # rehydrate the per-show context without re-querying the watchlist.
        # Use ALL fetch_targets (not just shows with pending) so the
        # orphan-downloaded recovery path can claim from any in-scope
        # show that has stranded `downloaded` rows.
        show_by_slug = {s.slug: s for s in fetch_targets}
        ep_num_map = {triple[2]["guid"]: triple[1] for triple in all_pending}
        scope_slugs = list(show_by_slug.keys())

        dl = _DownloadPool(
            ctx=self.ctx,
            show_by_slug=show_by_slug,
            ep_num_map=ep_num_map,
            scope_slugs=scope_slugs,
            pctx_for=self._pctx_for,
            out_q=q,
            host_counter=host_counter,
            host_lock=host_lock,
            host_cap=host_cap,
            stop_flag=self._stop_event,
            workers=dl_conc,
            orphan_guids=orphan_guids,
            queue_order=getattr(self.settings, "queue_order", "oldest_first"),
        )
        # Spawn the load profile's transcribe-worker count (default 1).
        # Pre-2026-04-23 only one was created regardless of the setting,
        # so users on a multi-worker level saw a single transcribing
        # row at a time despite paying the configuration cost. All
        # workers share the same in_q (queue.Queue is thread-safe) and
        # the same stop_event; shutdown sends N _SHUTDOWN sentinels via
        # the download pool's existing terminator (one per consumer).
        n_tr = max(self._load_profile.parallel, 1)
        # Shared atomic counter so the UI sees a coherent done_idx
        # across all parallel workers (workers race to increment).
        shared_done_counter = [0]
        shared_done_lock = threading.Lock()
        trs = [
            _TranscribeWorker(
                in_q=q,
                pctx_for=self._pctx_for,
                total=total,
                stop_flag=self._stop_event,
                done_counter=shared_done_counter,
                done_lock=shared_done_lock,
            )
            for _ in range(n_tr)
        ]
        # Tell the download pool how many sentinels to enqueue at end-of-
        # work so every consumer gets one and exits cleanly. Set as an
        # attribute the pool will read in its terminator (added below).
        dl.consumer_count = n_tr
        # Re-emit child signals on this thread so existing wiring stays
        # valid. CRITICAL: DirectConnection. The default AutoConnection
        # would be Queued (child workers and CheckAllThread run on
        # different QThreads), but CheckAllThread.run() is pure Python
        # without a QEventLoop.exec() — queued delivery never fires, so
        # the re-emits would be silently dropped. `.emit()` is thread-
        # safe regardless of which thread invokes it.
        dl.progress.connect(self.progress.emit, type=Qt.ConnectionType.DirectConnection)
        for tr in trs:
            tr.progress.connect(self.progress.emit, type=Qt.ConnectionType.DirectConnection)
            tr.episode_done.connect(self.episode_done.emit, type=Qt.ConnectionType.DirectConnection)

        # Poll the persisted pause flag from a short helper thread — when
        # set we trip the shared stop event, draining both workers.
        pause_watch_stop = threading.Event()

        def _watch_pause():
            while not pause_watch_stop.is_set():
                if self.ctx.state.get_meta("queue_paused") == "1":
                    self.progress.emit("queue paused mid-run — halting between episodes")
                    self._stop_event.set()
                    return
                pause_watch_stop.wait(1.0)

        pw = threading.Thread(target=_watch_pause, name="pause-watch", daemon=True)
        pw.start()

        dl.start()
        for tr in trs:
            tr.start()
        dl.wait()
        for tr in trs:
            tr.wait()
        pause_watch_stop.set()

        self._finish()
