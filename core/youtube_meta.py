"""yt-dlp metadata wrappers for channel preview + video enumeration.

Fast path: handle resolution + preview fetch use plain HTTP (httpx)
because yt-dlp's `--print %(channel_id)s` takes 12-90+ seconds on
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
_CHANNEL_ID_RE = re.compile(r"^UC[\w-]{22}$")
_OG_IMAGE_RE = re.compile(r'<meta property="og:image" content="([^"]+)"')


def _first_channel_id(out: str) -> str:
    """Return the first ``UC…`` channel id in yt-dlp output, else "".

    ``--print %(channel_id)s`` prints the literal ``NA`` when the field
    is missing, and a bare non-``UC`` token is likewise not a usable id.
    Both collapse to "" so callers hit the documented empty-on-failure
    path instead of propagating a fake id downstream.
    """
    for line in out.splitlines():
        line = line.strip()
        if _CHANNEL_ID_RE.match(line):
            return line
    return ""


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


def _og_image(channel_id: str, *, timeout: float = 8.0) -> str:
    """Scrape the channel page's ``<meta property="og:image">`` (the avatar).

    YouTube's channel page exposes the real channel avatar as its
    Open Graph image. Best-effort: any failure (network, no match)
    returns "" so the caller falls through the avatar fallback chain.
    """
    try:
        html = _http_get_text(f"https://www.youtube.com/channel/{channel_id}", timeout=timeout)
        m = _OG_IMAGE_RE.search(html)
        return m.group(1) if m else ""
    except Exception:  # noqa: BLE001
        return ""


def _pick_avatar(og: str, ytdlp_thumb: str, rss_thumb: str) -> str:
    """First non-empty of og:image → yt-dlp thumb → latest-video frame → ""."""
    for candidate in (og, ytdlp_thumb, rss_thumb):
        if candidate:
            return candidate
    return ""


def resolve_channel_url_to_id(url: str) -> str:
    """Resolve any channel URL (``/c/``, ``/user/``, ``/@handle``, …) to its id.

    Fast path: scrape the page for the `<link rel="canonical">` tag
    (~0.5s). Falls back to yt-dlp on a miss (~12-90s), which prints the
    bare ``UC…`` channel id via ``%(channel_id)s``.
    """
    try:
        html = _http_get_text(url, timeout=8.0)
    except Exception:  # noqa: BLE001
        html = ""
    m = _CANONICAL_RE.search(html)
    if m:
        return m.group(1)
    # Fallback — yt-dlp slow path (kept so blocked HTTP still resolves).
    out = _run_ytdlp(
        ["--skip-download", "--print", "%(channel_id)s", url],
        timeout=120,
    )
    return _first_channel_id(out)


def resolve_handle_to_channel_id(handle: str) -> str:
    """Look up a channel id from its @handle.

    Thin wrapper over :func:`resolve_channel_url_to_id` for the
    @handle URL form.
    """
    handle = handle.lstrip("@")
    return resolve_channel_url_to_id(f"https://www.youtube.com/@{handle}")


def resolve_video_to_channel_id(video_id: str) -> str:
    """Resolve a video id to the channel id that published it (yt-dlp)."""
    out = _run_ytdlp(
        [
            "--skip-download",
            "--print",
            "%(channel_id)s",
            f"https://www.youtube.com/watch?v={video_id}",
        ],
        timeout=120,
    )
    return _first_channel_id(out)


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
        # per-video <media:thumbnail>. Keep the latest one as a free fallback
        # frame; the real avatar comes from the channel page's og:image.
        rss_thumb = ""
        if entries:
            thumb = entries[0].find("media:group/media:thumbnail", ns)
            if thumb is not None:
                rss_thumb = thumb.get("url") or ""
        if title:
            # One extra cheap GET for the avatar; don't trigger the slow
            # yt-dlp path just for an image (hence ytdlp_thumb="").
            artwork = _pick_avatar(_og_image(channel_id), "", rss_thumb)
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
    ytdlp_thumb = thumbs[-1]["url"] if thumbs else ""
    resolved_id = data.get("channel_id") or channel_id
    artwork = _pick_avatar(_og_image(resolved_id), ytdlp_thumb, "")
    return {
        "channel_id": resolved_id,
        "title": data.get("channel") or data.get("title") or "",
        "video_count": int(data.get("playlist_count") or 0),
        "video_count_is_lower_bound": False,
        "artwork_url": artwork,
    }


def fetch_channel_first_video_date(channel_id: str) -> str:
    """Return the channel's oldest video upload date as ``YYYY-MM-DD``, or "".

    Thin wrapper over :func:`fetch_channel_first_video_and_count` for callers
    that only need the date.
    """
    return fetch_channel_first_video_and_count(channel_id)[0]


def fetch_channel_first_video_and_count(channel_id: str) -> tuple[str, int]:
    """Return ``(oldest-upload-date 'YYYY-MM-DD' or "", total_video_count)``.

    The Videos tab is newest-first, so ``--playlist-items -1`` is the oldest
    upload — and walking to it also yields ``playlist_count``, so the channel's
    "active since" date AND its total video count come back in ONE yt-dlp call.
    yt-dlp fully extracts only that single (oldest) video, so this is far
    cheaper than enumerating the whole channel. Best-effort: any failure
    returns ``("", 0)`` so the caller can fall back to its own defaults.
    """
    try:
        out = _run_ytdlp(
            [
                "--skip-download",
                "--playlist-items",
                "-1",
                "--print",
                "%(playlist_count)s|%(upload_date)s",
                f"https://www.youtube.com/channel/{channel_id}/videos",
            ],
            timeout=120,
        )
    except Exception:  # noqa: BLE001
        return "", 0
    lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
    if not lines:
        return "", 0
    parts = lines[-1].split("|")
    count = int(parts[0]) if parts and parts[0].strip().isdigit() else 0
    date = ""
    if len(parts) > 1:
        ud = parts[1].strip()
        if len(ud) == 8 and ud.isdigit():
            date = f"{ud[:4]}-{ud[4:6]}-{ud[6:8]}"
    return date, count


def enumerate_channel_videos(
    channel_id: str,
    *,
    limit: int | None = None,
    date_after: str | None = None,
    include_shorts: bool = False,
    full: bool = False,
) -> List[Dict]:
    """Enumerate a channel's uploads via yt-dlp.

    By default targets the ``/videos`` tab, which excludes Shorts; set
    ``include_shorts=True`` to enumerate the channel root instead.
    ``date_after`` (``YYYY-MM-DD``) limits to uploads on/after that date.

    ``full=False`` (default) uses ``--flat-playlist`` — fast, but yt-dlp
    returns ``upload_date``/``timestamp``/``duration`` as ``None`` (the
    history-streaming browser relies on this fast path). ``full=True`` DROPS
    ``--flat-playlist`` so each entry is fully extracted, yielding real
    ``upload_date`` + ``duration`` — and making ``--dateafter`` actually bite.
    """
    base = f"https://www.youtube.com/channel/{channel_id}"
    target = base if include_shorts else f"{base}/videos"
    args: List[str] = []
    if not full:
        args.append("--flat-playlist")
    args.append("--dump-json")
    if limit:
        args += ["--playlist-end", str(limit)]
    if date_after:
        args += ["--dateafter", date_after.replace("-", "")]
    args.append(target)
    out = _run_ytdlp(args, timeout=300)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def enumerate_playlist_videos(
    playlist_id: str,
    *,
    limit: int | None = None,
    date_after: str | None = None,
    full: bool = False,
) -> List[Dict]:
    """Enumerate a playlist's videos via yt-dlp (3.2). Mirrors
    ``enumerate_channel_videos`` but targets a ``/playlist?list=`` URL."""
    target = f"https://www.youtube.com/playlist?list={playlist_id}"
    args: List[str] = []
    if not full:
        args.append("--flat-playlist")
    args.append("--dump-json")
    if limit:
        args += ["--playlist-end", str(limit)]
    if date_after:
        args += ["--dateafter", date_after.replace("-", "")]
    args.append(target)
    out = _run_ytdlp(args, timeout=300)
    return [json.loads(line) for line in out.splitlines() if line.strip()]
