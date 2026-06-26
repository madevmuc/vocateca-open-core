"""YouTube URL parsing + canonical-RSS helpers."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal
from urllib.parse import parse_qs, urlparse

YoutubeKind = Literal["video", "channel_id", "handle", "channel_url"]


class YoutubeUrlError(ValueError):
    """URL is not a recognisable YouTube video/channel/handle URL."""


@dataclass(frozen=True)
class YoutubeUrl:
    kind: YoutubeKind
    # video id; channel id; handle without @; or, for kind "channel_url",
    # a full channel URL (resolved to an id via resolve_channel_url_to_id).
    value: str


_VIDEO_ID_RE = re.compile(r"^[\w-]{11}$")
_CHANNEL_ID_RE = re.compile(r"^UC[\w-]{22}$")


def parse_youtube_url(url: str) -> YoutubeUrl:
    u = urlparse(url.strip())
    host = (u.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = u.path or ""

    if host == "youtu.be":
        vid = path.lstrip("/").split("/", 1)[0]
        if _VIDEO_ID_RE.match(vid):
            return YoutubeUrl("video", vid)
        raise YoutubeUrlError(f"bad video id: {vid!r}")

    if host in {"youtube.com", "m.youtube.com", "music.youtube.com"}:
        if path.startswith("/watch"):
            qs = parse_qs(u.query)
            v = (qs.get("v") or [""])[0]
            if _VIDEO_ID_RE.match(v):
                return YoutubeUrl("video", v)
            raise YoutubeUrlError(f"bad video id in query: {v!r}")
        if path.startswith("/channel/"):
            cid = path.split("/", 2)[2].split("/", 1)[0]
            if _CHANNEL_ID_RE.match(cid):
                return YoutubeUrl("channel_id", cid)
            raise YoutubeUrlError(f"bad channel id: {cid!r}")
        if path.startswith("/@"):
            handle = path[2:].split("/", 1)[0]
            if handle:
                return YoutubeUrl("handle", handle)
        if path.startswith("/c/") or path.startswith("/user/"):
            return YoutubeUrl("channel_url", url.strip())

    # Bare "@handle" or bare "name" (no scheme, no host): only when urlparse
    # produced no netloc, so real URLs that fail every branch still raise.
    if not u.netloc:
        remainder = url.strip()
        if remainder.startswith("@"):
            remainder = remainder[1:]
        if remainder and "/" not in remainder and not any(c.isspace() for c in remainder):
            return YoutubeUrl("channel_url", f"https://www.youtube.com/@{remainder}")

    raise YoutubeUrlError(f"unrecognised YouTube URL: {url!r}")


def rss_url_for_channel_id(channel_id: str) -> str:
    return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"


def channel_id_from_feed_url(feed_url: str) -> str:
    """Return the ``channel_id`` query param of a YouTube channel feed URL.

    Returns ``""`` when the URL carries no such param (e.g. a podcast RSS
    URL). Kept permissive on purpose — does not validate the ``UC…`` shape —
    so it can dedup channels by the id embedded in their canonical feed URL.
    """
    qs = parse_qs(urlparse((feed_url or "").strip()).query)
    return (qs.get("channel_id") or [""])[0]
