"""Global + per-show statistics."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


def throughput_per_day(events: list[dict], *, days: int = 7) -> float:
    """Episodes transcribed per day over the last ``days`` (7.1).

    ``events`` are event-log dicts (``type``, ``ts``). Counts
    ``episode.transcribed`` events whose timestamp is within the window."""
    from datetime import datetime, timedelta, timezone

    if days <= 0:
        return 0.0
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    n = 0
    for ev in events:
        if ev.get("type") != "episode.transcribed":
            continue
        try:
            if datetime.fromisoformat(ev["ts"]) >= cutoff:
                n += 1
        except (ValueError, TypeError, KeyError):
            continue
    return n / days


def success_rate(events: list[dict]) -> float:
    """Fraction of finished episodes that succeeded: transcribed / (transcribed
    + failed) over the supplied events. 0.0 when there's nothing finished."""
    transcribed = sum(1 for e in events if e.get("type") == "episode.transcribed")
    failed = sum(1 for e in events if e.get("type") == "episode.failed")
    total = transcribed + failed
    return transcribed / total if total else 0.0


def dashboard_summary(state, *, window_days: int = 7) -> dict:
    """Bundle the headline dashboard metrics (7.1) from state + events."""
    events = state.query_events(limit=10000)
    g = compute_global_stats(state)
    return {
        "throughput_per_day": throughput_per_day(events, days=window_days),
        "success_rate": success_rate(events),
        "realtime_factor": realtime_factor(state),
        "done": g.episodes_done,
        "pending": g.episodes_pending,
        "failed": g.episodes_failed,
    }


def _parse_duration(s: Optional[str]) -> int:
    """RSS duration may be 'SSSS', 'MM:SS', or 'HH:MM:SS'. Returns seconds."""
    if not s:
        return 0
    parts = str(s).strip().split(":")
    try:
        if len(parts) == 1:
            return int(parts[0])
        if len(parts) == 2:
            return int(parts[0]) * 60 + int(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    except ValueError:
        return 0
    return 0


@dataclass(frozen=True)
class GlobalStats:
    transcripts: int
    total_seconds: int
    total_words: int
    episodes_total: int
    episodes_done: int
    episodes_pending: int
    episodes_failed: int


def compute_global_stats(state) -> GlobalStats:
    with state._conn() as c:
        totals = dict(c.execute("SELECT status, COUNT(*) FROM episodes GROUP BY status").fetchall())
        transcripts = totals.get("done", 0)
        words_row = c.execute(
            "SELECT COALESCE(SUM(word_count), 0) FROM episodes WHERE status='done'"
        ).fetchone()
        total_words = int(words_row[0] or 0)
        dur_row = c.execute(
            "SELECT COALESCE(SUM(duration_sec), 0) FROM episodes WHERE status='done'"
        ).fetchone()
        total_seconds = int(dur_row[0] or 0)
        total = sum(totals.values())
    return GlobalStats(
        transcripts=transcripts,
        total_seconds=total_seconds,
        total_words=total_words,
        episodes_total=total,
        episodes_done=totals.get("done", 0),
        episodes_pending=totals.get("pending", 0),
        episodes_failed=totals.get("failed", 0),
    )


@dataclass(frozen=True)
class ShowStats:
    slug: str
    total: int
    done: int
    pending: int
    failed: int
    avg_words: int
    avg_duration_sec: int
    total_seconds: int
    total_words: int
    last_completed: Optional[str]


def compute_show_stats(state, slug: str) -> ShowStats:
    with state._conn() as c:
        row = c.execute(
            """
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN status='done' THEN 1 ELSE 0 END) AS done,
                SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) AS pending,
                SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) AS failed,
                COALESCE(AVG(CASE WHEN status='done' THEN word_count END), 0) AS avg_words,
                COALESCE(AVG(CASE WHEN status='done' THEN duration_sec END), 0) AS avg_dur,
                COALESCE(SUM(CASE WHEN status='done' THEN duration_sec END), 0) AS total_dur,
                COALESCE(SUM(CASE WHEN status='done' THEN word_count END), 0) AS total_words,
                MAX(CASE WHEN status='done' THEN completed_at END) AS last_done
            FROM episodes WHERE show_slug = ?
        """,
            (slug,),
        ).fetchone()
    if row is None:
        return ShowStats(slug, 0, 0, 0, 0, 0, 0, 0, 0, None)
    return ShowStats(
        slug=slug,
        total=row["total"] or 0,
        done=row["done"] or 0,
        pending=row["pending"] or 0,
        failed=row["failed"] or 0,
        avg_words=int(row["avg_words"] or 0),
        avg_duration_sec=int(row["avg_dur"] or 0),
        total_seconds=int(row["total_dur"] or 0),
        total_words=int(row["total_words"] or 0),
        last_completed=row["last_done"],
    )


_FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def rescan_library_counts(state, output_root: Path) -> int:
    """Walk output_root, count words in each .md, update state.episodes.word_count
    and duration_sec (from .srt last timestamp). Returns count updated."""
    output_root = Path(output_root)
    if not output_root.exists():
        return 0
    updated = 0
    for md in output_root.rglob("*.md"):
        if md.name == "index.md":
            continue
        text = md.read_text(encoding="utf-8", errors="ignore")
        m = _FM_RE.match(text)
        if not m:
            continue
        # Crude frontmatter scan: look for "guid:" line.
        import yaml

        try:
            fm = yaml.safe_load(m.group(1)) or {}
        except yaml.YAMLError:
            continue
        guid = fm.get("guid")
        if not guid:
            continue
        body = text[m.end() :]
        words = len(body.split())
        dur = _duration_from_srt(md.with_suffix(".srt"))
        state.record_completion(guid, words, dur)
        updated += 1
    return updated


_SRT_TIME = re.compile(r"(\d+):(\d+):(\d+),\d+\s+-->\s+(\d+):(\d+):(\d+),")


def _duration_from_srt(path: Path) -> Optional[int]:
    if not path.exists():
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    last_end = 0
    for m in _SRT_TIME.finditer(text):
        eh, em_, es = int(m.group(4)), int(m.group(5)), int(m.group(6))
        last_end = max(last_end, eh * 3600 + em_ * 60 + es)
    return last_end or None


def realtime_factor(state, *, sample_limit: int = 50) -> float:
    """Return transcribe wall-clock seconds divided by audio duration seconds.

    A value of ``0.25`` means whisper runs at 4× realtime (transcribes a
    60-minute episode in 15 minutes). Derived from the most recent
    ``sample_limit`` completed episodes.

    Falls back to 0.25 when we have no usable history — a sensible
    optimistic default for whisper-cpp large-v3-turbo on Apple Silicon.
    """
    with state._conn() as c:
        rows = c.execute(
            "SELECT attempted_at, completed_at, duration_sec FROM episodes "
            "WHERE status='done' AND attempted_at IS NOT NULL "
            "AND completed_at IS NOT NULL AND duration_sec > 0 "
            "ORDER BY completed_at DESC LIMIT ?",
            (sample_limit,),
        ).fetchall()
    if not rows:
        return 0.25
    from datetime import datetime

    total_wall = 0.0
    total_audio = 0
    for r in rows:
        try:
            a = datetime.fromisoformat(r["attempted_at"])
            b = datetime.fromisoformat(r["completed_at"])
        except (TypeError, ValueError):
            continue
        wall = (b - a).total_seconds()
        # Skip implausible wall-clock (dedup skips + crashed jobs).
        if wall < 5 or wall > 3600:
            continue
        total_wall += wall
        total_audio += int(r["duration_sec"])
    if total_audio <= 0:
        return 0.25
    return total_wall / total_audio


def has_realtime_history(state) -> bool:
    """True iff at least one completed episode has the wall-clock + audio
    duration we need to compute a real ETA. Lets the UI distinguish a
    ``realtime_factor()`` return based on live data from the 0.25 fallback
    so users aren't shown a confidently-wrong finish time on first run."""
    with state._conn() as c:
        row = c.execute(
            "SELECT 1 FROM episodes "
            "WHERE status='done' AND attempted_at IS NOT NULL "
            "AND completed_at IS NOT NULL AND duration_sec > 0 LIMIT 1"
        ).fetchone()
    return row is not None


def pending_duration_sum(state, *, show_slug: str | None = None) -> int:
    """Sum of duration_sec across pending + downloading + downloaded
    episodes — i.e. audio still to transcribe."""
    where = "status IN ('pending', 'downloading', 'downloaded') AND duration_sec > 0"
    params: tuple = ()
    if show_slug:
        where = f"show_slug=? AND {where}"
        params = (show_slug,)
    with state._conn() as c:
        row = c.execute(
            f"SELECT COALESCE(SUM(duration_sec), 0) AS tot FROM episodes WHERE {where}",
            params,
        ).fetchone()
    return int(row["tot"] or 0)


def historical_avg_transcribe_sec(state, *, sample_limit: int = 50) -> float:
    """Return the average wall-clock time an episode takes to transcribe,
    measured from the most recent `sample_limit` completed episodes.

    Returns 0.0 if there is no usable history. Used as a fallback ETA
    before the live rolling average has data points.
    """
    with state._conn() as c:
        rows = c.execute(
            "SELECT attempted_at, completed_at FROM episodes "
            "WHERE status='done' AND attempted_at IS NOT NULL "
            "AND completed_at IS NOT NULL "
            "ORDER BY completed_at DESC LIMIT ?",
            (sample_limit,),
        ).fetchall()
    if not rows:
        return 0.0
    from datetime import datetime

    deltas: list[float] = []
    for r in rows:
        try:
            a = datetime.fromisoformat(r["attempted_at"])
            b = datetime.fromisoformat(r["completed_at"])
        except (TypeError, ValueError):
            continue
        d = (b - a).total_seconds()
        # Skip implausible values: dedup-skips complete in ~0s; multi-hour
        # entries are usually crashed jobs whose state was reset later.
        if 5 <= d <= 3600:
            deltas.append(d)
    if not deltas:
        return 0.0
    return sum(deltas) / len(deltas)


_PROMPT_WORDRE = re.compile(r"[A-Za-zÄÖÜäöüß][A-Za-zÄÖÜäöüß\-]{2,}")


def prompt_coverage(prompt: str, sample_texts: list[str]) -> float:
    """Fraction of distinct ≥3-letter prompt tokens that appear in the
    concatenated sample texts (case-insensitive).

    Used to detect stale whisper_prompts: if an author lists domain
    terms that the actual transcripts never contain, the prompt isn't
    steering the model. Low coverage (< 0.2) is flagged as a badge
    in the Shows tab.
    """
    if not prompt.strip() or not sample_texts:
        return 0.0
    tokens = {m.group(0).lower() for m in _PROMPT_WORDRE.finditer(prompt)}
    if not tokens:
        return 0.0
    blob = " ".join(sample_texts).lower()
    hit = sum(1 for t in tokens if t in blob)
    return hit / len(tokens)


def show_prompt_coverage(
    state, slug: str, prompt: str, sample_limit: int = 10
) -> tuple[int, float]:
    """Sample the last `sample_limit` DONE episodes of `slug` and return
    `(n_sampled, coverage)`. Caller renders the badge when
    n ≥ 5 and coverage < 0.2."""
    with state._conn() as c:
        rows = c.execute(
            "SELECT transcript_path FROM episodes "
            "WHERE show_slug=? AND status='done' "
            "AND transcript_path IS NOT NULL "
            "ORDER BY completed_at DESC LIMIT ?",
            (slug, sample_limit),
        ).fetchall()
    if not rows:
        return 0, 0.0
    samples: list[str] = []
    for r in rows:
        p = Path(r["transcript_path"] or "")
        if not p.exists():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        # Skip frontmatter block so only the transcript body is sampled.
        if text.startswith("---"):
            end = text.find("\n---", 3)
            if end != -1:
                text = text[end + 4 :]
        samples.append(text)
    if not samples:
        return 0, 0.0
    return len(samples), prompt_coverage(prompt, samples)


def format_duration(seconds: int) -> str:
    if seconds <= 0:
        return "0m"
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    mins = (seconds % 3600) // 60
    parts: list[str] = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if mins or not parts:
        parts.append(f"{mins}m")
    return " ".join(parts)
