"""``download_phase`` already-on-disk shortcut.

Two failure modes the shortcut closes:

1. **Slug drift** — earlier runs wrote `<YYYY-MM-DD>_<real-ep>_<title>.mp3`
   but the orphan-recovery / re-download path rebuilds the slug with
   ``episode_number='0000'`` (because ``ep_num_map`` only carries the
   current run's feed-fetch). Whisper-cli was being handed a path that
   didn't exist on disk → ``exit 2`` + usage text. Tested user impact:
   63 episodes stuck in ``failed`` after a full retry pass.

2. **Local-file ingest** — ``ingest_file`` writes ``mp3_url=file://…``
   plus a ``local_path:<guid>`` meta key. Pre-fix the URL hit
   ``download_mp3`` → ``safe_url`` rejected scheme ``file`` →
   download failure. Now we read ``local_path`` and stage the file.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

from core.pipeline import _find_existing_audio, download_phase


def test_find_existing_audio_matches_date_prefix_and_title(tmp_path):
    """Same date + title fragment = match, regardless of episode_number
    digits in between."""
    audio = tmp_path / "show" / "audio"
    audio.mkdir(parents=True)
    real = audio / "2022-01-24_0102_L'Immo feiert die 100. Folge.mp3"
    real.write_bytes(b"x" * 100)
    out = _find_existing_audio(audio, "2022-01-24T07:00:00", "L'Immo feiert die 100. Folge")
    assert out == real


def test_find_existing_audio_picks_largest_when_ambiguous(tmp_path):
    """Two same-date files matching title fragment — pick the largest
    (heuristic: real audio > partial / leftover)."""
    audio = tmp_path / "show" / "audio"
    audio.mkdir(parents=True)
    small = audio / "2022-01-24_0000_L'Immo feiert die 100. Folge.mp3"
    small.write_bytes(b"x" * 10)  # partial
    big = audio / "2022-01-24_0102_L'Immo feiert die 100. Folge.mp3"
    big.write_bytes(b"x" * 1_000_000)  # real
    out = _find_existing_audio(audio, "2022-01-24", "L'Immo feiert die 100. Folge")
    assert out == big


def test_find_existing_audio_skips_unrelated_titles(tmp_path):
    """Same date but different title → no match (would otherwise cross
    two episodes from the same publish day)."""
    audio = tmp_path / "show" / "audio"
    audio.mkdir(parents=True)
    other = audio / "2022-01-24_0103_Eine ganz andere Folge ueber Steuern.mp3"
    other.write_bytes(b"x" * 100)
    out = _find_existing_audio(audio, "2022-01-24", "L'Immo feiert die 100. Folge")
    assert out is None


def test_find_existing_audio_returns_none_for_missing_dir(tmp_path):
    out = _find_existing_audio(tmp_path / "nope", "2024-01-01", "x")
    assert out is None


def test_find_existing_audio_returns_none_for_blank_date(tmp_path):
    out = _find_existing_audio(tmp_path, "", "x")
    assert out is None


def test_find_existing_audio_handles_m4a_and_mp4(tmp_path):
    """Pre-fix orphan recovery globbed only `.mp3`; the user has
    podcasts with `.mp4` / `.m4a` enclosures (hausverwalter-inside).
    The shortcut must accept any audio container."""
    audio = tmp_path / "show" / "audio"
    audio.mkdir(parents=True)
    f = audio / "2017-10-26_0011_Wie Du deine Vorgaenge automatisieren.m4a"
    f.write_bytes(b"x" * 100)
    out = _find_existing_audio(audio, "2017-10-26", "Wie Du deine Vorgaenge automatisieren")
    assert out == f


def test_download_phase_short_circuits_on_existing_file(tmp_path, monkeypatch):
    """End-to-end: existing-on-disk file → download_phase persists
    mp3_path + flips to DOWNLOADED without invoking download_mp3."""
    output_root = tmp_path / "out"
    audio = output_root / "limmo" / "audio"
    audio.mkdir(parents=True)
    real_file = audio / "2022-01-24_0102_L'Immo feiert die 100. Folge.mp3"
    real_file.write_bytes(b"x" * 100)

    # Stub the state + library + downloader. We assert download_mp3 is
    # NOT called — that's the point of the shortcut.
    state = MagicMock()
    state.reserve_slug.side_effect = lambda guid, base_slug: base_slug
    state.get_episode.return_value = {
        "guid": "g",
        "show_slug": "limmo",
        "title": "L'Immo feiert die 100. Folge",
        "pub_date": "2022-01-24T07:00:00",
        "mp3_url": "https://example.com/x.mp3",
    }
    library = MagicMock()
    library.check_dedup.return_value = MagicMock(matched=False)
    download_called = []
    monkeypatch.setattr("core.pipeline.download_mp3", lambda *a, **kw: download_called.append(a))

    from core.pipeline import PipelineContext

    ctx = PipelineContext(
        state=state,
        library=library,
        output_root=output_root,
        whisper_prompt="",
        retention_days=7,
        delete_mp3_after=False,
    )

    outcome = download_phase("g", ctx, episode_number="0000")

    assert outcome.result is None, "shortcut should produce a transcribe-bound outcome"
    assert outcome.mp3_path == real_file
    assert outcome.slug == real_file.stem
    assert download_called == [], "download_mp3 must NOT be called when a matching file exists"
    state.set_mp3_path.assert_called_once_with("g", str(real_file))


def test_download_phase_uses_local_path_meta_for_file_uri(tmp_path, monkeypatch):
    """``ingest_file`` writes mp3_url=file:// + local_path meta. The
    pipeline must consult local_path instead of feeding a file:// URL
    to safe_url (which would reject the scheme)."""
    src = tmp_path / "drop" / "talk.wav"
    src.parent.mkdir()
    src.write_bytes(b"\x00" * 1024)

    state = MagicMock()
    state.reserve_slug.side_effect = lambda guid, base_slug: base_slug
    state.get_episode.return_value = {
        "guid": "sha256:abc",
        "show_slug": "files",
        "title": "talk",
        "pub_date": "2026-04-23",
        "mp3_url": src.as_uri(),
    }
    state.get_meta.return_value = str(src)
    library = MagicMock()
    library.check_dedup.return_value = MagicMock(matched=False)
    monkeypatch.setattr(
        "core.pipeline.download_mp3", lambda *a, **kw: pytest.fail("must not be called")
    )

    from core.pipeline import PipelineContext

    ctx = PipelineContext(
        state=state,
        library=library,
        output_root=tmp_path / "out",
        whisper_prompt="",
        retention_days=7,
        delete_mp3_after=False,
    )

    outcome = download_phase("sha256:abc", ctx, episode_number="0000")

    assert outcome.result is None
    assert outcome.mp3_path == src
    state.set_mp3_path.assert_called_once_with("sha256:abc", str(src))


def test_download_phase_file_uri_with_missing_local_path_fails_clearly(tmp_path, monkeypatch):
    """If the local source is gone (file deleted between ingest and
    transcribe), surface a readable LocalFileMissing error rather than
    the opaque safe_url 'refused scheme file' rejection."""
    state = MagicMock()
    state.reserve_slug.side_effect = lambda guid, base_slug: base_slug
    state.get_episode.return_value = {
        "guid": "sha256:dead",
        "show_slug": "files",
        "title": "ghost",
        "pub_date": "2026-04-23",
        "mp3_url": "file:///tmp/does/not/exist.wav",
    }
    state.get_meta.return_value = ""
    library = MagicMock()
    library.check_dedup.return_value = MagicMock(matched=False)
    monkeypatch.setattr(
        "core.pipeline.download_mp3", lambda *a, **kw: pytest.fail("must not be called")
    )

    from core.pipeline import PipelineContext

    ctx = PipelineContext(
        state=state,
        library=library,
        output_root=tmp_path / "out",
        whisper_prompt="",
        retention_days=7,
        delete_mp3_after=False,
    )

    outcome = download_phase("sha256:dead", ctx, episode_number="0000")

    assert outcome.result is not None
    assert outcome.result.action == "failed"
    assert "LocalFileMissing" in outcome.result.detail
