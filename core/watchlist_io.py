# core/watchlist_io.py
"""Clobber-safe watchlist persistence + reload for the running app.

save_watchlist: before writing, if the on-disk file changed since our baseline
(an external edit we haven't reconciled), union-merge any disk-only shows back
in so we never drop them. Then write atomically and refresh the baseline.

reload_watchlist: adopt the on-disk file as truth, return newly-appeared slugs.
"""

from __future__ import annotations

import logging
from typing import List

import yaml
from pydantic import ValidationError

from core.models import Watchlist
from core.watchlist_guard import file_digest, is_external_change


def _path(ctx):
    return ctx.data_dir / "watchlist.yaml"


def save_watchlist(ctx) -> None:
    path = _path(ctx)
    baseline = getattr(ctx, "_watchlist_hash", "")
    if is_external_change(path, baseline):
        # NOTE: union-merge preserves disk-only shows so an external edit is
        # never clobbered. Trade-off: if the in-memory change was a DELETE and
        # the same slug still exists on disk (externally re-added since our
        # baseline), the delete is silently undone (the slug is treated as
        # disk-only and re-appended). Acceptable under single-writer use; the
        # Task 8 watchdog/checkpoint reload surfaces external edits before the
        # user acts. A proper fix (deletion tombstones) belongs with the
        # reconcile work. Strictly safer than the old clobber-everything behavior.
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
    except (OSError, yaml.YAMLError, ValidationError) as e:
        logging.warning("watchlist reload skipped (unreadable/invalid): %s", e)
        return []  # half-written / invalid → leave as-is
    ctx.watchlist = disk
    ctx._watchlist_hash = file_digest(path)
    return [s.slug for s in disk.shows if s.slug not in before]
