"""Pipeline integration for YouTube-source shows.

A YouTube episode dispatches to a captions-first / whisper-fallback path
inside core.pipeline. The episode dict's `mp3_url` carries the YouTube
watch URL (set by the YouTube discovery layer); the `PipelineContext`
gains optional source/preference/channel-id fields populated by the
worker_thread per-show.
"""

from pathlib import Path
from unittest.mock import patch

from core.library import LibraryIndex
from core.pipeline import PipelineContext, process_episode
from core.state import StateStore


def _yt_ctx(tmp_path: Path, *, pref: str = "captions", skip_shorts: bool = True) -> PipelineContext:
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
        source="youtube",
        youtube_transcript_pref=pref,
        youtube_channel_id="UCabcdefghijklmnopqrstuv",
        skip_shorts=skip_shorts,
    )


# An "ok"-classifying probe result: long enough not to be a Short, not live,
# no availability/age gates. Patched into the happy-path tests so the
# proactive Shorts probe (enabled by skip_shorts default True) is a no-op.
_OK_META = {
    "duration": 600,
    "webpage_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "live_status": "not_live",
    "availability": "public",
    "age_limit": 0,
}


def _seed_yt_episode(ctx: PipelineContext, *, guid: str = "yt1") -> None:
    ctx.state.upsert_episode(
        show_slug="ch",
        guid=guid,
        title="My Video",
        pub_date="2026-04-15",
        mp3_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    )


_FAKE_SRT = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"


def test_youtube_episode_uses_captions_when_available(tmp_path: Path):
    ctx = _yt_ctx(tmp_path, pref="captions")
    _seed_yt_episode(ctx)

    called = {"captions": False, "audio": False, "whisper": False}

    def fake_captions(video_id, basename, *, lang="en", auto_ok=False):
        called["captions"] = True
        srt = basename.with_suffix(".srt")
        srt.parent.mkdir(parents=True, exist_ok=True)
        srt.write_text(_FAKE_SRT, encoding="utf-8")
        return srt

    def fake_audio(*a, **kw):
        called["audio"] = True

    def fake_whisper(*a, **kw):
        called["whisper"] = True

    with (
        patch("core.youtube_audio.probe_video_meta", return_value=_OK_META),
        patch("core.youtube_captions.fetch_manual_captions", side_effect=fake_captions),
        patch("core.youtube_audio.download_audio", side_effect=fake_audio),
        patch("core.pipeline.transcribe_episode", side_effect=fake_whisper),
    ):
        r = process_episode("yt1", ctx)

    assert called["captions"] is True
    assert called["whisper"] is False
    assert called["audio"] is False
    assert r.action == "transcribed"
    assert ctx.state.get_episode("yt1")["status"] == "done"

    show_dir = ctx.output_root / "ch"
    mds = list(show_dir.glob("*.md"))
    srts = list(show_dir.glob("*.srt"))
    assert len(mds) == 1
    assert len(srts) == 1
    body = mds[0].read_text(encoding="utf-8")
    assert "source: youtube" in body
    assert "youtube_id: dQw4w9WgXcQ" in body
    assert "channel_id: UCabcdefghijklmnopqrstuv" in body
    assert "transcript_source: captions" in body


def test_youtube_episode_falls_back_to_whisper_when_no_captions(tmp_path: Path):
    from core.youtube_captions import NoCaptionsAvailable

    ctx = _yt_ctx(tmp_path, pref="captions")
    _seed_yt_episode(ctx, guid="yt2")

    called = {"captions": False, "audio": False, "whisper": False}

    def fake_captions(*a, **kw):
        called["captions"] = True
        raise NoCaptionsAvailable("none")

    def fake_audio(video_id, target_mp3, **kw):
        called["audio"] = True
        target_mp3.parent.mkdir(parents=True, exist_ok=True)
        target_mp3.write_bytes(b"ID3" + b"\x00" * 1024)
        return target_mp3

    class _R:
        md_path: Path
        srt_path: Path
        word_count: int = 5

        def __init__(self, md, srt):
            self.md_path = md
            self.srt_path = srt

    def fake_whisper(*, mp3_path, output_dir, slug, **kw):
        called["whisper"] = True
        output_dir.mkdir(parents=True, exist_ok=True)
        srt = output_dir / f"{slug}.srt"
        srt.write_text(_FAKE_SRT, encoding="utf-8")
        md = output_dir / f"{slug}.md"
        md.write_text('---\nguid: "yt2"\n---\n', encoding="utf-8")
        return _R(md, srt)

    with (
        patch("core.youtube_audio.probe_video_meta", return_value=_OK_META),
        patch("core.youtube_captions.fetch_manual_captions", side_effect=fake_captions),
        patch("core.youtube_audio.download_audio", side_effect=fake_audio),
        patch("core.pipeline.transcribe_episode", side_effect=fake_whisper),
    ):
        r = process_episode("yt2", ctx)

    assert called["captions"] is True
    assert called["audio"] is True
    assert called["whisper"] is True
    assert r.action == "transcribed"
    assert ctx.state.get_episode("yt2")["status"] == "done"


def test_youtube_episode_whisper_pref_skips_captions(tmp_path: Path):
    ctx = _yt_ctx(tmp_path, pref="whisper")
    _seed_yt_episode(ctx, guid="yt3")

    called = {"captions": False, "audio": False, "whisper": False}

    def fake_captions(*a, **kw):
        called["captions"] = True

    def fake_audio(video_id, target_mp3, **kw):
        called["audio"] = True
        target_mp3.parent.mkdir(parents=True, exist_ok=True)
        target_mp3.write_bytes(b"ID3" + b"\x00" * 1024)
        return target_mp3

    class _R:
        word_count = 5

        def __init__(self, md, srt):
            self.md_path = md
            self.srt_path = srt

    def fake_whisper(*, mp3_path, output_dir, slug, **kw):
        called["whisper"] = True
        output_dir.mkdir(parents=True, exist_ok=True)
        srt = output_dir / f"{slug}.srt"
        srt.write_text(_FAKE_SRT, encoding="utf-8")
        md = output_dir / f"{slug}.md"
        md.write_text('---\nguid: "yt3"\n---\n', encoding="utf-8")
        return _R(md, srt)

    with (
        patch("core.youtube_audio.probe_video_meta", return_value=_OK_META),
        patch("core.youtube_captions.fetch_manual_captions", side_effect=fake_captions),
        patch("core.youtube_audio.download_audio", side_effect=fake_audio),
        patch("core.pipeline.transcribe_episode", side_effect=fake_whisper),
    ):
        r = process_episode("yt3", ctx)

    assert called["captions"] is False
    assert called["audio"] is True
    assert called["whisper"] is True
    assert r.action == "transcribed"


def test_youtube_whisper_writes_progress_and_persists_duration(tmp_path: Path):
    """Bug 3: the YouTube whisper path must feed the Queue — persist the audio
    duration (Audio / Whisper / Finish columns) and write the live transcribe %
    (Status column) via progress_cb, like the podcast path."""
    ctx = _yt_ctx(tmp_path, pref="whisper")
    _seed_yt_episode(ctx, guid="ytp")
    captured: dict = {}

    def fake_audio(video_id, target_mp3, **kw):
        target_mp3.parent.mkdir(parents=True, exist_ok=True)
        target_mp3.write_bytes(b"ID3" + b"\x00" * 1024)
        return target_mp3

    class _R:
        word_count = 5

        def __init__(self, md, srt):
            self.md_path = md
            self.srt_path = srt

    def fake_whisper(*, mp3_path, output_dir, slug, progress_cb=None, **kw):
        # Capture the live state DURING transcription (record_completion later
        # overwrites duration_sec with the SRT's real length, as it should).
        captured["dur_during"] = ctx.state.get_episode("ytp")["duration_sec"]
        # Simulate whisper reporting it has processed 300s of the 600s audio.
        if progress_cb is not None:
            progress_cb(300)
            captured["pct"] = ctx.state.get_meta("transcribe_pct:ytp")
        output_dir.mkdir(parents=True, exist_ok=True)
        srt = output_dir / f"{slug}.srt"
        srt.write_text(_FAKE_SRT, encoding="utf-8")
        md = output_dir / f"{slug}.md"
        md.write_text('---\nguid: "ytp"\n---\n', encoding="utf-8")
        return _R(md, srt)

    with (
        patch("core.youtube_audio.probe_video_meta", return_value=_OK_META),
        patch("core.youtube_audio.download_audio", side_effect=fake_audio),
        patch("core.pipeline.transcribe_episode", side_effect=fake_whisper),
    ):
        r = process_episode("ytp", ctx)

    assert r.action == "transcribed"
    # Duration persisted from the probe BEFORE transcription → the Queue
    # Audio/Whisper/Finish columns have a real length while it runs.
    assert captured.get("dur_during") == 600
    # progress_cb wired → live % written mid-transcription (300/600 = 50%).
    assert captured.get("pct") == "50"


# ── Task 2.4: routing Shorts / live / restricted videos ───────────────


def test_short_skipped_when_show_skips_shorts(tmp_path: Path):
    """A show that skips Shorts proactively probes and marks the episode
    SKIPPED (terminal, not a failure) without downloading anything."""
    ctx = _yt_ctx(tmp_path, pref="whisper", skip_shorts=True)
    _seed_yt_episode(ctx, guid="ytshort")

    short_meta = {
        "webpage_url": "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "duration": 30,
    }

    def fake_audio(*a, **kw):  # pragma: no cover - must NOT be called
        raise AssertionError("download_audio must not run for a skipped Short")

    with (
        patch("core.youtube_audio.probe_video_meta", return_value=short_meta),
        patch("core.youtube_audio.download_audio", side_effect=fake_audio),
    ):
        r = process_episode("ytshort", ctx)

    assert r.action == "skipped"
    assert ctx.state.get_episode("ytshort")["status"] == "skipped"


def test_short_not_skipped_when_include_shorts(tmp_path: Path):
    """With skip_shorts False the proactive probe is never run, so a short
    video still transcribes normally."""
    ctx = _yt_ctx(tmp_path, pref="whisper", skip_shorts=False)
    _seed_yt_episode(ctx, guid="ytinc")

    def boom_probe(*a, **kw):  # pragma: no cover - must NOT be called
        raise AssertionError("probe_video_meta must not run when including Shorts")

    def fake_audio(video_id, target_mp3, **kw):
        target_mp3.parent.mkdir(parents=True, exist_ok=True)
        target_mp3.write_bytes(b"ID3" + b"\x00" * 1024)
        return target_mp3

    class _R:
        word_count = 5

        def __init__(self, md, srt):
            self.md_path = md
            self.srt_path = srt

    def fake_whisper(*, mp3_path, output_dir, slug, **kw):
        output_dir.mkdir(parents=True, exist_ok=True)
        srt = output_dir / f"{slug}.srt"
        srt.write_text(_FAKE_SRT, encoding="utf-8")
        md = output_dir / f"{slug}.md"
        md.write_text('---\nguid: "ytinc"\n---\n', encoding="utf-8")
        return _R(md, srt)

    with (
        patch("core.youtube_audio.probe_video_meta", side_effect=boom_probe),
        patch("core.youtube_audio.download_audio", side_effect=fake_audio),
        patch("core.pipeline.transcribe_episode", side_effect=fake_whisper),
    ):
        r = process_episode("ytinc", ctx)

    assert r.action == "transcribed"
    assert ctx.state.get_episode("ytinc")["status"] != "skipped"


def test_live_video_deferred(tmp_path: Path):
    """A live/premiere video surfaces reactively from the download error and
    is DEFERRED (re-probed later), not failed."""
    ctx = _yt_ctx(tmp_path, pref="whisper", skip_shorts=False)
    _seed_yt_episode(ctx, guid="ytlive")

    def fake_audio(*a, **kw):
        raise RuntimeError("ERROR: [youtube] x: This live event will begin in 3 hours.")

    with patch("core.youtube_audio.download_audio", side_effect=fake_audio):
        r = process_episode("ytlive", ctx)

    assert r.action == "deferred"
    assert ctx.state.get_episode("ytlive")["status"] == "deferred"


def test_members_only_failed_with_message(tmp_path: Path):
    """A members-only video fails with the friendly classification message,
    not the raw yt-dlp exception text."""
    ctx = _yt_ctx(tmp_path, pref="whisper", skip_shorts=False)
    _seed_yt_episode(ctx, guid="ytmem")

    def fake_audio(*a, **kw):
        raise RuntimeError(
            "ERROR: [youtube] x: Join this channel to get access to "
            "members-only content like this video."
        )

    with patch("core.youtube_audio.download_audio", side_effect=fake_audio):
        r = process_episode("ytmem", ctx)

    assert r.action == "failed"
    row = ctx.state.get_episode("ytmem")
    assert row["status"] == "failed"
    err = row["error_text"]
    assert err
    assert "Join this channel" not in err  # friendly, not the raw exception
    assert "member" in err.lower()


def test_unrecognised_download_error_stays_failed_not_deferred(tmp_path: Path):
    """An unrecognised download error stays a generic FAILED — never
    deferred — so a persistent error (e.g. bot-gate) can't livelock."""
    ctx = _yt_ctx(tmp_path, pref="whisper", skip_shorts=False)
    _seed_yt_episode(ctx, guid="ytbot")

    def fake_audio(*a, **kw):
        raise RuntimeError("ERROR: Sign in to confirm you're not a bot")

    with patch("core.youtube_audio.download_audio", side_effect=fake_audio):
        r = process_episode("ytbot", ctx)

    assert r.action == "failed"
    assert ctx.state.get_episode("ytbot")["status"] == "failed"
