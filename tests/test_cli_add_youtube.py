"""CLI `add` must treat a YouTube channel/@handle URL like the GUI's
dedicated flow: resolve to the channel feed and tag source=youtube."""

import argparse

import cli
import core.paths
from core.models import Watchlist

_CID = "UCabc1234567890123456789"


def _yt_manifest(n):
    return [
        {
            "guid": f"v{i:02d}",
            "title": f"Ep {i}",
            "pubDate": f"2026-06-{i + 1:02d}T00:00:00",
            "mp3_url": f"https://www.youtube.com/watch?v=v{i:02d}",
            "description": "",
        }
        for i in range(n)
    ]


def _wire(tmp_path, monkeypatch, manifest):
    monkeypatch.setattr(core.paths, "user_data_dir", lambda: tmp_path)
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    monkeypatch.setattr(cli, "feed_metadata", lambda rss: {"title": "Sample Channel", "author": ""})
    monkeypatch.setattr(cli, "build_manifest", lambda rss: manifest)


def _pending(tmp_path, slug):
    from core.state import StateStore

    st = StateStore(tmp_path / "state.sqlite")
    with st._conn() as c:
        return c.execute(
            "SELECT COUNT(*) n FROM episodes WHERE show_slug=? AND status='pending'",
            (slug,),
        ).fetchone()["n"]


def test_channel_url_sets_source_youtube_and_feed(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, _yt_manifest(5))
    ns = argparse.Namespace(
        name_or_url=f"https://www.youtube.com/channel/{_CID}",
        backlog="all",
        slug=None,
        lang="en",
        yes=True,
    )
    assert cli.cmd_add(ns) == 0

    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "sample-channel")
    assert show.source == "youtube"
    assert show.rss == f"https://www.youtube.com/feeds/videos.xml?channel_id={_CID}"
    assert show.language == "en"
    # YouTube shows carry no whisper prompt.
    assert show.whisper_prompt == ""
    assert _pending(tmp_path, "sample-channel") == 5


def test_channel_backlog_last_limits_pending(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, _yt_manifest(5))
    ns = argparse.Namespace(
        name_or_url=f"https://www.youtube.com/channel/{_CID}",
        backlog="last:2",
        slug="yt",
        lang="de",
        yes=True,
    )
    assert cli.cmd_add(ns) == 0
    assert _pending(tmp_path, "yt") == 2


def test_handle_url_resolves_then_adds(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, _yt_manifest(3))
    import core.youtube_meta as ym

    monkeypatch.setattr(ym, "resolve_handle_to_channel_id", lambda h: _CID)
    ns = argparse.Namespace(
        name_or_url="https://www.youtube.com/@somehandle",
        backlog="all",
        slug="handle-show",
        lang="de",
        yes=True,
    )
    assert cli.cmd_add(ns) == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "handle-show")
    assert show.source == "youtube"
    assert show.rss == f"https://www.youtube.com/feeds/videos.xml?channel_id={_CID}"


def test_single_video_url_is_rejected(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, _yt_manifest(1))
    ns = argparse.Namespace(
        name_or_url="https://www.youtube.com/watch?v=VID11111111",
        backlog="all",
        slug=None,
        lang="de",
        yes=True,
    )
    # Channel/handle only — a bare video URL exits 2.
    assert cli.cmd_add(ns) == 2
