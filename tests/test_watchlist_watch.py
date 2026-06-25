# tests/test_watchlist_watch.py
from types import SimpleNamespace

from core.watchlist_watch import WatchlistEventHandler, _affects_watchlist


def _evt(path, dest=None):
    e = SimpleNamespace(src_path=str(path))
    if dest is not None:
        e.dest_path = str(dest)
    return e


def test_fires_only_for_watchlist(tmp_path):
    calls = []
    h = WatchlistEventHandler(lambda: calls.append(1))
    h.dispatch(_evt(tmp_path / "watchlist.yaml"))
    assert calls == [1]
    h.dispatch(_evt(tmp_path / "settings.yaml"))
    assert calls == [1]  # unchanged — non-watchlist ignored


def test_affects_watchlist_on_move(tmp_path):
    # an atomic save (tmp → watchlist.yaml) shows up as a move to dest
    assert _affects_watchlist(_evt(tmp_path / "x.tmp", tmp_path / "watchlist.yaml")) is True
    assert _affects_watchlist(_evt(tmp_path / "x.tmp", tmp_path / "y.tmp")) is False
