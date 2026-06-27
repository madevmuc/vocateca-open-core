"""Hardware detection + settings recommendations.

Shared between `ui/settings_pane.py` (shows the recommendation) and
`ui/queue_tab.py` (warns when the user's config diverges).
"""

from __future__ import annotations

import subprocess
from typing import Optional


def detect() -> tuple[Optional[float], Optional[int]]:
    """Return (mem_gb, perf_cores). None for either on detect failure."""
    try:
        mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).decode().strip())
        ncpu = int(
            subprocess.check_output(["sysctl", "-n", "hw.perflevel0.physicalcpu"]).decode().strip()
        )
    except Exception:
        return (None, None)
    return (mem_bytes / (1024**3), ncpu)


def recommended_parallel_workers() -> int:
    """Parallel whisper-cli processes (keep 1 core free for UI/OS)."""
    mem_gb, ncpu = detect()
    if mem_gb is None or ncpu is None:
        return 1
    if mem_gb < 16:
        return 1
    if mem_gb <= 32 and ncpu >= 8:
        return 2
    return 3


def recommended_multiproc_split() -> int:
    """whisper-cli -p N — caps at 4 (diminishing returns past 4 on Apple Silicon)."""
    _, ncpu = detect()
    if ncpu is None:
        return 1
    return max(1, min(ncpu // 2, 4))


def recommend_model(*, cores: int, ram_gb: float) -> str:
    """Suggest a whisper model for the machine class (8.1).

    Heuristic by RAM (primary) + core count: plenty of RAM/cores → the fast
    turbo large model; mid machines → medium; small machines → small/base."""
    if ram_gb >= 16 and cores >= 8:
        return "large-v3-turbo"
    if ram_gb >= 8 and cores >= 6:
        return "medium"
    if ram_gb >= 4:
        return "small"
    return "base"
