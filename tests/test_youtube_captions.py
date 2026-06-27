from pathlib import Path
from unittest.mock import MagicMock, patch

from core.youtube_captions import (
    NoCaptionsAvailable,
    fetch_manual_captions,
    vtt_to_srt,
)

FIXTURE = Path(__file__).parent / "fixtures" / "youtube" / "sample.en.vtt"


def _setup_fake_ytdlp(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.APP_SUPPORT", tmp_path)
    (tmp_path / "bin").mkdir(parents=True)
    (tmp_path / "bin" / "yt-dlp").write_text("#!/bin/sh\n")
    (tmp_path / "bin" / "yt-dlp").chmod(0o755)


def test_vtt_to_srt_converts_basic_cue():
    vtt = FIXTURE.read_text()
    srt = vtt_to_srt(vtt)
    assert "1\n" in srt
    assert " --> " in srt
    assert ",000" in srt or "," in srt  # SRT uses commas in timestamps


def test_fetch_manual_returns_path(tmp_path, monkeypatch):
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    written_vtt = out_dir / "video.en.vtt"
    written_vtt.write_text(FIXTURE.read_text())

    fake_proc = MagicMock(returncode=0, stdout="", stderr="")
    with patch("subprocess.run", return_value=fake_proc):
        srt_path = fetch_manual_captions("dQw4w9WgXcQ", out_dir / "video", lang="en")
        assert srt_path.exists()
        assert srt_path.suffix == ".srt"


def test_fetch_manual_raises_when_no_captions(tmp_path, monkeypatch):
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    fake_proc = MagicMock(returncode=0, stdout="", stderr="")
    with patch("subprocess.run", return_value=fake_proc):
        try:
            fetch_manual_captions("vid", tmp_path / "video", lang="en")
        except NoCaptionsAvailable:
            return
        raise AssertionError("expected NoCaptionsAvailable")


def _sub_langs_seen(calls) -> list[str]:
    """Extract the --sub-langs argument from each captured yt-dlp argv."""
    seen: list[str] = []
    for cmd in calls:
        if "--sub-langs" in cmd:
            seen.append(cmd[cmd.index("--sub-langs") + 1])
    return seen


def test_specific_language_is_strict(tmp_path, monkeypatch):
    """A specific language is STRICT: only that language is ever requested.

    Even though the video *has* English captions, asking for German must
    raise NoCaptionsAvailable (→ caller whispers) and must never silently
    grab the English track or even probe for it.
    """
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    # English captions DO exist on the video; German does not.
    (out_dir / "video.en.vtt").write_text(FIXTURE.read_text())

    # If the strict rule ever consulted the available-langs probe we'd see it.
    monkeypatch.setattr(
        "core.youtube_captions._list_available_sub_langs",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("probe must not run")),
    )

    calls: list[list[str]] = []

    def fake_run(cmd, *a, **k):
        calls.append(cmd)
        # yt-dlp "succeeds" but writes nothing for the requested (de) track.
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        try:
            fetch_manual_captions("vid", out_dir / "video", lang="de")
        except NoCaptionsAvailable:
            pass
        else:
            raise AssertionError("expected NoCaptionsAvailable (strict, no en fallback)")

    # The only --sub-langs ever requested was "de" — never "en".
    assert _sub_langs_seen(calls) == ["de"]


def test_auto_accepts_channel_default_track(tmp_path, monkeypatch):
    """lang="auto" accepts the channel's default manual track.

    The probe lists ["fr", "en"] (YouTube order = channel default first), so
    "auto" must try "fr" first and return its srt — not a hard-coded "en".
    """
    _setup_fake_ytdlp(tmp_path, monkeypatch)
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    monkeypatch.setattr(
        "core.youtube_captions._list_available_sub_langs",
        lambda *a, **k: ["fr", "en"],
    )

    calls: list[list[str]] = []

    def fake_run(cmd, *a, **k):
        calls.append(cmd)
        # The download for the channel-default (fr) track produces its vtt.
        if "--sub-langs" in cmd and cmd[cmd.index("--sub-langs") + 1] == "fr":
            (out_dir / "video.fr.vtt").write_text(FIXTURE.read_text())
        return MagicMock(returncode=0, stdout="", stderr="")

    with patch("subprocess.run", side_effect=fake_run):
        srt_path = fetch_manual_captions("vid", out_dir / "video", lang="auto")

    assert srt_path.exists()
    assert srt_path.suffix == ".srt"
    # It tried the channel-default track first (fr), driven by the probe.
    assert _sub_langs_seen(calls)[0] == "fr"
