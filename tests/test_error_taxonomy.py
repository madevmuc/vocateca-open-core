"""Error taxonomy + transient classification (6.1)."""

from __future__ import annotations

import httpx

from core.errors import (
    DISK,
    FORMAT,
    NETWORK,
    NOT_FOUND,
    TOO_LARGE,
    UNKNOWN,
    WHISPER,
    categorize,
    is_transient,
)
from core.pipeline import DiskSpaceError
from core.security import DownloadTooLargeError
from core.transcriber import TranscriptionError


def test_network_errors():
    assert categorize(httpx.ConnectError("boom")) == NETWORK
    assert categorize(httpx.ReadTimeout("slow")) == NETWORK


def test_not_found():
    resp = httpx.Response(404, request=httpx.Request("GET", "http://x/y"))
    err = httpx.HTTPStatusError("404", request=resp.request, response=resp)
    assert categorize(err) == NOT_FOUND


def test_too_large():
    assert categorize(DownloadTooLargeError("file too big")) == TOO_LARGE


def test_disk():
    assert categorize(DiskSpaceError("only 1 MB free")) == DISK


def test_whisper():
    assert categorize(TranscriptionError("whisper-cli exit 2")) == WHISPER


def test_format_from_message():
    assert categorize(ValueError("unsupported audio format / container")) == FORMAT


def test_unknown_default():
    assert categorize(RuntimeError("???")) == UNKNOWN


def test_transient_classification():
    assert is_transient(NETWORK) is True
    assert is_transient(DISK) is True
    assert is_transient(NOT_FOUND) is False
    assert is_transient(WHISPER) is False
    assert is_transient(UNKNOWN) is False


def test_record_failure_retry_vs_terminal(tmp_path):
    from core.state import StateStore

    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    s.upsert_episode(show_slug="sh", guid="g1", title="T", pub_date="2026-01-01", mp3_url="u")
    # Transient retry → status back to pending, attempts bumped.
    n = s.record_failure("g1", NETWORK, "net err", retry=True)
    assert n == 1
    ep = s.get_episode("g1")
    assert ep["status"] == "pending"
    assert ep["error_category"] == NETWORK
    # Terminal failure → FAILED, attempts bumped again.
    n2 = s.record_failure("g1", WHISPER, "whisper err", retry=False)
    assert n2 == 2
    ep = s.get_episode("g1")
    assert ep["status"] == "failed"
    assert ep["error_category"] == WHISPER


def test_attempts_reset_on_success(tmp_path):
    from core.state import EpisodeStatus, StateStore

    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    s.upsert_episode(show_slug="sh", guid="g1", title="T", pub_date="2026-01-01", mp3_url="u")
    s.record_failure("g1", NETWORK, "net err", retry=True)
    assert s.get_episode("g1")["attempts"] == 1
    # A later success clears attempts + category so a future failure gets full budget.
    s.set_status("g1", EpisodeStatus.DONE)
    ep = s.get_episode("g1")
    assert ep["attempts"] == 0
    assert ep["error_category"] is None


def test_should_retry_transient_under_cap_then_stops():
    from core.errors import should_retry

    assert should_retry(NETWORK, attempts=0, max_attempts=3) is True
    assert should_retry(NETWORK, attempts=2, max_attempts=3) is True
    assert should_retry(NETWORK, attempts=3, max_attempts=3) is False  # cap reached
    # permanent categories never retry
    assert should_retry(WHISPER, attempts=0, max_attempts=3) is False
    assert should_retry(NOT_FOUND, attempts=0, max_attempts=3) is False
