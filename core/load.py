"""Load-management profiles — map a user-facing background-load level to
concrete whisper-cli launch parameters (parallelism, threads, macOS
scheduling tier).

Pure + dependency-free so it unit-tests without touching hardware. The
caller (ui/worker_thread.py) supplies the detected performance-core count;
core/hw.py does the detection. macOS scheduling tiers are applied as an
argv prefix on the whisper-cli command (thread-safe — no preexec_fn).

Design: docs/plans/2026-06-25-load-management-design.md
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

LoadLevel = Literal["quiet", "balanced", "full"]
Qos = Literal["background", "nice", "normal"]


@dataclass(frozen=True)
class LoadProfile:
    parallel: int  # concurrent transcribe workers (whisper-cli processes)
    threads: int  # whisper-cli -t
    qos: Qos  # macOS scheduling tier
    nice_level: int  # niceness when qos == "nice" (ignored otherwise)

    def command_prefix(self) -> list[str]:
        """argv prefix that applies the scheduling tier to a launched
        subprocess. Empty list for the normal tier."""
        if self.qos == "background":
            return ["taskpolicy", "-b"]
        if self.qos == "nice":
            return ["nice", "-n", str(self.nice_level)]
        return []


def resolve_load_profile(
    level: LoadLevel,
    *,
    perf_cores: int,
    background_priority: bool,
) -> LoadProfile:
    """Map (level, hardware, polite-flag) → concrete launch parameters.

    ``perf_cores`` is the machine's performance-core count; the caller falls
    back to logical CPUs / a small constant when detection fails. Higher
    levels spend more cores and a less-deferential scheduling tier.
    """
    p = max(1, perf_cores)
    if level == "quiet":
        return LoadProfile(parallel=1, threads=min(2, p), qos="background", nice_level=0)
    if level == "balanced":
        return LoadProfile(parallel=1, threads=max(2, p // 2), qos="nice", nice_level=10)
    if level == "full":
        parallel = 2 if p >= 8 else 1
        threads = max(2, p // parallel)
        if background_priority:
            return LoadProfile(parallel=parallel, threads=threads, qos="nice", nice_level=5)
        return LoadProfile(parallel=parallel, threads=threads, qos="normal", nice_level=0)
    raise ValueError(f"unknown load level: {level!r}")


_TIER_DE = {
    "background": "läuft im Hintergrund (E-Kerne)",
    "nice": "weicht aktiver Nutzung aus",
    "normal": "volle Priorität",
}


def describe_profile(profile: LoadProfile) -> str:
    """Human-readable one-liner for the settings read-out label."""
    episodes = "1 Episode" if profile.parallel == 1 else f"{profile.parallel} Episoden"
    return f"{episodes} × {profile.threads} Threads · {_TIER_DE[profile.qos]}"


def resolve_transcribe_workers(
    load_parallel: int,
    transcribe_concurrency: int,
    ram_gb: float | None = None,
    per_worker_gb: float = 3.0,
) -> int:
    """Effective transcribe-worker count (2.2).

    The load profile sets a safe default (1, or 2 on big machines at "full").
    ``transcribe_concurrency`` is a user override: when > 1 it raises the cap to
    that value; the default (1) leaves the profile's choice untouched so we never
    *reduce* the parallelism a "full" profile already grants.

    The result is capped by available RAM (``ram_gb``): each concurrent whisper
    worker holds the model in memory (~``per_worker_gb`` for large-v3), so we
    never spawn more than ``ram_gb // per_worker_gb`` workers — preventing an
    over-eager ``transcribe_concurrency`` from thrashing swap. ``ram_gb=None``
    skips the RAM cap (detection failed)."""
    base = max(int(load_parallel or 1), 1)
    cc = int(transcribe_concurrency or 1)
    workers = max(cc, 1) if cc > 1 else base
    if ram_gb:
        ram_cap = max(1, int(ram_gb // max(per_worker_gb, 0.1)))
        workers = min(workers, ram_cap)
    return max(workers, 1)
