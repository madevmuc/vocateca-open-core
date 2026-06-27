"""RSS feed parsing — produces manifests in the project's canonical format.

Canonical manifest entry (matches raw/transcripts/*/episodes.json):

    {
        "guid": str,                     # entry.id, unique
        "title": str,
        "pubDate": "YYYY-MM-DDTHH:MM:SS", # ISO 8601, no tz
        "duration": str,                 # seconds OR HH:MM:SS / MM:SS — preserve feed's format
        "episode_number": str,           # 4-digit zero-padded, "0000" if missing
        "mp3_url": str,
        "description": str,
        "url": str,                      # episode landing page
    }

Array sorted oldest → newest by pubDate.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional

import feedparser
import httpx

from core.http import get_client
from core.security import MAX_FEED_BYTES, safe_url

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
)


@dataclass
class FeedHealth:
    ok: bool
    reason: str
    canonical_url: Optional[str] = None

    @classmethod
    def check(cls, url: str, *, timeout: float = 10.0) -> "FeedHealth":
        try:
            r = get_client().head(
                url, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=timeout
            )
        except httpx.HTTPError as e:
            return cls(False, f"network: {e}")
        if r.status_code >= 400:
            return cls(False, f"HTTP {r.status_code}")
        return cls(True, "", canonical_url=str(r.url))


def _extract_mp3_url(entry: Any) -> Optional[str]:
    # Prefer explicit audio/mpeg enclosure
    for link in entry.get("links", []) or []:
        if link.get("type") == "audio/mpeg" or link.get("rel") == "enclosure":
            href = link.get("href")
            if href:
                return href
    for enc in entry.get("enclosures", []) or []:
        t = enc.get("type", "")
        if t.startswith("audio") or not t:
            href = enc.get("href") or enc.get("url")
            if href:
                return href
    return None


def _youtube_video_id(entry: Any) -> Optional[str]:
    """Return the 11-char video id of a YouTube channel-feed entry, else None.

    YouTube channel feeds (``/feeds/videos.xml?channel_id=…``) are Atom, not
    RSS, and carry no audio enclosure — so ``_extract_mp3_url`` returns None
    for them. feedparser maps ``<yt:videoId>`` to ``entry.yt_videoid``; older
    entries only expose the id as ``yt:video:<VIDEOID>``. We surface the bare
    video id so the manifest can synthesise a ``watch?v=`` URL whose guid
    matches what ``AddShowDialog`` / ``enumerate_channel_videos`` seed.
    """
    vid = entry.get("yt_videoid")
    if not vid:
        eid = entry.get("id") or ""
        if eid.startswith("yt:video:"):
            vid = eid.rsplit(":", 1)[-1]
    return vid or None


def _pub_date_iso(entry: Any) -> str:
    """Return 'YYYY-MM-DDTHH:MM:SS' (no tz) or empty string."""
    parsed = entry.get("published_parsed") or entry.get("updated_parsed")
    if parsed:
        try:
            return datetime(*parsed[:6]).isoformat()
        except (TypeError, ValueError):
            pass
    # Fallback: feedparser gives raw 'published'
    raw = entry.get("published") or entry.get("updated") or ""
    return raw


def _episode_number(entry: Any) -> str:
    ep = entry.get("itunes_episode") or ""
    try:
        return str(int(ep)).zfill(4)
    except (TypeError, ValueError):
        return "0000"


def _duration(entry: Any) -> str:
    d = entry.get("itunes_duration")
    if d is None:
        return "00:00:00"
    return str(d)


def build_manifest(feed_url: str, *, timeout: float = 30.0) -> List[Dict[str, Any]]:
    """Fetch + parse a feed, return the canonical manifest list.

    Backwards-compatible signature — see `build_manifest_with_url`
    for the variant that also returns the canonical URL after redirect.
    """
    _, episodes, _et, _mod = build_manifest_with_url(feed_url, timeout=timeout)
    return episodes or []


def conditional_validators(
    etag: Optional[str], modified: Optional[str], *, use_cache: bool
) -> tuple[Optional[str], Optional[str]]:
    """Gate stored ETag / Last-Modified validators by the ``use_etag_cache``
    setting (8.5). When caching is off, return ``(None, None)`` so the next
    fetch sends no conditional headers and re-fetches in full."""
    if not use_cache:
        return None, None
    return etag, modified


def build_manifest_with_url(
    feed_url: str,
    *,
    timeout: float = 30.0,
    etag: Optional[str] = None,
    modified: Optional[str] = None,
) -> tuple[str, Optional[List[Dict[str, Any]]], Optional[str], Optional[str]]:
    """Fetch + parse a feed, returning ``(canonical_url, episodes, etag, modified)``.

    When the feed host issued a 301 Permanent Redirect (or a chain of
    them), ``canonical_url`` is the final URL httpx landed on. Callers
    that persist feed URLs should save the canonical one so the next
    daily check doesn't re-do the redirect handshake.

    If ``etag`` or ``modified`` are supplied they become
    ``If-None-Match`` / ``If-Modified-Since`` headers. When the server
    answers ``304 Not Modified`` we short-circuit: the returned
    ``episodes`` is ``None`` and ``etag``/``modified`` are ``None``
    (callers should keep their stored values). Otherwise ``episodes``
    is the parsed list and the returned etag/last-modified reflect the
    current response headers so the caller can persist them.
    """
    safe_url(feed_url)
    headers = {"User-Agent": USER_AGENT}
    if etag:
        headers["If-None-Match"] = etag
    if modified:
        headers["If-Modified-Since"] = modified
    r = get_client().get(feed_url, headers=headers, follow_redirects=True, timeout=timeout)
    if r.status_code == 304:
        # Unchanged — keep caller's stored validators, skip parse.
        return str(r.url), None, None, None
    r.raise_for_status()
    if len(r.content) > MAX_FEED_BYTES:
        raise ValueError(f"feed too large: {len(r.content)} bytes")
    canonical = str(r.url)
    parsed = feedparser.parse(r.content)

    episodes: List[Dict[str, Any]] = []
    for entry in parsed.entries:
        mp3 = _extract_mp3_url(entry)
        guid = entry.get("id") or entry.get("guid") or mp3
        if not mp3:
            # YouTube channel feed: no enclosure, but every entry is a video.
            # Synthesise a watch URL and key the episode by the bare video id
            # so feed-poll dedup matches the rows the Add dialog already seeded.
            vid = _youtube_video_id(entry)
            if vid:
                mp3 = f"https://www.youtube.com/watch?v={vid}"
                guid = vid
        if not mp3:
            continue
        episodes.append(
            {
                "guid": guid,
                "title": entry.get("title", ""),
                "pubDate": _pub_date_iso(entry),
                "duration": _duration(entry),
                "episode_number": _episode_number(entry),
                "mp3_url": mp3,
                "description": entry.get("summary", "") or entry.get("description", ""),
                "url": entry.get("link", ""),
            }
        )

    episodes.sort(key=lambda x: x["pubDate"])
    new_etag = r.headers.get("etag")
    new_modified = r.headers.get("last-modified")
    return canonical, episodes, new_etag, new_modified


def feed_metadata(feed_url: str, *, timeout: float = 30.0) -> Dict[str, str]:
    """Return channel-level metadata (title, author, description)."""
    r = get_client().get(
        feed_url, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=timeout
    )
    r.raise_for_status()
    parsed = feedparser.parse(r.content)
    ch = parsed.feed
    # Cover art: feedparser normalises <itunes:image href="..."> to
    # ch.itunes_image (a dict with 'href') or ch.image (dict with 'href'
    # or 'url' depending on how the feed spelled it). Check the most
    # specific source first so we don't pick up a favicon from <image>
    # when a proper itunes:image exists.
    itunes_img = ch.get("itunes_image") or {}
    image = ch.get("image") or {}
    artwork = (
        (itunes_img.get("href") if isinstance(itunes_img, dict) else "")
        or (image.get("href") if isinstance(image, dict) else "")
        or (image.get("url") if isinstance(image, dict) else "")
        or ""
    )
    return {
        "title": ch.get("title", ""),
        "author": ch.get("author", "") or ch.get("itunes_author", ""),
        "description": ch.get("subtitle", "") or ch.get("description", ""),
        "canonical_url": str(r.url),
        "artwork_url": artwork,
    }
