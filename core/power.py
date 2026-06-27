"""Power-state detection + battery load adaptation (roadmap 8.4).

On macOS, ``pmset -g batt`` reports whether the machine is on AC or battery.
When on battery and ``pause_on_battery`` is set, transcription drops to the
gentler ``battery_load_level`` so an unplugged laptop isn't hammered. Parsing is
a pure function; the probe is best-effort (returns False if pmset is absent).
"""

from __future__ import annotations

import subprocess

_PMSET_TIMEOUT = 3


def parse_pmset_on_battery(output: str) -> bool:
    """True if ``pmset -g batt`` output indicates the machine is on battery."""
    if not output:
        return False
    first = output.strip().splitlines()[0] if output.strip() else ""
    return "Battery Power" in first


def on_battery() -> bool:
    """Whether the machine is currently running on battery (macOS)."""
    try:
        result = subprocess.run(
            ["pmset", "-g", "batt"],
            capture_output=True,
            text=True,
            timeout=_PMSET_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if result.returncode != 0:
        return False
    return parse_pmset_on_battery(result.stdout or "")


def effective_load_level(
    base_level: str, *, on_battery: bool, pause_on_battery: bool, battery_level: str
) -> str:
    """Resolve the load level to actually use given the power state (8.4)."""
    if on_battery and pause_on_battery:
        return battery_level
    return base_level


def should_pause_for_battery(
    *, pause_queue_on_battery: bool, on_battery_now: bool | None = None
) -> bool:
    """Whether the queue should be held right now because we're on battery.

    ``on_battery_now`` is injectable for tests; when None it probes
    :func:`on_battery`. Returns False unless the setting is on AND unplugged."""
    if not pause_queue_on_battery:
        return False
    return on_battery() if on_battery_now is None else bool(on_battery_now)
