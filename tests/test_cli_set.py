"""``cli.py set <slug> youtube_transcript_pref=…`` value validation.

auto-captions is no longer a user-settable value: the dead option was
removed from every selectable surface. cmd_set must reject it (and any
other garbage) while still accepting the two live values plus empty
(inherit-the-Settings-default).
"""

from __future__ import annotations

import argparse

import cli
from core.models import Show, Watchlist


def _wire(tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    wl = Watchlist(
        shows=[
            Show(
                slug="ch",
                title="Channel",
                rss="https://www.youtube.com/feeds/videos.xml?channel_id=UCabc",
                source="youtube",
            )
        ]
    )
    wl.save(tmp_path / "watchlist.yaml")


def _set(slug, assignment):
    return cli.cmd_set(argparse.Namespace(slug=slug, assignment=assignment))


def _pref(tmp_path):
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    return next(s for s in wl.shows if s.slug == "ch").youtube_transcript_pref


def test_set_transcript_pref_auto_captions_rejected(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    assert _set("ch", "youtube_transcript_pref=auto-captions") == 2
    # Rejection must not have mutated the stored show.
    assert _pref(tmp_path) == ""


def test_set_transcript_pref_garbage_rejected(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    assert _set("ch", "youtube_transcript_pref=garbage") == 2
    assert _pref(tmp_path) == ""


def test_set_transcript_pref_captions_accepted(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    assert _set("ch", "youtube_transcript_pref=captions") == 0
    assert _pref(tmp_path) == "captions"


def test_set_transcript_pref_whisper_accepted(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    assert _set("ch", "youtube_transcript_pref=whisper") == 0
    assert _pref(tmp_path) == "whisper"


def test_set_transcript_pref_empty_accepted(tmp_path, monkeypatch):
    # Empty string means "inherit the Settings default" — must stay legal.
    _wire(tmp_path, monkeypatch)
    assert _set("ch", "youtube_transcript_pref=captions") == 0
    assert _set("ch", "youtube_transcript_pref=") == 0
    assert _pref(tmp_path) == ""
