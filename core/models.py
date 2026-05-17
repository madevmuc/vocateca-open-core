"""Pydantic models for watchlist.yaml and settings.yaml."""

from __future__ import annotations

import re
from pathlib import Path
from typing import List, Optional

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
    # Settings default. Otherwise one of: "captions" | "whisper" | "auto-captions".
    youtube_transcript_pref: str = ""


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
    parallel_transcribe: int = 1
    # Block E defaults
    obsidian_vault_path: str = ""
    obsidian_vault_name: str = "knowledge-hub"
    export_root: str = "~/Downloads"
    whisper_model: str = "large-v3-turbo"
    log_retention_days: int = 90
    # Performance toggles (Phase 1.5)
    whisper_fast_mode: bool = False  # beam=1/best=1/-ac 0, ~2-3× speedup, lower quality
    whisper_multiproc: int = 1  # whisper-cli -p N file split (1 = off)
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
    # via Show.youtube_transcript_pref. One of:
    # "captions" | "whisper" | "auto-captions".
    youtube_default_transcript_source: str = "captions"
    # Default expected caption language (whisper.cpp + yt-dlp lang code)
    # for newly-added YouTube channels. The Add-YouTube dialog seeds the
    # per-show language from this. Default "de" matches the user's
    # German-podcast default; pick "en" if you mostly track English
    # YouTube channels.
    youtube_default_language: str = "de"
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

    @field_validator("daily_check_time")
    @classmethod
    def _validate_time(cls, v: str) -> str:
        if not _TIME_RE.match(v):
            raise ValueError(f"invalid HH:MM time: {v!r}")
        return v

    @classmethod
    def load(cls, path: Path) -> "Settings":
        if not path.exists():
            # Fresh install — populate HW-aware tuning defaults so the
            # queue-tab tuning-hint banner doesn't immediately shout at
            # brand-new users. Persist so subsequent loads see the values
            # (which then take the existing-file branch below).
            s = cls()
            _apply_hw_defaults(s)
            try:
                s.save(path)
            except Exception:
                # If we can't persist (e.g. read-only fs in tests), still
                # return the populated in-memory settings.
                pass
            backfill_setup_completed(s)
            return s
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        s = cls.model_validate(data)
        backfill_setup_completed(s)
        return s

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            yaml.safe_dump(self.model_dump(), allow_unicode=True, sort_keys=False),
            encoding="utf-8",
        )


def _apply_hw_defaults(s: "Settings") -> None:
    """Populate parallel_transcribe + whisper_multiproc with hardware-
    aware recommendations. Called only on fresh install — saved user
    values are never overwritten."""
    try:
        from core.hw import recommended_multiproc_split, recommended_parallel_workers

        s.parallel_transcribe = recommended_parallel_workers()
        s.whisper_multiproc = recommended_multiproc_split()
    except Exception:
        # HW detect failure — leave generic defaults in place.
        pass


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
