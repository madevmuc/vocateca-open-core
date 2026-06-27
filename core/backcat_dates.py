"""Back-catalogue real upload-date backfill (roadmap 3.1).

The fast channel-enumeration path (``--flat-playlist``) doesn't return real
upload dates, so back-catalogue episodes can carry approximate/synthetic
``pub_date`` values. This module re-resolves the real ``upload_date`` via a full
yt-dlp extraction (slow, so run in the background / on demand) and updates the
episode rows. Pure update + resolve helpers; the network call is injected.
"""

from __future__ import annotations


def resolve_real_dates(channel_id: str, *, enumerate_fn) -> dict[str, str]:
    """Map ``video_id → "YYYY-MM-DD"`` from a full channel enumeration.

    ``enumerate_fn(channel_id, full=True)`` returns yt-dlp entry dicts with
    ``id`` + ``upload_date`` (``YYYYMMDD``). Entries without a date are skipped."""
    out: dict[str, str] = {}
    for entry in enumerate_fn(channel_id, full=True) or []:
        vid = entry.get("id")
        ud = entry.get("upload_date")
        if vid and ud and len(ud) == 8 and ud.isdigit():
            out[vid] = f"{ud[:4]}-{ud[4:6]}-{ud[6:8]}"
    return out


def update_pub_dates(state, mapping: dict[str, str]) -> int:
    """Update ``pub_date`` for episodes by guid from ``mapping``; only rows whose
    date actually differs are touched. Returns the number changed."""
    changed = 0
    with state._conn() as c:
        for guid, date in mapping.items():
            cur = c.execute(
                "UPDATE episodes SET pub_date=? WHERE guid=? AND pub_date IS NOT ?",
                (date, guid, date),
            )
            changed += cur.rowcount or 0
    return changed


def backfill_show_dates(state, channel_id: str, *, enumerate_fn) -> int:
    """Resolve + apply real upload dates for one channel. Returns rows changed."""
    return update_pub_dates(state, resolve_real_dates(channel_id, enumerate_fn=enumerate_fn))
