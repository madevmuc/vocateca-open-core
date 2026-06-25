"""Derived queue UI state — single source of truth for every surface.

``pausing`` is the transitional state after Pause is pressed but before
the in-flight episode finishes: the worker was told to stop claiming new
work (``queue_paused`` meta = "1") yet ``ctx.queue.running`` is still
True because whisper-cli is finishing the current episode. Pure and
Qt-free so it is unit-testable without the GUI.
"""

from __future__ import annotations


def queue_ui_state(*, queue_paused: bool, running: bool) -> str:
    """Return one of: "idle" | "running" | "pausing" | "paused"."""
    if running and queue_paused:
        return "pausing"
    if running:
        return "running"
    if queue_paused:
        return "paused"
    return "idle"
