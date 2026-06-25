# tests/test_watchlist_io.py
from types import SimpleNamespace

from core.models import Show, Watchlist
from core.state import StateStore
from core.watchlist_guard import file_digest
from core.watchlist_io import reload_watchlist, save_watchlist


def _ctx(tmp_path, slugs):
    wl = Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in slugs])
    path = tmp_path / "watchlist.yaml"
    wl.save(path)
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    return SimpleNamespace(
        data_dir=tmp_path,
        watchlist=wl,
        state=st,
        _watchlist_hash=file_digest(path),
    )


def test_save_does_not_clobber_external_additions(tmp_path):
    # App loaded 2 shows; baseline recorded.
    ctx = _ctx(tmp_path, ["a", "b"])
    # External edit adds "c" and "d" directly to the file.
    ext = Watchlist(
        shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in ["a", "b", "c", "d"]]
    )
    ext.save(tmp_path / "watchlist.yaml")
    # App mutates its stale in-memory copy (toggle b) and saves.
    ctx.watchlist.shows[1].enabled = False
    save_watchlist(ctx)
    on_disk = Watchlist.load(tmp_path / "watchlist.yaml")
    slugs = {s.slug for s in on_disk.shows}
    assert slugs == {"a", "b", "c", "d"}  # external shows survived
    assert next(s for s in on_disk.shows if s.slug == "b").enabled is False  # mutation kept


def test_reload_adopts_external_and_reports_added(tmp_path):
    ctx = _ctx(tmp_path, ["a"])
    ext = Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in ["a", "z"]])
    ext.save(tmp_path / "watchlist.yaml")
    added = reload_watchlist(ctx)
    assert added == ["z"]
    assert {s.slug for s in ctx.watchlist.shows} == {"a", "z"}
    assert ctx._watchlist_hash == file_digest(tmp_path / "watchlist.yaml")


def test_save_no_external_change_just_writes(tmp_path):
    ctx = _ctx(tmp_path, ["a", "b"])
    ctx.watchlist.shows.append(Show(slug="c", title="c", rss="http://h/c"))
    save_watchlist(ctx)
    on_disk = Watchlist.load(tmp_path / "watchlist.yaml")
    assert {s.slug for s in on_disk.shows} == {"a", "b", "c"}
    assert ctx._watchlist_hash == file_digest(tmp_path / "watchlist.yaml")  # baseline refreshed
