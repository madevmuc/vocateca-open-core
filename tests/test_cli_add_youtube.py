"""CLI `add` must treat a YouTube channel/@handle URL like the GUI's
dedicated flow: resolve to the channel feed, deep-enumerate the channel's
uploads (honouring --backlog), and tag source=youtube. It also maps the
--captions/--whisper and --skip-shorts/--include-shorts flags onto the
Show model."""

import argparse

import cli
import core.paths
import core.youtube_meta as ym
from core.models import Watchlist

_CID = "UCabc1234567890123456789"


def _yt_manifest(n):
    # build_manifest fallback for any non-youtube path; the youtube path
    # enumerates instead and never reaches this.
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


def _videos(n):
    # yt-dlp --flat-playlist shape (id + title + unix timestamp).
    return [
        {"id": f"v{i:02d}", "title": f"Ep {i}", "timestamp": 1_700_000_000 + i} for i in range(n)
    ]


def _wire(tmp_path, monkeypatch, *, n_videos=5):
    """Wire cmd_add against tmp data dirs and mock the network seams.

    Returns a ``calls`` list that records every enumerate_channel_videos
    invocation as a dict of keyword arguments, so tests can assert the
    backlog/shorts → enumerator mapping. The fake enumerator honours the
    ``limit`` kwarg (returns that many videos) so last:N composes with
    apply_backlog exactly like the real deep enumeration.
    """
    monkeypatch.setattr(core.paths, "user_data_dir", lambda: tmp_path)
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)
    monkeypatch.setattr(cli, "feed_metadata", lambda rss: {"title": "Sample Channel", "author": ""})
    monkeypatch.setattr(cli, "build_manifest", lambda rss: _yt_manifest(n_videos))

    calls = []

    def fake_enum(cid, *, limit=None, date_after=None, include_shorts=False):
        calls.append(
            {
                "cid": cid,
                "limit": limit,
                "date_after": date_after,
                "include_shorts": include_shorts,
            }
        )
        count = limit if limit is not None else n_videos
        return _videos(count)

    monkeypatch.setattr(ym, "enumerate_channel_videos", fake_enum)
    return calls


def _ns(**kw):
    base = dict(
        name_or_url=f"https://www.youtube.com/channel/{_CID}",
        backlog="all",
        slug=None,
        lang="en",
        yes=True,
    )
    base.update(kw)
    return argparse.Namespace(**base)


def _pending(tmp_path, slug):
    from core.state import StateStore

    st = StateStore(tmp_path / "state.sqlite")
    with st._conn() as c:
        return c.execute(
            "SELECT COUNT(*) n FROM episodes WHERE show_slug=? AND status='pending'",
            (slug,),
        ).fetchone()["n"]


def test_channel_url_sets_source_youtube_and_feed(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=5)
    ns = _ns(backlog="all", slug=None)
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
    _wire(tmp_path, monkeypatch, n_videos=5)
    ns = _ns(backlog="last:2", slug="yt", lang="de")
    assert cli.cmd_add(ns) == 0
    assert _pending(tmp_path, "yt") == 2


def test_handle_url_resolves_then_adds(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=3)
    monkeypatch.setattr(ym, "resolve_handle_to_channel_id", lambda h: _CID)
    ns = _ns(
        name_or_url="https://www.youtube.com/@somehandle",
        backlog="all",
        slug="handle-show",
        lang="de",
    )
    assert cli.cmd_add(ns) == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "handle-show")
    assert show.source == "youtube"
    assert show.rss == f"https://www.youtube.com/feeds/videos.xml?channel_id={_CID}"


def test_channel_url_resolves_then_adds(tmp_path, monkeypatch):
    """A /c/ (or /user/) custom URL parses to kind "channel_url" and must be
    resolved to a channel id, not treated as the id itself."""
    _wire(tmp_path, monkeypatch, n_videos=3)
    monkeypatch.setattr(ym, "resolve_channel_url_to_id", lambda u: _CID)
    ns = _ns(
        name_or_url="https://www.youtube.com/c/Veritasium",
        backlog="all",
        slug="c-show",
        lang="en",
    )
    assert cli.cmd_add(ns) == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "c-show")
    assert show.source == "youtube"
    assert show.rss == f"https://www.youtube.com/feeds/videos.xml?channel_id={_CID}"


def test_unresolvable_channel_url_exits_2(tmp_path, monkeypatch):
    """An unresolvable channel URL must fail cleanly (exit 2), not write a
    show with a garbage feed URL."""
    _wire(tmp_path, monkeypatch, n_videos=1)
    monkeypatch.setattr(ym, "resolve_channel_url_to_id", lambda u: "")
    ns = _ns(name_or_url="https://www.youtube.com/c/Nope", backlog="all", slug=None, lang="de")
    assert cli.cmd_add(ns) == 2


def test_duplicate_channel_id_rejected(tmp_path, monkeypatch):
    """Adding the same channel id under a different slug must be rejected
    (exit 3) and must not create a second show for that channel."""
    _wire(tmp_path, monkeypatch, n_videos=3)
    assert cli.cmd_add(_ns(backlog="all", slug="first")) == 0

    # Same channel id, different slug — should be caught by channel-id dedup.
    assert cli.cmd_add(_ns(backlog="all", slug="second")) == 3

    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    feed = f"https://www.youtube.com/feeds/videos.xml?channel_id={_CID}"
    yt_for_channel = [s for s in wl.shows if s.source == "youtube" and s.rss == feed]
    assert len(yt_for_channel) == 1


def test_single_video_url_is_rejected(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=1)
    ns = _ns(name_or_url="https://www.youtube.com/watch?v=VID11111111", backlog="all", slug=None)
    # Channel/handle only — a bare video URL exits 2.
    assert cli.cmd_add(ns) == 2


# ── flag → Show field mapping ───────────────────────────────────────────


def test_captions_flag_sets_transcript_pref(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=3)
    ns = _ns(slug="caps", youtube_transcript_pref="captions")
    assert cli.cmd_add(ns) == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "caps")
    assert show.youtube_transcript_pref == "captions"


def test_whisper_flag_sets_transcript_pref(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=3)
    ns = _ns(slug="whisp", youtube_transcript_pref="whisper")
    assert cli.cmd_add(ns) == 0
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "whisp")
    assert show.youtube_transcript_pref == "whisper"


def test_skip_shorts_default_enumerates_videos_tab(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=3)
    ns = _ns(slug="noshorts", skip_shorts=True)
    assert cli.cmd_add(ns) == 0
    # Default skip_shorts → enumerate the /videos tab (include_shorts False).
    assert calls and calls[0]["include_shorts"] is False
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "noshorts")
    assert show.skip_shorts is True


def test_include_shorts_enumerates_root(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=3)
    ns = _ns(slug="withshorts", skip_shorts=False)
    assert cli.cmd_add(ns) == 0
    # include-shorts → enumerate the channel root (include_shorts True).
    assert calls and calls[0]["include_shorts"] is True
    wl = Watchlist.load(tmp_path / "watchlist.yaml")
    show = next(s for s in wl.shows if s.slug == "withshorts")
    assert show.skip_shorts is False


def test_since_backlog_passes_date_after(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=3)
    ns = _ns(slug="since", backlog="since:2020-01-01")
    assert cli.cmd_add(ns) == 0
    assert calls and calls[0]["date_after"] == "2020-01-01"


def test_last_backlog_passes_limit(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=5)
    ns = _ns(slug="last2", backlog="last:2")
    assert cli.cmd_add(ns) == 0
    assert calls and calls[0]["limit"] == 2
    assert _pending(tmp_path, "last2") == 2
