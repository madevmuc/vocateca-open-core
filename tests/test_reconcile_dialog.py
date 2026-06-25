"""apply_reconcile_choice: seed + apply backlog + mark decided for an
externally-added show. Drives the real helper with the feed stubbed."""
from types import SimpleNamespace

import ui.reconcile_dialog as rd
from core.models import Show, Watchlist
from core.state import StateStore
from core.watchlist_guard import is_decided


def _ctx(tmp_path):
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    wl = Watchlist(shows=[Show(slug="x", title="X", rss="http://h/x")])
    return SimpleNamespace(watchlist=wl, state=st)


def _manifest(n=10):
    return [
        {
            "guid": f"g{i}",
            "title": f"t{i}",
            "pubDate": f"2026-01-{i + 1:02d}T00:00:00",
            "mp3_url": f"http://h/{i}.mp3",
        }
        for i in range(n)
    ]


def _pending(st):
    with st._conn() as c:
        return c.execute(
            "SELECT COUNT(*) n FROM episodes WHERE show_slug='x' AND status='pending'"
        ).fetchone()["n"]


def test_apply_reconcile_last5_seeds_and_decides(tmp_path, monkeypatch):
    ctx = _ctx(tmp_path)
    monkeypatch.setattr(rd, "build_manifest", lambda rss: _manifest(10))
    n = rd.apply_reconcile_choice(ctx, "x", "last:5")
    assert n == 10
    assert _pending(ctx.state) == 5          # back-catalog marked done
    assert is_decided(ctx.state, "x")         # un-gated now


def test_apply_reconcile_all_keeps_everything(tmp_path, monkeypatch):
    ctx = _ctx(tmp_path)
    monkeypatch.setattr(rd, "build_manifest", lambda rss: _manifest(10))
    rd.apply_reconcile_choice(ctx, "x", "all")
    assert _pending(ctx.state) == 10
    assert is_decided(ctx.state, "x")


def test_apply_reconcile_unknown_slug_is_noop(tmp_path, monkeypatch):
    ctx = _ctx(tmp_path)
    monkeypatch.setattr(rd, "build_manifest", lambda rss: _manifest(10))
    assert rd.apply_reconcile_choice(ctx, "nope", "all") == 0
    assert not is_decided(ctx.state, "nope")
