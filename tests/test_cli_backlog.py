"""CLI ``backlog <slug> --backlog …`` deepens an EXISTING YouTube show's
back-catalogue: it re-enumerates the channel's uploads (depth controlled by
the reused --backlog grammar) and SEEDs + QUEUEs the new ones (pending),
while leaving any pre-existing episode's status untouched (upsert preserves
it). Unlike ``add`` it never calls ``apply_backlog`` — everything fetched is
queued."""

import argparse

import cli
import core.paths
import core.youtube_meta as ym
from core.models import Show, Watchlist
from core.state import EpisodeStatus, StateStore

_CID = "UCabc1234567890123456789"
_FEED = f"https://www.youtube.com/feeds/videos.xml?channel_id={_CID}"


def _videos(n):
    # yt-dlp --flat-playlist shape (id + title + unix timestamp).
    return [
        {"id": f"v{i:02d}", "title": f"Ep {i}", "timestamp": 1_700_000_000 + i} for i in range(n)
    ]


def _wire(tmp_path, monkeypatch, *, n_videos=5, source="youtube", skip_shorts=True, rss=_FEED):
    """Point cli at tmp data dirs, write a watchlist with one show (slug
    ``ch``), and stub the channel enumerator with a recorder.

    Returns the ``calls`` list capturing each enumerate_channel_videos
    invocation's kwargs so tests can assert the depth → enumerator mapping.
    """
    monkeypatch.setattr(core.paths, "user_data_dir", lambda: tmp_path)
    monkeypatch.setattr(cli, "DATA", tmp_path, raising=False)

    wl = Watchlist(
        shows=[
            Show(
                slug="ch",
                title="Sample Channel",
                rss=rss,
                source=source,
                skip_shorts=skip_shorts,
            )
        ]
    )
    wl.save_atomic(tmp_path / "watchlist.yaml")

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
    base = dict(slug="ch", backlog="all")
    base.update(kw)
    return argparse.Namespace(**base)


def _state(tmp_path):
    st = StateStore(tmp_path / "state.sqlite")
    st.init_schema()
    return st


def _pending(tmp_path, slug="ch"):
    st = StateStore(tmp_path / "state.sqlite")
    with st._conn() as c:
        return c.execute(
            "SELECT COUNT(*) n FROM episodes WHERE show_slug=? AND status='pending'",
            (slug,),
        ).fetchone()["n"]


def test_backlog_seeds_new_episodes_pending(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=5)
    assert cli.cmd_backlog(_ns()) == 0
    assert _pending(tmp_path) == 5


def test_backlog_preserves_existing_status(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, n_videos=5)
    # Pre-seed v00 and mark it done; backlog must NOT re-queue it.
    st = _state(tmp_path)
    st.upsert_episode(
        show_slug="ch",
        guid="v00",
        title="Ep 0",
        pub_date="2023-11-14",
        mp3_url="https://www.youtube.com/watch?v=v00",
    )
    st.set_status("v00", EpisodeStatus.DONE)

    assert cli.cmd_backlog(_ns()) == 0
    # v00 stays done; only the genuinely new v01..v04 (4) are pending.
    assert st.get_episode("v00")["status"] == "done"
    assert _pending(tmp_path) == 4


def test_backlog_unknown_slug_exits_2(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    assert cli.cmd_backlog(_ns(slug="nope")) == 2


def test_backlog_non_youtube_show_exits_2(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch, source="podcast")
    assert cli.cmd_backlog(_ns()) == 2


def test_backlog_last_passes_limit(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=10)
    assert cli.cmd_backlog(_ns(backlog="last:3")) == 0
    assert calls and calls[0]["limit"] == 3
    assert _pending(tmp_path) == 3


def test_backlog_since_passes_date_after(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=3)
    assert cli.cmd_backlog(_ns(backlog="since:2021-01-01")) == 0
    # since: must not also smuggle a stray limit.
    assert calls and calls[0]["date_after"] == "2021-01-01" and calls[0]["limit"] is None


def test_backlog_recent_passes_limit_15(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=20)
    assert cli.cmd_backlog(_ns(backlog="recent")) == 0
    assert calls and calls[0]["limit"] == 15


def test_backlog_include_shorts_follows_show_flag(tmp_path, monkeypatch):
    # A show that opts into Shorts must enumerate the channel root, not /videos.
    calls = _wire(tmp_path, monkeypatch, n_videos=3, skip_shorts=False)
    assert cli.cmd_backlog(_ns()) == 0
    assert calls and calls[0]["include_shorts"] is True


def test_backlog_skip_shorts_excludes_shorts(tmp_path, monkeypatch):
    calls = _wire(tmp_path, monkeypatch, n_videos=3, skip_shorts=True)
    assert cli.cmd_backlog(_ns()) == 0
    assert calls and calls[0]["include_shorts"] is False


def test_backlog_underivable_channel_id_exits_2(tmp_path, monkeypatch):
    # A youtube show whose RSS carries no channel_id can't be enumerated.
    _wire(tmp_path, monkeypatch, rss="https://www.youtube.com/feeds/videos.xml")
    assert cli.cmd_backlog(_ns()) == 2


def test_backlog_bad_backlog_value_exits_2(tmp_path, monkeypatch):
    _wire(tmp_path, monkeypatch)
    assert cli.cmd_backlog(_ns(backlog="garbage")) == 2
