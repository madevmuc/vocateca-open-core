"""Per-episode phase timeline (roadmap 7.2).

Compute how long each pipeline phase took for one episode from its persisted
lifecycle events (``discovered → download_started → downloaded →
transcribe_started → transcribed``). Pure + defensive: missing phases are simply
absent from the result, bad timestamps are ignored.
"""

from __future__ import annotations

from datetime import datetime


def _ts_map(events) -> dict[str, datetime]:
    """type → parsed timestamp (last occurrence wins)."""
    out: dict[str, datetime] = {}
    for ev in events:
        etype = ev["type"] if isinstance(ev, dict) else ev.type
        ts = ev["ts"] if isinstance(ev, dict) else ev.ts
        try:
            out[etype] = datetime.fromisoformat(ts)
        except (ValueError, TypeError):
            continue
    return out


def _delta(ts_map, a: str, b: str):
    if a in ts_map and b in ts_map:
        return (ts_map[b] - ts_map[a]).total_seconds()
    return None


def phase_durations(events) -> dict:
    """Phase durations (seconds) for one episode's event list.

    Keys (present only when both endpoints exist):
    ``queue_wait_sec`` (discovered→download_started), ``download_sec``
    (download_started→downloaded), ``transcribe_sec``
    (transcribe_started→transcribed), ``total_sec`` (first→last event)."""
    tm = _ts_map(events)
    if not tm:
        return {}
    out: dict = {}
    queue_wait = _delta(tm, "episode.discovered", "episode.download_started")
    download = _delta(tm, "episode.download_started", "episode.downloaded")
    transcribe = _delta(tm, "episode.transcribe_started", "episode.transcribed")
    if queue_wait is not None:
        out["queue_wait_sec"] = queue_wait
    if download is not None:
        out["download_sec"] = download
    if transcribe is not None:
        out["transcribe_sec"] = transcribe
    out["total_sec"] = (max(tm.values()) - min(tm.values())).total_seconds()
    return out


def _fmt(sec: float) -> str:
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    m, s = divmod(sec, 60)
    if m < 60:
        return f"{m}m {s}s"
    h, m = divmod(m, 60)
    return f"{h}h {m}m"


def format_timeline(events) -> str:
    """Human-readable multi-line timeline summary for a dialog."""
    d = phase_durations(events)
    if not d:
        return "No timeline data yet for this episode."
    rows = [
        ("Queue wait", d.get("queue_wait_sec")),
        ("Download", d.get("download_sec")),
        ("Transcribe", d.get("transcribe_sec")),
        ("Total", d.get("total_sec")),
    ]
    return "\n".join(f"{label}: {_fmt(v)}" for label, v in rows if v is not None)
