"""Pydantic models for watchlist.yaml and settings.yaml."""

from __future__ import annotations

import re
from pathlib import Path
from typing import List, Literal, Optional

import yaml
from pydantic import BaseModel, Field, field_validator

_TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


class Show(BaseModel):
    slug: str
    title: str
    rss: str
    whisper_prompt: str = ""
    enabled: bool = True
    output_override: Optional[str] = None
    language: str = "de"  # whisper language code; "auto" for per-episode detect
    # Cover art URL (from <itunes:image> or <image>) captured at add / refresh
    # time. Default is empty string for backward compat with existing
    # watchlist.yaml files — ShowDetailsDialog falls back to a 🎙 placeholder
    # when the feed didn't expose artwork.
    artwork_url: str = ""
    # Source discriminator. Values:
    #   podcast       — RSS feed
    #   youtube       — channel RSS at /feeds/videos.xml?channel_id=UC...
    #   local-folder  — a watched folder on disk (rss empty; path in meta)
    #   local-drop    — drag-drop / Import folder one-offs (rss empty)
    #   url           — ad-hoc URL ingest via yt-dlp generic extractor
    # Defaults to "podcast" for backward compat with existing
    # watchlist.yaml files.
    source: str = "podcast"
    # Per-show YouTube transcript preference. Empty string = inherit from
    # Settings default. Otherwise one of: "captions" | "whisper". A legacy
    # "auto-captions" value is still tolerated on read (pipeline routes it
    # down the captions path) but is no longer user-selectable.
    youtube_transcript_pref: str = ""
    # YouTube: skip Shorts on backfill + as a per-video pipeline safety net.
    # Default True. include_shorts on enumeration is the inverse.
    skip_shorts: bool = True
    # ── roadmap additions (all default to a no-op so old YAML loads clean) ──
    # Auto-vocabulary prompt (1.2): when True and no explicit whisper_prompt,
    # seed --prompt from frequent proper nouns mined from past transcripts.
    auto_vocab: bool = False
    # Per-show duration filters (3.3): episodes whose known duration falls
    # outside [min, max] are SKIPPED. 0 = no limit; falls back to the
    # settings-level defaults when 0.
    min_duration_sec: int = 0
    max_duration_sec: int = 0
    # Per-show notification opt-out (7.4): False silences desktop
    # notifications for this show.
    notify: bool = True


class Watchlist(BaseModel):
    shows: List[Show] = Field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> "Watchlist":
        if not path.exists():
            return cls()
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        return cls.model_validate(data)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            yaml.safe_dump(self.model_dump(), allow_unicode=True, sort_keys=False),
            encoding="utf-8",
        )

    def save_atomic(self, path: Path) -> None:
        """Crash-safe write: serialize to a temp file in the same dir, then
        os.replace() (atomic on POSIX) so a reader never sees a half file."""
        import os
        import tempfile

        path.parent.mkdir(parents=True, exist_ok=True)
        data = yaml.safe_dump(self.model_dump(), allow_unicode=True, sort_keys=False)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(data)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


class Settings(BaseModel):
    output_root: str = "~/Desktop/Paragraphos/transcripts"
    daily_check_time: str = "09:00"
    catch_up_missed: bool = True
    # Master switch for the GitHub-release update check — gates BOTH the
    # once-at-startup check and the on-activation re-check. Off → zero
    # GitHub requests (honours the "no telemetry" stance).
    update_check_enabled: bool = True
    # Auto-start queue when the app launches. On by default so opening
    # Paragraphos begins work immediately; turn off if you prefer the
    # queue to sit idle until you click Start.
    auto_start_queue: bool = True
    # Seconds to wait after launch before the auto-start fires. Lets the
    # main window finish painting + the tray icon appear before the queue
    # grabs CPU. Settings UI exposes this next to auto_start_queue.
    auto_start_delay_seconds: int = 5
    notify_on_success: bool = True
    # Flipped True the first time the user completes the first-run setup
    # dialog. Legacy users with customised paths get auto-backfilled on load
    # (see ``backfill_setup_completed``) so the dialog doesn't ambush them.
    setup_completed: bool = False
    mp3_retention_days: int = 7
    delete_mp3_after_transcribe: bool = True
    bandwidth_limit_mbps: int = 0
    # Load management — how hard the machine may be driven by transcription.
    # The level derives concrete whisper-cli parallelism + thread count +
    # macOS scheduling tier (see core/load.py); replaces the former
    # parallel_transcribe / whisper_multiproc knobs.
    load_level: Literal["quiet", "balanced", "full"] = "balanced"
    # Run transcription under a deferential scheduling tier so the Mac stays
    # responsive. Implied for quiet/balanced; at "full" this picks nice
    # (polite, default) vs normal (raw maximum) priority.
    background_priority: bool = True
    # Block E defaults
    obsidian_vault_path: str = ""
    obsidian_vault_name: str = "knowledge-hub"
    export_root: str = "~/Downloads"
    whisper_model: str = "large-v3-turbo"
    log_retention_days: int = 90
    # Performance toggles (Phase 1.5)
    whisper_fast_mode: bool = False  # beam=1/best=1/-ac 0, ~2-3× speedup, lower quality
    rss_concurrency: int = 8  # parallel feed fetches per check
    download_concurrency: int = 4  # parallel MP3 downloads
    download_concurrency_per_host: int = 2
    use_etag_cache: bool = True  # RSS conditional GET
    library_scan_cache: bool = True  # skip re-parse of unchanged .md at startup
    # Phase 3 UX
    notify_mode: str = "per_episode"  # per_episode | daily_summary | off
    # Optional external knowledge-base root (e.g. an Obsidian vault /
    # knowledge-hub repo). When set AND the directory contains
    # raw/.last_compiled, the Shows tab shows a 'N transcripts since last
    # compile' banner. Empty string disables the banner.
    knowledge_hub_root: str = ""
    github_repo: str = "madevmuc/paragraphos"  # override if you forked
    # Output formats — Markdown is always written; SRT is opt-in. Default
    # True so upgraders see no behaviour change on first launch.
    save_srt: bool = True
    # Source filter — at least one must be True. Validated in
    # core.sources.validate_sources(). Default both on for backward
    # compat (existing users keep podcast behaviour).
    sources_podcasts: bool = True
    sources_youtube: bool = True
    # ISO8601 UTC timestamp of last successful `yt-dlp -U` run.
    # Empty string means never run; helper triggers an update if older
    # than 7 days. See ui.main_window.maybe_self_update_ytdlp.
    ytdlp_last_self_update_at: str = ""
    # Default YouTube transcript source for shows that don't override
    # via Show.youtube_transcript_pref. One of: "captions" | "whisper".
    # A legacy "auto-captions" value is still tolerated on read but is no
    # longer user-selectable.
    youtube_default_transcript_source: str = "captions"
    # Default expected caption language (whisper.cpp + yt-dlp lang code)
    # for newly-added YouTube channels. The Add-YouTube dialog seeds the
    # per-show language from this. Default "de" matches the user's
    # German-podcast default; pick "en" if you mostly track English
    # YouTube channels.
    youtube_default_language: str = "de"
    # Global fallback for a YouTube show's Shorts policy: the pipeline uses
    # this when a Show has no own ``skip_shorts`` (e.g. a legacy show written
    # before that field existed). True = exclude Shorts.
    youtube_skip_shorts_default: bool = True
    # Whether the bottom log dock is visible across all pages. Off by
    # default — power-user diagnostic, surfaced by the Logs sidebar
    # entry and the Ctrl+L shortcut for everyone else.
    show_log_dock: bool = False
    # Background connectivity probe (core.connectivity.ConnectivityMonitor).
    # When True, a daemon thread TCP-probes 1.1.1.1/8.8.8.8/youtube.com on a
    # 30 s/5 s cadence; when the network drops, the queue is paused with a
    # banner; when it returns, network-failed episodes from the last
    # ``auto_resume_failed_window_hours`` hours are re-queued automatically.
    # Off-switch for users behind captive portals where the probes are noisy.
    connectivity_monitor_enabled: bool = True
    # How far back (hours) to look for network-failed episodes when
    # auto-resuming after the connection comes back. 24 h covers the
    # overnight / laptop-sleep case without re-running ancient retries.
    auto_resume_failed_window_hours: int = 24
    # Local source ingest (v1.3.0 "universal ingest").
    #
    # ``watch_folder_root`` is expanded via ``Path.expanduser()``; a fresh
    # install keeps the feature off (``enabled=False``) until the user
    # opts in via Settings → Local sources. ``post`` chooses what happens
    # to a watched file after its episode transitions to ``done``:
    # ``keep`` leaves it in place (default, safest), ``move`` relocates it
    # to a sibling ``done/`` folder mirroring any subfolder path, and
    # ``delete`` unlinks it. ``local_max_duration_hours`` gates any ingest
    # (drop, watch, folder-import) — files exceeding it go to Failed with
    # a clear reason. 4 h covers long lectures and most board-meeting
    # recordings without letting an accidentally-queued movie consume a
    # whole afternoon of whisper time.
    watch_folder_enabled: bool = False
    watch_folder_root: str = "~/Paragraphos/to-be-transcribed"
    watch_folder_post: str = "keep"
    local_max_duration_hours: int = 4

    # ── roadmap additions (0.2) — additive, defaults keep old YAML valid ──
    # events / observability
    event_retention_days: int = 90
    # granular notifications (7.4)
    notify_events: dict[str, bool] = Field(
        default_factory=lambda: {
            "episode.transcribed": True,
            "run.finished": True,
            "episode.failed": True,
        }
    )
    notify_quiet_hours_enabled: bool = False
    notify_quiet_hours_start: str = "22:00"
    notify_quiet_hours_end: str = "08:00"
    # webhooks (10.1) — each entry: {events:[..], kind:"command"|"post",
    # target:str, enabled:bool}
    webhooks_enabled: bool = False
    webhooks: list[dict] = Field(default_factory=list)
    # queue ordering (2.5)
    queue_order: Literal["oldest_first", "newest_first", "shortest_first"] = "oldest_first"
    # duration filter defaults (3.3) — 0 = no limit
    default_min_duration_sec: int = 0
    default_max_duration_sec: int = 0
    # caption fallback (3.4)
    caption_fallback_mode: Literal["manual_whisper", "manual_auto_whisper"] = "manual_whisper"
    # confidence marking (1.3)
    confidence_marking_enabled: bool = True
    confidence_threshold: float = 0.5
    # scheduling windows (2.3)
    processing_windows_enabled: bool = False
    processing_windows: list[str] = Field(default_factory=list)  # ["HH:MM-HH:MM", ...]
    # power / battery budget (8.4)
    pause_on_battery: bool = False
    battery_load_level: Literal["quiet", "balanced", "full"] = "quiet"
    # When on, the whole queue is held while the laptop runs on battery (no
    # downloads/transcribes start) and resumes automatically once plugged in.
    # Distinct from pause_on_battery, which only eases the load level.
    pause_queue_on_battery: bool = False
    # parallel transcription cap (2.2) — 1 = serial (safe default)
    transcribe_concurrency: int = 1
    # metal / model auto-pick (8.1)
    whisper_metal_enabled: bool = True
    whisper_model_autopick: bool = False
    # diarization (1.5) — on by default; needs the optional sherpa-onnx backend
    # + models to actually run (otherwise it's a silently-skipped no-op)
    diarization_enabled: bool = True
    # Directory holding segmentation.onnx + embedding.onnx for sherpa-onnx
    # diarization. Empty → resolved to <data_dir>/models/diarize at runtime.
    diarization_model_dir: str = ""
    # disk guard (6.3)
    disk_guard_enabled: bool = True
    disk_guard_min_free_gb: int = 5

    @field_validator("daily_check_time")
    @classmethod
    def _validate_time(cls, v: str) -> str:
        if not _TIME_RE.match(v):
            raise ValueError(f"invalid HH:MM time: {v!r}")
        return v

    @classmethod
    def load(cls, path: Path) -> "Settings":
        if not path.exists():
            # Fresh install — the load_level default ("balanced") is already
            # the responsive default, so no HW seeding is needed. Persist so
            # subsequent loads take the existing-file branch below.
            s = cls()
            try:
                s.save(path)
            except Exception:
                # If we can't persist (e.g. read-only fs in tests), still
                # return the in-memory settings.
                pass
            backfill_setup_completed(s)
            return s
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        _migrate_load_level(data)
        s = cls.model_validate(data)
        backfill_setup_completed(s)
        return s

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            yaml.safe_dump(self.model_dump(), allow_unicode=True, sort_keys=False),
            encoding="utf-8",
        )
        # Announce the change on the bus (no-op when nothing subscribes, e.g.
        # the fresh-install auto-save during load). Import locally to keep the
        # core models import-light and avoid any cycle.
        try:
            from core import events

            events.emit(events.Event(type=events.EventType.SETTINGS_CHANGED, ts=events.now_iso()))
        except Exception:
            pass


def _migrate_load_level(data: dict) -> None:
    """Legacy settings.yaml had parallel_transcribe / whisper_multiproc.
    Map an absent load_level onto a level so upgraders keep a sensible
    profile instead of silently dropping to the default. Unknown legacy
    keys are otherwise ignored by Pydantic (extra='ignore')."""
    if "load_level" in data:
        return
    legacy = data.get("parallel_transcribe")
    if isinstance(legacy, int):
        data["load_level"] = "full" if legacy >= 2 else "balanced"


def backfill_setup_completed(s: Settings) -> None:
    """Legacy users had the setup steps implicitly done through manual
    edits — flip the new ``setup_completed`` flag True so the first-run
    setup dialog doesn't ambush them on upgrade.

    Mutates ``s`` in place; returns ``None``."""
    if s.setup_completed:
        return
    defaults = Settings()
    customised = (
        s.output_root != defaults.output_root
        or s.obsidian_vault_path != defaults.obsidian_vault_path
        or s.knowledge_hub_root != defaults.knowledge_hub_root
    )
    if customised:
        s.setup_completed = True
