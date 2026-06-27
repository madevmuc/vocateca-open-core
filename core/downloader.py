"""Resumable MP3 downloader (Content-Length parity check)."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from pathlib import Path

import httpx

from core.http import get_client
from core.security import (
    MAX_MP3_BYTES,
    DownloadTooLargeError,
    is_allowed_audio_content_type,
    looks_like_audio,
    safe_url,
)

# Content-Type values that are accepted optimistically: many small podcast
# hosts and CDNs serve MP3 with a generic binary type. We verify the first
# chunk's magic bytes downstream so a real text/html or PDF served as
# octet-stream still fails fast, just at byte level instead of header level.
_OCTET_STREAM_PREFIXES = ("application/octet-stream", "binary/octet-stream")

logger = logging.getLogger(__name__)

# Retry budget for transient network failures. Per attempt we sleep
# RETRY_DELAYS[attempt] before the next try. Total worst-case wait
# on 3 failed attempts is 1+5+20 = 26 seconds before we give up.
RETRY_DELAYS = (1.0, 5.0, 20.0)

# HTTP status codes that deserve a retry. 4xx means the URL is gone
# for good (404 episode pulled, 403 auth-gated, 410 gone) — no point
# hammering it.
RETRIABLE_STATUSES = frozenset({429, 500, 502, 503, 504})


def _should_retry(exc: BaseException) -> bool:
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in RETRIABLE_STATUSES
    # Timeouts, connection errors, protocol errors, pool errors — all
    # transient. TooLarge / security errors propagate up untouched.
    return isinstance(
        exc,
        (httpx.TimeoutException, httpx.NetworkError, httpx.RemoteProtocolError, httpx.PoolTimeout),
    )


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
)


@dataclass(frozen=True)
class DownloadResult:
    bytes_written: int
    skipped: bool
    final_size: int


def _expected_size(url: str, timeout: float = 10.0) -> int:
    r = get_client().head(
        url, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=timeout
    )
    r.raise_for_status()
    return int(r.headers.get("content-length", "0") or 0)


def _head(url: str, timeout: float = 10.0) -> httpx.Response:
    r = get_client().head(
        url, headers={"User-Agent": USER_AGENT}, follow_redirects=True, timeout=timeout
    )
    r.raise_for_status()
    return r


class DownloadPaused(RuntimeError):
    """Raised when a per-download pause was requested mid-stream (2.4).

    The ``.part`` file is preserved so a later call resumes from the offset."""


def download_mp3(
    url: str,
    dest: Path,
    *,
    chunk: int = 1 << 16,
    timeout: float = 60.0,
    max_bytes: int = MAX_MP3_BYTES,
    pause_check=None,
    _sleep=time.sleep,
) -> DownloadResult:
    """Download an MP3 with retry on transient network failures.

    Retries 3×: delays 1s, 5s, 20s. Retries on 5xx / 429 / timeouts /
    network errors. Does NOT retry on 4xx (URL permanently gone),
    DownloadTooLargeError, or safe_url guard violations.
    """
    safe_url(url)
    dest.parent.mkdir(parents=True, exist_ok=True)

    last_exc: BaseException | None = None
    for attempt, delay in enumerate(RETRY_DELAYS):
        try:
            return _download_once(
                url,
                dest,
                chunk=chunk,
                timeout=timeout,
                max_bytes=max_bytes,
                pause_check=pause_check,
            )
        except DownloadPaused:
            raise  # never retry a deliberate pause
        except Exception as e:
            if not _should_retry(e):
                raise
            last_exc = e
            logger.warning(
                "download transient failure attempt %d/%d — sleeping %.0fs then retrying: %s",
                attempt + 1,
                len(RETRY_DELAYS),
                delay,
                e,
            )
            _sleep(delay)
    # All retries exhausted.
    assert last_exc is not None
    raise last_exc


def _download_once(
    url: str, dest: Path, *, chunk: int, timeout: float, max_bytes: int, pause_check=None
) -> DownloadResult:
    expected = 0
    accept_ranges = False
    try:
        head = _head(url, timeout=timeout)
        expected = int(head.headers.get("content-length", "0") or 0)
        accept_ranges = head.headers.get("accept-ranges", "").lower() == "bytes"
    except httpx.HTTPError:
        pass  # Some servers block HEAD — fall through to GET.
    if expected and expected > max_bytes:
        raise DownloadTooLargeError(
            f"remote advertises {expected} bytes — refusing (cap {max_bytes})"
        )
    if dest.exists() and expected and dest.stat().st_size == expected:
        return DownloadResult(0, True, expected)

    tmp = dest.with_suffix(dest.suffix + ".part")

    # Resume support: if a .part file exists and the server advertises
    # Range support + a known Content-Length, try to continue from the
    # partial offset instead of re-downloading from zero.
    resume_from = 0
    if tmp.exists() and expected and accept_ranges:
        partial_size = tmp.stat().st_size
        if partial_size == expected:
            # Already fully downloaded, just never finalized.
            tmp.replace(dest)
            return DownloadResult(0, True, dest.stat().st_size)
        if partial_size > expected:
            logger.debug(
                "partial %s larger than expected (%d > %d) — discarding",
                tmp,
                partial_size,
                expected,
            )
            tmp.unlink()
        elif 0 < partial_size < expected:
            resume_from = partial_size

    written = 0
    headers: dict[str, str] = {"User-Agent": USER_AGENT}
    if resume_from:
        headers["Range"] = f"bytes={resume_from}-"

    with get_client().stream(
        "GET", url, headers=headers, follow_redirects=True, timeout=timeout
    ) as r:
        r.raise_for_status()
        # Content-Type sniff — reject obvious non-audio (HTML, JSON, etc.).
        # The allowlist now includes octet-stream variants (many podcast hosts
        # serve MP3 with a generic binary type); we verify those with a
        # magic-byte sniff on the first chunk below.
        ct = r.headers.get("content-type", "")
        if ct and not is_allowed_audio_content_type(ct):
            raise ValueError(f"refusing non-audio Content-Type: {ct!r}")
        ct_lower = ct.lower().split(";", 1)[0].strip()
        needs_magic_sniff = any(ct_lower.startswith(p) for p in _OCTET_STREAM_PREFIXES)

        # If we asked for a Range and got 200 back, the server ignored it.
        # Truncate the partial and restart from zero.
        mode = "wb"
        if resume_from:
            if r.status_code == 206:
                mode = "ab"
                written = resume_from
            else:
                logger.debug(
                    "server returned %d to Range request — restarting from zero",
                    r.status_code,
                )
                resume_from = 0

        first_chunk = True
        with tmp.open(mode) as f:
            for block in r.iter_bytes(chunk):
                if first_chunk:
                    # Defence-in-depth: octet-stream is accepted optimistically
                    # at header level, but the leading bytes must look like a
                    # known audio container. A real text/html or PDF served
                    # with a binary CT still fails fast here.
                    # Skip the sniff when resuming a partial — the first block
                    # is mid-file and won't carry a header magic.
                    if needs_magic_sniff and not resume_from and not looks_like_audio(block):
                        f.close()
                        try:
                            tmp.unlink()
                        except OSError:
                            pass
                        raise ValueError(
                            f"refusing non-audio payload (CT was {ct!r}, "
                            "magic bytes don't match audio)"
                        )
                    first_chunk = False
                # Per-download pause (2.4): flush what we have and bail, leaving
                # the .part on disk so a later call resumes from here.
                if pause_check is not None and pause_check():
                    f.flush()
                    raise DownloadPaused(f"download paused at {written} bytes")
                f.write(block)
                written += len(block)
                if written > max_bytes:
                    f.close()
                    try:
                        tmp.unlink()
                    except OSError:
                        pass
                    raise DownloadTooLargeError(f"stream exceeded {max_bytes} bytes without EOF")
    tmp.replace(dest)
    return DownloadResult(written, False, dest.stat().st_size)
