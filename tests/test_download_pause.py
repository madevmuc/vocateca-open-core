"""Pausable individual downloads (2.4)."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
import respx

from core.downloader import DownloadPaused, download_mp3

_URL = "https://cdn.test/ep.mp3"
_BODY = b"ID3" + b"\x00" * 200  # valid audio magic + payload


def _mock(content_type="audio/mpeg"):
    respx.head(_URL).mock(
        return_value=httpx.Response(200, headers={"content-length": str(len(_BODY))})
    )
    respx.get(_URL).mock(
        return_value=httpx.Response(200, content=_BODY, headers={"content-type": content_type})
    )


@respx.mock
def test_pause_halts_and_leaves_part(tmp_path):
    _mock()
    dest = tmp_path / "ep.mp3"
    calls = {"n": 0}

    def pause_check():
        calls["n"] += 1
        return calls["n"] > 1  # let the first chunk through, then pause

    with pytest.raises(DownloadPaused):
        download_mp3(_URL, dest, chunk=8, pause_check=pause_check)

    assert not dest.exists()  # never finalised
    part = dest.with_suffix(dest.suffix + ".part")
    assert part.exists()  # partial preserved for resume


@respx.mock
def test_unpaused_download_completes(tmp_path):
    _mock()
    dest = tmp_path / "ep.mp3"
    result = download_mp3(_URL, dest, chunk=8, pause_check=lambda: False)
    assert dest.exists()
    assert dest.read_bytes() == _BODY
    assert result.final_size == len(_BODY)


@respx.mock
def test_no_pause_check_is_noop(tmp_path):
    _mock()
    dest = tmp_path / "ep.mp3"
    download_mp3(_URL, dest, chunk=8)
    assert dest.exists()
