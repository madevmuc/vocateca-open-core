"""Shared app state container."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

from core.library import LibraryIndex, start_watching
from core.models import Settings, Watchlist
from core.state import StateStore
from core.watchlist_guard import file_digest, grandfather_existing


@dataclass
class QueueRunState:
    """Live state of the currently running check — shared across all tabs."""

    running: bool = False
    total: int = 0
    done: int = 0
    started_at: Optional[datetime] = None
    avg_sec_per_episode: float = 0.0  # rolling live average (last 10 eps)
    historical_avg_sec: float = 0.0  # fallback before 1st live episode
    last_episode_title: str = ""
    last_episode_show: str = ""
    # Duration-based ETA — summed audio seconds still to transcribe + the
    # realtime factor (wall-clock / audio) for historical runs. Queue ETA
    # = remaining_audio_sec * realtime_factor, which beats "episodes × avg"
    # because shows have wildly different episode lengths.
    remaining_audio_sec: int = 0
    realtime_factor: float = 0.25

    @property
    def effective_avg_sec(self) -> float:
        """Best available estimate per episode — live rolling avg if we have
        one, historical DB average otherwise."""
        return self.avg_sec_per_episode or self.historical_avg_sec

    @property
    def duration_based_eta_sec(self) -> float:
        """Remaining wall-clock time based on pending audio × realtime factor.
        Returns 0 when we have no duration data (falls back to episode-avg)."""
        if self.remaining_audio_sec <= 0 or self.realtime_factor <= 0:
            return 0.0
        return self.remaining_audio_sec * self.realtime_factor


@dataclass
class AppContext:
    data_dir: Path
    settings: Settings
    watchlist: Watchlist
    state: StateStore
    library: LibraryIndex
    queue: QueueRunState = None  # type: ignore[assignment]
    _observer: object = None
    # GitHub-release update info — populated asynchronously by core.updater
    # when a newer version is detected. Used by MainWindow to show an
    # "update available" banner with a Download button.
    update_available_tag: str = ""
    update_available_url: str = ""
    # Content-hash baseline of watchlist.yaml at load time, so later code can
    # detect external edits to the file (see core.watchlist_guard).
    _watchlist_hash: str = ""

    @classmethod
    def load(cls, data_dir: Path) -> "AppContext":
        settings = Settings.load(data_dir / "settings.yaml")
        watchlist = Watchlist.load(data_dir / "watchlist.yaml")
        state = StateStore(data_dir / "state.sqlite")
        state.init_schema()
        state.recover_in_flight()
        # One-time grandfathering of pre-existing shows + baseline content-hash
        # so the new backlog gate never ambushes shows that predate it and we
        # can later detect external edits to watchlist.yaml.
        grandfather_existing(watchlist, state)
        _wl_hash = file_digest(data_dir / "watchlist.yaml")
        cache_path = data_dir / "library_cache.json" if settings.library_scan_cache else None
        library = LibraryIndex(Path(settings.output_root).expanduser(), cache_path=cache_path)
        library.scan()
        observer = start_watching(library)
        return cls(
            data_dir,
            settings,
            watchlist,
            state,
            library,
            queue=QueueRunState(),
            _observer=observer,
            _watchlist_hash=_wl_hash,
        )

    def reload_library(self) -> None:
        if self._observer is not None:
            try:
                self._observer.stop()
                self._observer.join(timeout=2)
            except Exception:
                pass
        cache_path = (
            self.data_dir / "library_cache.json" if self.settings.library_scan_cache else None
        )
        self.library = LibraryIndex(
            Path(self.settings.output_root).expanduser(), cache_path=cache_path
        )
        self.library.scan()
        self._observer = start_watching(self.library)
