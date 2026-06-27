"""Error taxonomy for the pipeline (roadmap 6.1).

Maps exceptions raised during download/transcribe into a small set of stable
categories so the Failed tab can group failures and the pipeline can decide
which are worth an automatic retry (transient) vs. permanent.
"""

from __future__ import annotations

NETWORK = "network"
NOT_FOUND = "not_found"
TOO_LARGE = "too_large"
FORMAT = "format"
WHISPER = "whisper"
DISK = "disk"
UNKNOWN = "unknown"

# Categories worth an automatic retry with backoff.
_TRANSIENT = {NETWORK, DISK}


def is_transient(category: str) -> bool:
    return category in _TRANSIENT


def should_retry(category: str, attempts: int, max_attempts: int = 3) -> bool:
    """Whether a failure in ``category`` after ``attempts`` tries should be
    auto-retried: only transient categories, and only under the attempt cap."""
    return is_transient(category) and attempts < max_attempts


def categorize(exc: BaseException) -> str:
    """Classify an exception into a taxonomy category."""
    name = type(exc).__name__
    msg = str(exc).lower()

    # Explicit project exception types first.
    if name == "DiskSpaceError":
        return DISK
    if name == "DownloadTooLargeError":
        return TOO_LARGE
    if name == "TranscriptionError":
        return WHISPER

    # HTTP status — distinguish not-found from transient server/network errors.
    if name == "HTTPStatusError":
        status = getattr(getattr(exc, "response", None), "status_code", None)
        if status in (404, 410):
            return NOT_FOUND
        return NETWORK

    # httpx transport/timeout errors are all network-ish.
    mod = type(exc).__module__ or ""
    if mod.startswith("httpx") or "timeout" in name.lower() or "connect" in name.lower():
        return NETWORK

    # Message-based fallbacks.
    if "not found" in msg or "404" in msg:
        return NOT_FOUND
    if "too large" in msg or "exceeds" in msg:
        return TOO_LARGE
    if "disk" in msg or "no space" in msg:
        return DISK
    if "format" in msg or "codec" in msg or "container" in msg:
        return FORMAT
    if "network" in msg or "connection" in msg or "temporarily" in msg:
        return NETWORK
    return UNKNOWN
