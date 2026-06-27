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


@respx.mock
def test_pipeline_pause_parks_as_paused_not_pending(tmp_path):
    # A paused download must park the episode as PAUSED so the claim loop won't
    # immediately re-grab it and re-pause in a tight loop.
    from core.library import LibraryIndex
    from core.pipeline import PipelineContext, download_phase
    from core.state import EpisodeStatus, StateStore

    _mock()
    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    s.upsert_episode(show_slug="sh", guid="g1", title="T", pub_date="2026-01-01", mp3_url=_URL)
    ctx = PipelineContext(
        state=s,
        library=LibraryIndex(tmp_path / "out"),
        output_root=tmp_path / "out",
        whisper_prompt="",
        retention_days=7,
        delete_mp3_after=False,
        download_pause_check=lambda guid: True,  # pause immediately
    )
    outcome = download_phase("g1", ctx, episode_number="0001")
    assert outcome.result is not None
    assert outcome.result.action == "deferred"
    assert s.get_episode("g1")["status"] == EpisodeStatus.PAUSED.value
