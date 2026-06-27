"""Disk-space guard (roadmap 6.3).

A pre-flight check before download/transcribe: if free space drops below
``disk_guard_min_free_gb`` the queue is auto-paused (with a banner) so the run
doesn't fill the disk mid-transcribe. Pure helpers here; the worker wires the
auto-pause + banner.
"""

from __future__ import annotations

import shutil
from pathlib import Path

# A transcript + whisper's temp WAV/JSON overhead on top of the audio. Whisper
# decodes to a temp WAV (~10× a compressed MP3) but that's transient; budget a
# conservative ~40% on top of the audio for transcript + working files.
_OVERHEAD_FACTOR = 0.4


def free_gb(path) -> float:
    """Free space at ``path`` in GiB."""
    return shutil.disk_usage(Path(path)).free / 1024**3


def estimate_needed(audio_bytes: int) -> int:
    """Estimate bytes needed to process an episode of ``audio_bytes`` audio."""
    return int(audio_bytes * (1 + _OVERHEAD_FACTOR))


def should_pause(settings, path) -> bool:
    """Whether the queue should auto-pause for low disk (6.3)."""
    if not getattr(settings, "disk_guard_enabled", True):
        return False
    min_gb = int(getattr(settings, "disk_guard_min_free_gb", 5) or 5)
    try:
        return free_gb(path) < min_gb
    except Exception:  # noqa: BLE001 — never let the guard itself crash the run
        return False
