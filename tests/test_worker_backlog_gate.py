# tests/test_worker_backlog_gate.py
from core.state import StateStore
from core.watchlist_guard import mark_decided
from ui.worker_thread import show_is_gated


def _st(tmp_path):
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    return st


def test_undecided_show_is_gated(tmp_path):
    st = _st(tmp_path)
    assert show_is_gated(st, "newshow") is True  # no marker → gated


def test_decided_show_not_gated(tmp_path):
    st = _st(tmp_path)
    mark_decided(st, "ok")
    assert show_is_gated(st, "ok") is False


def test_paused_still_gated(tmp_path):
    st = _st(tmp_path)
    mark_decided(st, "p")
    st.set_meta("show_paused:p", "1")
    assert show_is_gated(st, "p") is True  # paused OR undecided
