"""Wiring smoke for the watchlist-reload checkpoint.

Drives the *real* ``ParagraphosApp._maybe_reload_watchlist`` against a minimal
stand-in ``self`` (mirror of ``test_app_activation_catchup``'s ``_FakeApp``
pattern: bind the unbound method to a SimpleNamespace carrying just ``ctx``).
No Qt event loop, no window/tray — only the reload + stamp behavior is checked.

When watchlist.yaml is edited externally (a show appended) between baseline and
checkpoint, the running app must adopt the new show *without* clobbering it and
stamp its first-seen time so the 24h backlog auto-accept timer starts — while
leaving the show undecided (the banner/sweep are later tasks).
"""

from __future__ import annotations

import types

import app as app_module
from core.models import Show, Watchlist
from core.state import StateStore
from core.watchlist_guard import DETECTED_AT, is_decided
from core.watchlist_io import file_digest


def test_maybe_reload_adopts_and_stamps_external_addition(tmp_path):
    # App loaded a 1-show watchlist; baseline recorded.
    wl = Watchlist(shows=[Show(slug="a", title="a", rss="http://h/a")])
    path = tmp_path / "watchlist.yaml"
    wl.save(path)
    state = StateStore(tmp_path / "state.sqlite")
    state.init_schema()
    ctx = types.SimpleNamespace(
        data_dir=tmp_path,
        watchlist=wl,
        state=state,
        _watchlist_hash=file_digest(path),
    )
    self = types.SimpleNamespace(ctx=ctx)

    # Externally append a new show directly to the file.
    ext = Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in ["a", "new"]])
    ext.save(path)

    # Call the REAL bound method against the stand-in self.
    app_module.ParagraphosApp._maybe_reload_watchlist(self)

    slugs = {s.slug for s in ctx.watchlist.shows}
    assert "new" in slugs  # adopted (no clobber)
    assert is_decided(ctx.state, "new") is False  # still undecided
    assert ctx.state.get_meta(DETECTED_AT("new")) is not None  # first-seen stamped


def test_auto_accept_overdue_method_decides_overdue_show(tmp_path):
    """The REAL ParagraphosApp._auto_accept_overdue, driven against a stand-in
    self with a real ctx: an undecided show first-seen >24h ago becomes decided
    after the sweep (no Qt loop)."""
    from datetime import datetime, timedelta, timezone

    from core.watchlist_guard import mark_detected_now

    wl = Watchlist(shows=[Show(slug="ext", title="ext", rss="http://h/ext")])
    state = StateStore(tmp_path / "state.sqlite")
    state.init_schema()
    # Stamp first-seen well over 24h ago so the sweep (which uses now=utcnow)
    # finds it overdue.
    mark_detected_now(state, "ext", now=datetime.now(timezone.utc) - timedelta(hours=25))
    assert is_decided(state, "ext") is False

    ctx = types.SimpleNamespace(watchlist=wl, state=state)
    self = types.SimpleNamespace(ctx=ctx)

    app_module.ParagraphosApp._auto_accept_overdue(self)

    assert is_decided(state, "ext") is True
