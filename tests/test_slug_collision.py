"""Regression: two episodes that collapse to the same slug must not
share an on-disk path (audio OR transcript), and a missing audio file
must produce a legible error instead of whisper-cli's usage dump.

Root cause of the 2026-06-25 fix-flip-buy-hold failures: ``build_slug``
(``<date>_<ep_num>_<sanitized title>``) is not unique per episode. Two
distinct guids with the same publish date + title — feed re-uploads
(``Was modernisiere ich?`` appeared twice) or ``(1/2)``/``(2/2)`` parts
that ``_find_existing_audio`` cross-matched on a 20-char title prefix —
resolved to one shared ``<slug>.mp3`` + ``<slug>.md``. Under parallel
transcription with ``delete_mp3_after`` on, the first to finish unlinked
the shared mp3 (retention) and the second hit ``whisper-cli exit 2``
("no input files specified"); pairs that both "succeeded" silently
overwrote each other's transcript.

The error was also illegible: ``transcriber`` logged ``stderr[-400:]``,
but whisper prints ``error: input file not found`` at the *top* and a
~6 KB usage screen after, so the slice kept only the VAD-options tail.
"""

from pathlib import Path
from unittest.mock import patch

import pytest

from core.library import LibraryIndex
from core.pipeline import (
    PipelineContext,
    _find_existing_audio,
    download_phase,
    transcribe_phase,
)
from core.state import StateStore
from core.transcriber import TranscriptionError, transcribe_episode


def _ctx(tmp_path: Path, *, delete_mp3_after: bool = True) -> PipelineContext:
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    out = tmp_path / "out"
    out.mkdir()
    lib = LibraryIndex(out)
    return PipelineContext(
        state=state,
        library=lib,
        output_root=out,
        whisper_prompt="",
        retention_days=7,
        delete_mp3_after=delete_mp3_after,
    )


def _fake_download(url, dest, **kw):
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(b"\x00" * 4096)
    from core.downloader import DownloadResult

    return DownloadResult(4096, False, 4096)


_USAGE_TAIL = (
    "  -vsd N,    --vad-min-silence-duration-ms N [100    ] VAD min silence\n"
    "  -vmsd N,   --vad-max-speech-duration-s   N [FLT_MAX] VAD max speech\n"
    "  -vp N,     --vad-speech-pad-ms           N [30     ] VAD speech padding\n"
    "  -vo N,     --vad-samples-overlap         N [0.10   ] VAD samples overlap\n\n"
)


def _fake_whisper(cmd, *a, **kw):
    """Mirror whisper.cpp: a missing ``-f`` file → exit 2 + 'input file not
    found' followed by the long usage screen; otherwise write the outputs
    whisper would for the ``-of`` prefix."""
    f_path = None
    of_prefix = None
    for i, arg in enumerate(cmd):
        if arg == "-f":
            f_path = Path(cmd[i + 1])
        elif arg == "-of":
            of_prefix = Path(cmd[i + 1])

    class R:
        def __init__(self, rc, out="", err=""):
            self.returncode = rc
            self.stdout = out
            self.stderr = err

    if f_path is None or not f_path.exists():
        err = (
            f"error: input file not found '{f_path}'\n"
            f"error: no input files specified\n"
            f"usage: whisper-cli [options] file0 file1 ...\n{_USAGE_TAIL}"
        )
        return R(2, "", err)
    (of_prefix.parent / (of_prefix.name + ".txt")).write_text("word " * 500, encoding="utf-8")
    (of_prefix.parent / (of_prefix.name + ".srt")).write_text(
        "1\n00:00:00,000 --> 00:00:02,000\nx\n", encoding="utf-8"
    )
    return R(0)


# --------------------------------------------------------------------------
# 1. State-level: reserve_slug gives every guid a unique, stable slug.
# --------------------------------------------------------------------------


def test_reserve_slug_unique_per_guid(tmp_path: Path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    base = "2021-07-19_0000_Fix & Flip - Was modernisiere ich"
    a = state.reserve_slug("guid-A", base)
    b = state.reserve_slug("guid-B", base)
    assert a == base, "first claimant keeps the clean slug"
    assert b != a, "second guid must not collide on the same slug"
    assert b.startswith(base), "disambiguated slug stays human-readable"


def test_reserve_slug_idempotent(tmp_path: Path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    base = "2021-01-01_0000_Folge"
    first = state.reserve_slug("g", base)
    again = state.reserve_slug("g", base)
    assert first == again, "re-reserving for the same guid is stable across calls/runs"


# --------------------------------------------------------------------------
# 2. _find_existing_audio must not cross-match different episodes.
# --------------------------------------------------------------------------


def test_find_existing_audio_does_not_cross_match_part_numbers(tmp_path: Path):
    """'(1/2)' and '(2/2)' share the first 20 title chars. The drift
    recovery must NOT hand part 2 the part-1 file."""
    audio = tmp_path / "show" / "audio"
    audio.mkdir(parents=True)
    part1 = audio / "2021-11-04_0000_Fix & Flip - 10 Fragen an einen Makler (12).mp3"
    part1.write_bytes(b"x" * 1000)
    # Looking for part 2 while only part 1 is on disk.
    out = _find_existing_audio(audio, "2021-11-04", "Fix & Flip - 10 Fragen an einen Makler (2/2)")
    assert out is None, "part 2 must not adopt part 1's audio file"


# --------------------------------------------------------------------------
# 3. A missing audio file → clear error, not whisper's usage dump.
# --------------------------------------------------------------------------


def test_transcribe_episode_missing_input_gives_clear_error(tmp_path: Path):
    out = tmp_path / "out"
    out.mkdir()
    gone = tmp_path / "audio" / "gone.mp3"  # never created
    with pytest.raises(TranscriptionError) as ei:
        transcribe_episode(
            mp3_path=gone,
            output_dir=out,
            slug="2021-01-01_0000_gone",
            metadata={"guid": "g", "title": "gone", "pub_date": "2021-01-01"},
        )
    msg = str(ei.value)
    assert str(gone) in msg or gone.name in msg, "names the missing file"
    assert "VAD" not in msg, "must not be the whisper usage dump"


def test_exit2_error_surfaces_whispers_real_diagnostic(tmp_path: Path):
    """When whisper itself exits 2 (file existed at pre-flight but vanished,
    or any arg error), the raised error must include whisper's leading
    'error:' line — not only the usage tail that stderr[-400:] kept."""
    out = tmp_path / "out"
    out.mkdir()
    mp3 = tmp_path / "a.mp3"
    mp3.write_bytes(b"\x00" * 2048)  # exists at pre-flight

    err = (
        f"error: input file not found '{mp3}'\n"
        f"error: no input files specified\n"
        f"usage: whisper-cli [options] file0 file1 ...\n{_USAGE_TAIL}"
    )

    class R:
        returncode = 2
        stdout = ""
        stderr = err

    with patch("core.transcriber.subprocess.run", return_value=R()):
        with pytest.raises(TranscriptionError) as ei:
            transcribe_episode(
                mp3_path=mp3,
                output_dir=out,
                slug="2021-01-01_0000_a",
                metadata={"guid": "g", "title": "a", "pub_date": "2021-01-01"},
            )
    assert "input file not found" in str(ei.value), "real diagnostic must survive"


# --------------------------------------------------------------------------
# 4. Headline: two same-title/same-date episodes must not collide.
# --------------------------------------------------------------------------


def test_duplicate_title_episodes_get_distinct_outputs(tmp_path: Path):
    """The 'Was modernisiere ich?' case: two distinct guids, identical
    title + pub_date. Download BOTH before transcribing EITHER (the
    parallel-run TOCTOU), then transcribe in order. Neither may fail and
    they must produce two distinct transcripts."""
    ctx = _ctx(tmp_path, delete_mp3_after=True)
    for g in ("guid-1", "guid-2"):
        ctx.state.upsert_episode(
            show_slug="fix-flip",
            guid=g,
            title="Fix & Flip - Was modernisiere ich?",
            pub_date="2021-07-19",
            mp3_url=f"http://x/{g}.mp3",
        )

    with (
        patch("core.pipeline.download_mp3", side_effect=_fake_download),
        patch("core.transcriber.subprocess.run", side_effect=_fake_whisper),
    ):
        o1 = download_phase("guid-1", ctx)
        o2 = download_phase("guid-2", ctx)
        assert o1.result is None and o2.result is None
        assert o1.slug != o2.slug, "the two episodes must claim different slugs"
        assert o1.mp3_path != o2.mp3_path, "they must not share an audio file"

        r1 = transcribe_phase(o1, ctx)
        r2 = transcribe_phase(o2, ctx)

    assert r1.action == "transcribed", f"first episode failed: {r1.detail}"
    assert r2.action == "transcribed", f"second episode failed: {r2.detail}"
    mds = sorted((ctx.output_root / "fix-flip").glob("*.md"))
    assert len(mds) == 2, f"expected two distinct transcripts, got {[p.name for p in mds]}"


def test_retention_keeps_mp3_still_referenced_by_active_episode(tmp_path: Path):
    """Defense in depth: if two episodes ever do point at the same mp3
    (legacy rows), the first to finish must not delete the file out from
    under the second that's still pending/downloaded."""
    ctx = _ctx(tmp_path, delete_mp3_after=True)
    show_dir = ctx.output_root / "demo"
    audio = show_dir / "audio"
    audio.mkdir(parents=True)
    shared = audio / "2021-01-01_0000_shared.mp3"
    shared.write_bytes(b"\x00" * 4096)

    for g in ("g1", "g2"):
        ctx.state.upsert_episode(
            show_slug="demo", guid=g, title="shared", pub_date="2021-01-01", mp3_url="http://x"
        )
        ctx.state.set_mp3_path(g, str(shared))
    from core.state import EpisodeStatus

    ctx.state.set_status("g2", EpisodeStatus.DOWNLOADED)  # still needs the file

    # Forge g1's transcribe outcome directly against the shared file.
    from core.pipeline import DownloadOutcome

    o1 = DownloadOutcome(
        guid="g1",
        mp3_path=shared,
        show_dir=show_dir,
        slug="2021-01-01_0000_shared",
        ep=ctx.state.get_episode("g1"),
    )
    with patch("core.transcriber.subprocess.run", side_effect=_fake_whisper):
        transcribe_phase(o1, ctx)
    assert shared.exists(), "must not unlink an mp3 another active episode still references"
