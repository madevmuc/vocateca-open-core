"""Audio-only YouTube download via yt-dlp, mapping to the existing
podcast-MP3 pipeline so transcribe.py treats it identically."""

from __future__ import annotations

import subprocess
from pathlib import Path

from core import ytdlp


class YoutubeDownloadError(RuntimeError):
    pass


def download_audio(video_id: str, target_mp3: Path, *, timeout: int = 600) -> Path:
    if not ytdlp.is_installed():
        raise YoutubeDownloadError("yt-dlp not installed")
    target_mp3.parent.mkdir(parents=True, exist_ok=True)
    template = str(target_mp3.with_suffix(""))
    cmd = [
        str(ytdlp.ytdlp_path()),
        "-f",
        "bestaudio",
        "--extract-audio",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "-o",
        f"{template}.%(ext)s",
        f"https://www.youtube.com/watch?v={video_id}",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise YoutubeDownloadError(proc.stderr.strip() or "unknown")
    if not target_mp3.exists():
        raise YoutubeDownloadError(f"yt-dlp did not produce {target_mp3}")
    return target_mp3


def probe_video_meta(video_id: str, *, timeout: int = 60) -> dict:
    """Cheap yt-dlp ``--print`` probe for classification (no download).

    Returns a dict suitable for :func:`core.youtube_classify.classify_video`:
    ``{"duration": int|None, "webpage_url": str, "live_status": str,
    "availability": str, "age_limit": int}``. yt-dlp emits ``NA`` (or a blank
    line) for fields it can't resolve; those collapse to ``None``/``""``/``0``.
    """
    if not ytdlp.is_installed():
        raise YoutubeDownloadError("yt-dlp not installed")
    fmt = "%(duration)s|%(webpage_url)s|%(live_status)s|%(availability)s|%(age_limit)s"
    cmd = [
        str(ytdlp.ytdlp_path()),
        "--skip-download",
        "--print",
        fmt,
        f"https://www.youtube.com/watch?v={video_id}",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise YoutubeDownloadError(proc.stderr.strip() or "probe failed")

    lines = [ln for ln in (proc.stdout or "").splitlines() if ln.strip()]
    parts = lines[0].split("|") if lines else []
    parts += [""] * (5 - len(parts))  # tolerate truncated output

    def _clean(v: str) -> str:
        v = (v or "").strip()
        return "" if v.upper() == "NA" else v

    def _to_int(v: str) -> int | None:
        v = _clean(v)
        if not v:
            return None
        try:
            return int(float(v))
        except ValueError:
            return None

    return {
        "duration": _to_int(parts[0]),
        "webpage_url": _clean(parts[1]),
        "live_status": _clean(parts[2]),
        "availability": _clean(parts[3]),
        "age_limit": _to_int(parts[4]) or 0,
    }
