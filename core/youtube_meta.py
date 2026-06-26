"""yt-dlp metadata wrappers for channel preview + video enumeration.

Fast path: handle resolution + preview fetch use plain HTTP (httpx)
because yt-dlp's `--print %(channel_id)j` takes 12-90+ seconds on
many networks (rate-limited, missing JS-runtime fallbacks). The
canonical channel URL lives in `<link rel="canonical">` of the
@handle page; the channel's hidden RSS feed gives title + recent
video count instantly.

yt-dlp is still used for `enumerate_channel_videos` (full backfill),
which has no equivalent fast path.
"""

from __future__ import annotations

import json
import re
import subprocess
from typing import Dict, List
from xml.etree import ElementTree as ET

from core import ytdlp
from core.http import get_client


class YoutubeMetaError(RuntimeError):
    """yt-dlp returned an error or unparseable output."""


_CANONICAL_RE = re.compile(
    r'<link rel="canonical" href="https://www\.youtube\.com/channel/(UC[\w-]{22})"'
)


def _run_ytdlp(args: List[str], timeout: int = 120) -> str:
    if not ytdlp.is_installed():
        raise YoutubeMetaError("yt-dlp not installed")
    cmd = [str(ytdlp.ytdlp_path()), *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise YoutubeMetaError(f"yt-dlp failed: {proc.stderr.strip() or 'unknown error'}")
    return proc.stdout


_BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)


def _http_get_text(url: str, *, timeout: float = 10.0) -> str:
    """GET with a Safari UA + bypass cookies for the EU consent wall.

    YouTube serves a stripped consent shim (no canonical link, no JSON)
    to non-browser UAs AND a separate consent-redirect to EU IPs unless
    the SOCS cookie is set. Both are required for `youtube.com/@handle`
    to return the actual channel page.
    """
    client = get_client()
    r = client.get(
        url,
        follow_redirects=True,
        timeout=timeout,
        headers={"User-Agent": _BROWSER_UA, "Accept-Language": "en-US,en;q=0.9"},
        cookies={
            "CONSENT": "PENDING+999",
            "SOCS": "CAESEwgDEgk0ODE3Nzk3MjQaAmVuIAEaBgiA_LyaBg",
        },
    )
    r.raise_for_status()
    return r.text


def resolve_handle_to_channel_id(handle: str) -> str:
    """Look up a channel id from its @handle.

    Fast path: scrape the @handle page for the `<link rel="canonical">`
    tag (~0.5s). Falls back to yt-dlp on any failure (~12-90s).
    """
    handle = handle.lstrip("@")
    try:
        html = _http_get_text(f"https://www.youtube.com/@{handle}", timeout=8.0)
    except Exception:  # noqa: BLE001
        html = ""
    m = _CANONICAL_RE.search(html)
    if m:
        return m.group(1)
    # Fallback — yt-dlp slow path (kept so blocked HTTP still resolves).
    out = _run_ytdlp(
        [
            "--skip-download",
            "--print",
            "%(channel_id)j",
            f"https://www.youtube.com/@{handle}",
        ],
        timeout=120,
    )
    line = out.strip().splitlines()[0]
    parsed = json.loads(line) if line.startswith('"') else json.loads(out.strip())
    if isinstance(parsed, dict):
        return parsed.get("channel_id") or ""
    return parsed


def fetch_channel_preview(channel_id: str) -> Dict[str, object]:
    """Return {title, video_count, artwork_url, channel_id}.

    Fast path: read the channel's hidden RSS feed at
    `/feeds/videos.xml?channel_id=UC...` which gives the title + the
    latest 15 entries (~0.5s, no yt-dlp). `video_count` from the feed
    is a lower bound (15 most recent); UI displays "15+ recent" when
    only the RSS path was used. Falls back to yt-dlp for the exact
    count and artwork on any HTTP failure.
    """
    feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"
    try:
        xml = _http_get_text(feed_url, timeout=8.0)
        root = ET.fromstring(xml)
        ns = {
            "atom": "http://www.w3.org/2005/Atom",
            "media": "http://search.yahoo.com/mrss/",
        }
        title_el = root.find("atom:title", ns)
        title = title_el.text.strip() if title_el is not None and title_el.text else ""
        entries = root.findall("atom:entry", ns)
        # The channel avatar isn't in the feed, but every entry carries a
        # per-video <media:thumbnail>. Surface the latest one so the Add
        # dialog has an image to show immediately without the slow yt-dlp path.
        artwork = ""
        if entries:
            thumb = entries[0].find("media:group/media:thumbnail", ns)
            if thumb is not None:
                artwork = thumb.get("url") or ""
        if title:
            return {
                "channel_id": channel_id,
                "title": title,
                "video_count": len(entries),
                "video_count_is_lower_bound": True,
                "artwork_url": artwork,
            }
    except Exception:  # noqa: BLE001
        pass
    # Fallback: yt-dlp slow path with exact playlist_count + artwork.
    out = _run_ytdlp(
        [
            "--skip-download",
            "--playlist-items",
            "0",
            "--dump-single-json",
            f"https://www.youtube.com/channel/{channel_id}",
        ],
        timeout=180,
    )
    data = json.loads(out)
    thumbs = data.get("thumbnails") or []
    artwork = thumbs[-1]["url"] if thumbs else ""
    return {
        "channel_id": data.get("channel_id") or channel_id,
        "title": data.get("channel") or data.get("title") or "",
        "video_count": int(data.get("playlist_count") or 0),
        "video_count_is_lower_bound": False,
        "artwork_url": artwork,
    }


def fetch_channel_first_video_date(channel_id: str) -> str:
    """Return the channel's oldest video upload date as ``YYYY-MM-DD``, or "".

    The Videos tab is newest-first, so ``--playlist-items -1`` is the oldest
    upload. yt-dlp walks the (flat) listing to its end but only fully extracts
    that single video, so this is far cheaper than enumerating the whole
    channel. Best-effort: any failure (network, no date, huge channel
    timeout) returns "" so the caller can fall back to its own default.
    """
    try:
        out = _run_ytdlp(
            [
                "--skip-download",
                "--playlist-items",
                "-1",
                "--print",
                "%(upload_date)s",
                f"https://www.youtube.com/channel/{channel_id}/videos",
            ],
            timeout=120,
        )
    except Exception:  # noqa: BLE001
        return ""
    lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
    if not lines:
        return ""
    ud = lines[-1]
    if len(ud) == 8 and ud.isdigit():
        return f"{ud[:4]}-{ud[4:6]}-{ud[6:8]}"
    return ""


def enumerate_channel_videos(channel_id: str, *, limit: int | None = None) -> List[Dict]:
    args = [
        "--flat-playlist",
        "--dump-json",
        f"https://www.youtube.com/channel/{channel_id}",
    ]
    if limit:
        args[1:1] = ["--playlist-end", str(limit)]
    out = _run_ytdlp(args, timeout=300)
    return [json.loads(line) for line in out.splitlines() if line.strip()]
