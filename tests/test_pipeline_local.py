"""Pipeline integration for local-source shows."""

from pathlib import Path
from unittest.mock import patch

from core.library import LibraryIndex
from core.pipeline import PipelineContext, process_episode
from core.state import StateStore


def _local_ctx(tmp_path: Path) -> PipelineContext:
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
        delete_mp3_after=False,
        source="local",
    )


def _seed_local_episode(ctx: PipelineContext, src: Path, *, guid: str = "sha256:deadbeef") -> None:
    ctx.state.upsert_episode(
        show_slug="files",
        guid=guid,
        title=src.stem,
        pub_date="2026-04-15",
        mp3_url=f"file://{src}",
        duration_sec=42,
    )
    ctx.state.set_meta(f"local_path:{guid}", str(src))


def test_local_episode_copies_source_and_transcribes(tmp_path: Path):
    src = tmp_path / "a.wav"
    src.write_bytes(b"RIFF\x00\x00\x00\x00WAVEfmt fake wav bytes")

    ctx = _local_ctx(tmp_path)
    _seed_local_episode(ctx, src)

    class FakeResult:
        md_path = tmp_path / "out" / "files" / "x.md"
        srt_path = tmp_path / "out" / "files" / "x.srt"
        word_count = 10

    def fake_transcribe(*a, **kw):
        FakeResult.md_path.parent.mkdir(parents=True, exist_ok=True)
        FakeResult.md_path.write_text("# x\n\nhello", encoding="utf-8")
        FakeResult.srt_path.write_text(
            "1\n00:00:00,000 --> 00:00:01,000\nhello\n", encoding="utf-8"
        )
        return FakeResult

    with patch("core.pipeline.transcribe_episode", side_effect=fake_transcribe):
        r = process_episode("sha256:deadbeef", ctx)

    assert r.action == "transcribed"
    assert ctx.state.get_episode("sha256:deadbeef")["status"] == "done"
    # Source file must still exist (delete_mp3_after=False above).
    assert src.exists()


def test_local_episode_records_mp3_path_for_orphan_recovery(tmp_path: Path):
    src = tmp_path / "a.wav"
    src.write_bytes(b"RIFF\x00\x00\x00\x00WAVEfmt fake wav bytes")

    ctx = _local_ctx(tmp_path)
    _seed_local_episode(ctx, src)

    # Before processing: no staged path recorded yet.
    pre = ctx.state.get_episode("sha256:deadbeef").get("mp3_path")
    assert pre is None or pre == ""

    class FakeResult:
        md_path = tmp_path / "out" / "files" / "x.md"
        srt_path = tmp_path / "out" / "files" / "x.srt"
        word_count = 10

    def fake_transcribe(*a, **kw):
        FakeResult.md_path.parent.mkdir(parents=True, exist_ok=True)
        FakeResult.md_path.write_text("# x\n\nhello", encoding="utf-8")
        FakeResult.srt_path.write_text(
            "1\n00:00:00,000 --> 00:00:01,000\nhello\n", encoding="utf-8"
        )
        return FakeResult

    with patch("core.pipeline.transcribe_episode", side_effect=fake_transcribe):
        process_episode("sha256:deadbeef", ctx)

    ep = ctx.state.get_episode("sha256:deadbeef")
    recorded = ep["mp3_path"]
    assert isinstance(recorded, str) and recorded
    # Extension must be preserved (staged keeps the source suffix).
    assert recorded.endswith(".wav")


def test_local_episode_fails_gracefully_when_source_missing(tmp_path: Path):
    src = tmp_path / "gone.wav"
    ctx = _local_ctx(tmp_path)
    _seed_local_episode(ctx, src, guid="sha256:missing")

    r = process_episode("sha256:missing", ctx)
    assert r.action == "failed"
    assert "source file" in r.detail.lower()
    assert ctx.state.get_episode("sha256:missing")["status"] == "failed"
