"""YouTube caption fetch (via yt-dlp) and WebVTT → SRT conversion.

Manual (uploader-provided) captions only by default; auto-captions are
opt-in via the `auto_ok` flag.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

from core import ytdlp


class NoCaptionsAvailable(RuntimeError):
    """yt-dlp returned no caption file for the requested language/kind."""


_VTT_TS = re.compile(r"(\d{2}:\d{2}:\d{2})\.(\d{3})")


def vtt_to_srt(vtt: str) -> str:
    """Convert WebVTT text to SRT. Drops cue settings + WEBVTT header."""
    lines = vtt.splitlines()
    try:
        i = lines.index("")
        body = lines[i + 1 :]
    except ValueError:
        body = lines

    blocks: list[list[str]] = []
    cur: list[str] = []
    for line in body:
        if line.strip() == "":
            if cur:
                blocks.append(cur)
                cur = []
        else:
            cur.append(line)
    if cur:
        blocks.append(cur)

    out: list[str] = []
    n = 0
    for blk in blocks:
        ts_idx = next((i for i, ln in enumerate(blk) if "-->" in ln), None)
        if ts_idx is None:
            continue
        ts_line = blk[ts_idx]
        ts_line = ts_line.split("  ")[0]
        ts_line = _VTT_TS.sub(r"\1,\2", ts_line)
        text_lines = blk[ts_idx + 1 :]
        if not text_lines:
            continue
        n += 1
        out.append(str(n))
        out.append(ts_line)
        out.extend(text_lines)
        out.append("")
    return "\n".join(out)


def _list_available_sub_langs(video_id: str, *, auto_ok: bool = False) -> list[str]:
    """Query yt-dlp for the languages of the video's manual subtitles.

    Returns the language codes in YouTube's listed order (typically the
    uploader's chosen primary first). Empty list if yt-dlp errors out.
    Used by fetch_manual_captions ONLY for ``lang == "auto"`` — to accept
    the channel's default manual track. A specific language is strict and
    never consults this list.
    """
    if not ytdlp.is_installed():
        return []
    cmd = [
        str(ytdlp.ytdlp_path()),
        "--list-subs",
        "--skip-download",
        f"https://www.youtube.com/watch?v={video_id}",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return []
    if proc.returncode != 0:
        return []
    out = proc.stdout
    # Output format:
    #   [info] Available subtitles for <id>:
    #   Language Name       Formats
    #   en       English    vtt, srt, ...
    #   de       Deutsch    vtt, srt, ...
    in_manual = False
    in_auto = False
    langs: list[str] = []
    for raw in out.splitlines():
        line = raw.strip()
        low = line.lower()
        if "available subtitles" in low:
            in_manual, in_auto = True, False
            continue
        if "available automatic captions" in low:
            in_manual, in_auto = False, auto_ok
            continue
        if not (in_manual or in_auto):
            continue
        # Skip the header row "Language Name Formats".
        if line.startswith("Language") or not line:
            continue
        code = line.split(None, 1)[0]
        # Lang codes are alpha or alpha-alpha (e.g., en, en-en, mfe-ar).
        if code and code[0].isalpha():
            langs.append(code)
    return langs


def fetch_manual_captions(
    video_id: str,
    out_basename: Path,
    *,
    lang: str = "en",
    auto_ok: bool = False,
) -> Path:
    """Download captions for `video_id`. Returns path to converted .srt.

    `out_basename` is e.g. `/tmp/xyz/video` (no extension); yt-dlp will
    write `<basename>.<lang>.vtt` next to it.

    Language rule:
      * A specific language (e.g. ``lang="de"``) is STRICT: only that
        language is ever requested. If the video has no manual track in
        that language, ``NoCaptionsAvailable`` is raised (the caller then
        falls back to whisper). There is deliberately NO ``en``/other-
        language fallback — asking for German must never silently import
        an English track.
      * ``lang="auto"`` is LOOSE: it accepts the channel's default manual
        track. The available manual languages are probed once (via
        ``--list-subs``) in YouTube's listed order — channel default
        first — and tried in turn. If none exist, ``NoCaptionsAvailable``
        is raised (→ whisper).
    """
    if not ytdlp.is_installed():
        raise NoCaptionsAvailable("yt-dlp not installed")

    # Build the candidate-language list. "auto" → whatever manual tracks
    # the video actually has (channel default first); a specific language
    # → that language ONLY (strict, no fallback). Dedup, preserve order.
    if lang == "auto":
        raw_candidates = _list_available_sub_langs(video_id, auto_ok=auto_ok)
    else:
        raw_candidates = [lang]
    candidates: list[str] = []
    seen: set[str] = set()
    for code in raw_candidates:
        if code and code not in seen:
            candidates.append(code)
            seen.add(code)

    last_err = ""
    for try_lang in candidates:
        extra = ["--sub-langs", try_lang, "--skip-download", "--sub-format", "vtt"]
        if auto_ok:
            extra.insert(0, "--write-auto-subs")
        cmd = [
            str(ytdlp.ytdlp_path()),
            "--write-subs",
            *extra,
            "-o",
            str(out_basename),
            f"https://www.youtube.com/watch?v={video_id}",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            last_err = proc.stderr.strip() or "yt-dlp non-zero exit"
            continue
        vtt_path = out_basename.with_suffix(f".{try_lang}.vtt")
        if not vtt_path.exists():
            last_err = f"no caption file produced for lang={try_lang}"
            continue
        srt_path = out_basename.with_suffix(".srt")
        srt_path.write_text(vtt_to_srt(vtt_path.read_text(encoding="utf-8")), encoding="utf-8")
        return srt_path

    raise NoCaptionsAvailable(last_err or "no caption track found")
