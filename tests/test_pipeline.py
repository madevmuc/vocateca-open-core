from pathlib import Path
from unittest.mock import patch

from core.library import LibraryIndex
from core.pipeline import PipelineContext, build_slug, process_episode
from core.state import StateStore


def _ctx(tmp_path: Path) -> PipelineContext:
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
        delete_mp3_after=True,
    )


def test_build_slug_uses_umlauts():
    s = build_slug("2026-04-15", "Wohnräume für Anfänger", "0042")
    assert s == "2026-04-15_0042_Wohnräume für Anfänger"


def test_dedup_skip(tmp_path: Path):
    ctx = _ctx(tmp_path)
    (ctx.output_root / "demo").mkdir()
    (ctx.output_root / "demo" / "existing.md").write_text(
        '---\nguid: "g1"\n---\n', encoding="utf-8"
    )
    ctx.library.scan()
    ctx.state.upsert_episode(
        show_slug="demo", guid="g1", title="X", pub_date="2026-04-01", mp3_url="http://x/1.mp3"
    )
    result = process_episode("g1", ctx)
    assert result.action == "skipped"
    assert ctx.state.get_episode("g1")["status"] == "done"


def test_full_pipeline_success(tmp_path: Path):
    ctx = _ctx(tmp_path)
    ctx.state.upsert_episode(
        show_slug="demo",
        guid="gx",
        title="Folge 1",
        pub_date="2026-04-15",
        mp3_url="http://x/1.mp3",
    )

    def fake_download(url, dest, **kw):
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"ID3" + b"\x00" * 1024)  # valid audio magic for integrity check
        from core.downloader import DownloadResult

        return DownloadResult(1027, False, 1027)

    def fake_whisper(cmd, *a, **kw):
        import re

        prefix = None
        for i, arg in enumerate(cmd):
            if arg == "-of":
                prefix = Path(cmd[i + 1])
                break
        # whisper-cli appends the extension to the -of prefix; mirror that.
        (prefix.parent / (prefix.name + ".txt")).write_text("word " * 500, encoding="utf-8")
        (prefix.parent / (prefix.name + ".srt")).write_text(
            "1\n00:00 --> 00:02\nx\n", encoding="utf-8"
        )

        class R:
            returncode = 0
            stdout = ""
            stderr = ""

        return R()

    with (
        patch("core.pipeline.download_mp3", side_effect=fake_download),
        patch("core.transcriber.subprocess.run", side_effect=fake_whisper),
    ):
        r = process_episode("gx", ctx)
    assert r.action == "transcribed"
    assert ctx.state.get_episode("gx")["status"] == "done"
    # MP3 should be deleted (retention on)
    mp3s = list((ctx.output_root / "demo" / "audio").glob("*.mp3"))
    assert mp3s == []
    # Transcript written
    mds = list((ctx.output_root / "demo").glob("*.md"))
    assert len(mds) == 1
    assert 'guid: "gx"' in mds[0].read_text()


def test_download_failure_marks_failed(tmp_path: Path):
    ctx = _ctx(tmp_path)
    ctx.state.upsert_episode(
        show_slug="demo", guid="gx", title="T", pub_date="2026-04-15", mp3_url="http://x"
    )

    # A permanent (non-transient) error fails terminally. Transient categories
    # (network/disk) are auto-retried instead — see test_error_taxonomy.
    def boom(*a, **kw):
        raise RuntimeError("unrecoverable parse glitch")

    with patch("core.pipeline.download_mp3", side_effect=boom):
        r = process_episode("gx", ctx)
    assert r.action == "failed"
    assert ctx.state.get_episode("gx")["status"] == "failed"
    assert "unrecoverable parse glitch" in ctx.state.get_episode("gx")["error_text"]


def test_transient_download_failure_is_retried(tmp_path: Path):
    ctx = _ctx(tmp_path)
    ctx.state.upsert_episode(
        show_slug="demo", guid="gx", title="T", pub_date="2026-04-15", mp3_url="http://x"
    )

    def boom(*a, **kw):
        raise RuntimeError("network down")

    with patch("core.pipeline.download_mp3", side_effect=boom):
        r = process_episode("gx", ctx)
    # First transient failure → re-queued (deferred), not terminal.
    assert r.action == "deferred"
    assert ctx.state.get_episode("gx")["status"] == "pending"
    assert ctx.state.get_episode("gx")["error_category"] == "network"
