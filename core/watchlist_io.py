# core/watchlist_io.py
"""Clobber-safe watchlist persistence + reload for the running app.

save_watchlist: before writing, if the on-disk file changed since our baseline
(an external edit we haven't reconciled), union-merge any disk-only shows back
in so we never drop them. Then write atomically and refresh the baseline.

reload_watchlist: adopt the on-disk file as truth, return newly-appeared slugs.
"""

from __future__ import annotations

from typing import List

from core.models import Watchlist
from core.watchlist_guard import file_digest, is_external_change


def _path(ctx):
    return ctx.data_dir / "watchlist.yaml"


def save_watchlist(ctx) -> None:
    path = _path(ctx)
    baseline = getattr(ctx, "_watchlist_hash", "")
    if is_external_change(path, baseline):
        disk = Watchlist.load(path)
        have = {s.slug for s in ctx.watchlist.shows}
        for s in disk.shows:
            if s.slug not in have:  # disk-only → preserve
                ctx.watchlist.shows.append(s)
    ctx.watchlist.save_atomic(path)
    ctx._watchlist_hash = file_digest(path)


def reload_watchlist(ctx) -> List[str]:
    path = _path(ctx)
    before = {s.slug for s in ctx.watchlist.shows}
    try:
        disk = Watchlist.load(path)
    except Exception:
        return []  # half-written / invalid → leave as-is
    ctx.watchlist = disk
    ctx._watchlist_hash = file_digest(path)
    return [s.slug for s in disk.shows if s.slug not in before]
