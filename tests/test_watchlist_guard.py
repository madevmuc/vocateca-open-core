# tests/test_watchlist_guard.py
from datetime import datetime, timezone
from pathlib import Path

from core.models import Show, Watchlist
from core.state import StateStore
from core.watchlist_guard import (
    DECIDED,
    DETECTED_AT,
    GRANDFATHERED,
    auto_accept_due,
    file_digest,
    grandfather_existing,
    is_external_change,
    mark_decided,
    mark_detected_now,
    undecided_slugs,
)


def _wl(*slugs):
    return Watchlist(shows=[Show(slug=s, title=s, rss=f"http://h/{s}") for s in slugs])


def _state(tmp_path):
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    return st


def test_file_digest_stable_and_missing(tmp_path):
    p = tmp_path / "w.yaml"
    assert file_digest(p) == ""  # missing → ""
    p.write_text("a: 1")
    d1 = file_digest(p)
    assert d1 and file_digest(p) == d1  # stable
    p.write_text("a: 2")
    assert file_digest(p) != d1  # content-sensitive


def test_is_external_change(tmp_path):
    p = tmp_path / "w.yaml"
    p.write_text("x")
    base = file_digest(p)
    assert is_external_change(p, base) is False
    p.write_text("y")
    assert is_external_change(p, base) is True
    # empty baseline (startup, nothing recorded) is never "external"
    assert is_external_change(p, "") is False


def test_undecided_slugs(tmp_path):
    st = _state(tmp_path)
    wl = _wl("a", "b", "c")
    mark_decided(st, "a")
    assert undecided_slugs(wl, st) == ["b", "c"]


def test_grandfather_marks_all_once(tmp_path):
    st = _state(tmp_path)
    wl = _wl("a", "b")
    assert grandfather_existing(wl, st) is True  # ran
    assert undecided_slugs(wl, st) == []
    assert st.get_meta(GRANDFATHERED) == "1"
    # second call is a no-op (returns False), new shows NOT auto-decided
    wl2 = _wl("a", "b", "c")
    assert grandfather_existing(wl2, st) is False
    assert undecided_slugs(wl2, st) == ["c"]


def test_auto_accept_due(tmp_path):
    st = _state(tmp_path)
    now = datetime(2026, 6, 25, 12, 0, tzinfo=timezone.utc)
    mark_detected_now(st, "b", now=datetime(2026, 6, 24, 11, 0, tzinfo=timezone.utc))
    assert auto_accept_due(st, "b", now=now) is True  # >24h
    mark_detected_now(st, "c", now=datetime(2026, 6, 25, 11, 0, tzinfo=timezone.utc))
    assert auto_accept_due(st, "c", now=now) is False  # <24h


def test_auto_accept_boundary_and_naive(tmp_path):
    st = _state(tmp_path)
    now = datetime(2026, 6, 25, 12, 0, tzinfo=timezone.utc)
    # exactly 24h → due (>= boundary)
    st.set_meta(DETECTED_AT("exact"), datetime(2026, 6, 24, 12, 0, tzinfo=timezone.utc).isoformat())
    assert auto_accept_due(st, "exact", now=now) is True
    # a naive timestamp in the store must not raise; treated as UTC → 25h → due
    st.set_meta(DETECTED_AT("naive"), "2026-06-24T11:00:00")
    assert auto_accept_due(st, "naive", now=now) is True
