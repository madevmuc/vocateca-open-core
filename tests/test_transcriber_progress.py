"""Streaming-progress path in core.transcriber.transcribe_episode.

Mocks subprocess.run so it writes whisper-style timestamp lines into
the `stdout=` file handle the caller passed in. Asserts progress_cb
is invoked with the parsed segment end-seconds.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch


def test_progress_cb_fires_from_stdout_log(tmp_path: Path):
    from core.transcriber import transcribe_episode

    (tmp_path / "fake.mp3").write_bytes(b"\x00" * 1024)
    calls: list[int] = []

    def cb(sec: int) -> None:
        calls.append(sec)

    def fake_run(cmd, *a, **kw):
        # Simulate whisper writing two segments to its stdout (which the
        # transcriber redirected to an open file handle for us to tail).
        stdout_f = kw.get("stdout")
        if stdout_f is not None and hasattr(stdout_f, "write"):
            stdout_f.write("[00:00:05.000 --> 00:00:10.000]  hello\n")
            stdout_f.write("[00:00:10.000 --> 00:00:20.000]  world\n")
            stdout_f.flush()
        # Materialise the .txt/.srt whisper would have written via -of.
        stem = None
        for i, arg in enumerate(cmd):
            if arg == "-of":
                stem = Path(cmd[i + 1])
                break
        assert stem is not None
        (stem.parent / (stem.name + ".txt")).write_text("word " * 500, encoding="utf-8")
        (stem.parent / (stem.name + ".srt")).write_text(
            "1\n00:00:00,000 --> 00:00:02,000\nx\n", encoding="utf-8"
        )

        class R:
            returncode = 0
            stdout = ""
            stderr = ""

        return R()

    with patch("core.transcriber.subprocess.run", side_effect=fake_run):
        transcribe_episode(
            mp3_path=tmp_path / "fake.mp3",
            output_dir=tmp_path / "out",
            slug="2026-04-15_0000_test",
            metadata={
                "guid": "g",
                "show_slug": "demo",
                "title": "T",
                "pub_date": "2026-04-15",
                "mp3_url": "http://x",
            },
            progress_cb=cb,
        )

    # Either or both timestamps surfaced — the final sync read after
    # subprocess.run returned guarantees at least one.
    assert calls, f"progress_cb never fired — calls={calls}"
    assert max(calls) in (10, 20)


def test_progress_cb_none_uses_classic_path(tmp_path: Path):
    """When progress_cb is None we stay on plain subprocess.run — existing
    tests rely on this (they only mock subprocess.run)."""
    from core.transcriber import transcribe_episode

    (tmp_path / "fake.mp3").write_bytes(b"\x00" * 1024)

    def fake_run(cmd, *a, **kw):
        stem = None
        for i, arg in enumerate(cmd):
            if arg == "-of":
                stem = Path(cmd[i + 1])
                break
        assert stem is not None
        # No stdout= in kwargs means we're on the capture_output=True path.
        assert kw.get("stdout") is None or hasattr(kw.get("stdout"), "write") is False
        (stem.parent / (stem.name + ".txt")).write_text("word " * 500, encoding="utf-8")
        (stem.parent / (stem.name + ".srt")).write_text(
            "1\n00:00:00,000 --> 00:00:02,000\nx\n", encoding="utf-8"
        )

        class R:
            returncode = 0
            stdout = ""
            stderr = ""

        return R()

    with patch("core.transcriber.subprocess.run", side_effect=fake_run):
        transcribe_episode(
            mp3_path=tmp_path / "fake.mp3",
            output_dir=tmp_path / "out",
            slug="2026-04-15_0001_classic",
            metadata={
                "guid": "g",
                "show_slug": "demo",
                "title": "T",
                "pub_date": "2026-04-15",
                "mp3_url": "http://x",
            },
        )
