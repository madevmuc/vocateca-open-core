# core/backlog.py
"""Canonical backlog ("history vs. future") strategy for a freshly-added show.

One Qt-free entry point reused by the CLI (`paragraphos add --backlog`), the
GUI Add-show dialog, and the app-side reconcile dialog. Modes:
    all              — transcribe the entire archive (leave all pending)
    recent           — keep only the newest episode pending
    last:N           — keep the newest N pending
    since:YYYY-MM-DD  — keep episodes published on/after the date pending
Everything not kept is marked ``done`` so the next check skips it.
"""

from __future__ import annotations

from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import List, Optional, Tuple

Mode = Tuple[str, Optional[object]]  # ("last", 5) | ("since", "2026-01-05") | ("all", None)


class BacklogError(ValueError):
    """Raised for an unparseable --backlog value."""


def parse_backlog(raw: str) -> Mode:
    s = (raw or "").strip().lower()
    if s == "all":
        return ("all", None)
    if s == "recent":
        return ("recent", None)
    if s.startswith("last:"):
        try:
            n = int(s.split(":", 1)[1])
        except ValueError:
            raise BacklogError(f"--backlog last:N needs an integer, got {raw!r}")
        if n < 1:
            raise BacklogError("--backlog last:N needs N >= 1")
        return ("last", n)
    if s.startswith("since:"):
        date = raw.split(":", 1)[1].strip()
        try:
            datetime.strptime(date, "%Y-%m-%d")
        except ValueError:
            raise BacklogError(f"--backlog since:DATE needs YYYY-MM-DD, got {date!r}")
        return ("since", date)
    raise BacklogError(
        f"unknown --backlog {raw!r}; use one of: all | recent | last:N | since:YYYY-MM-DD"
    )


def _parse_pubdate(pd: str) -> Optional[datetime]:
    if not pd:
        return None
    try:
        dt = parsedate_to_datetime(pd)
        if dt is not None:
            return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        pass
    try:
        dt = datetime.fromisoformat(pd.replace("Z", "+00:00"))
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        pass
    if len(pd) == 8 and pd.isdigit():  # YouTube YYYYMMDD
        try:
            return datetime.strptime(pd, "%Y%m%d").replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


def apply_backlog(state, slug: str, mode: Mode, manifest: List[dict]) -> None:
    """Mark the back-catalog ``done`` per ``mode``. Episodes must already be
    upserted. ``manifest`` is the feed manifest (dicts with guid/pubDate)."""
    kind, arg = mode
    if kind == "all":
        return
    if kind in ("recent", "last"):
        keep = 1 if kind == "recent" else int(arg)
        with state._conn() as c:
            c.execute(
                """UPDATE episodes SET status='done'
                   WHERE show_slug=? AND guid NOT IN (
                       SELECT guid FROM episodes WHERE show_slug=?
                       ORDER BY pub_date DESC LIMIT ?
                   )""",
                (slug, slug, keep),
            )
        return
    if kind == "since":
        cutoff = datetime.strptime(str(arg), "%Y-%m-%d").replace(tzinfo=timezone.utc)
        stale = [
            ep["guid"]
            for ep in manifest
            # fail-open: an unparseable/missing pubDate falls back to `cutoff`, so it is KEPT pending (never auto-marked done on a parse failure).
            if (_parse_pubdate(ep.get("pubDate", "")) or cutoff) < cutoff
        ]
        if stale:
            with state._conn() as c:
                ph = ",".join("?" for _ in stale)
                c.execute(
                    f"UPDATE episodes SET status='done' WHERE show_slug=? AND guid IN ({ph})",
                    (slug, *stale),
                )
