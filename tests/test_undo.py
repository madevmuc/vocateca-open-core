"""Time-boxed undo manager + trash round-trip (9.5)."""

from __future__ import annotations

from ui.undo import UndoManager


def test_push_and_undo_runs_callable_and_returns_label():
    clock = [0.0]
    mgr = UndoManager(clock=lambda: clock[0])
    ran = []
    mgr.push("Removed show X", lambda: ran.append("x"), ttl_sec=60)
    label = mgr.undo_last()
    assert label == "Removed show X"
    assert ran == ["x"]


def test_undo_empty_returns_none():
    mgr = UndoManager(clock=lambda: 0.0)
    assert mgr.undo_last() is None


def test_expired_action_returns_none_and_does_not_run():
    clock = [0.0]
    mgr = UndoManager(clock=lambda: clock[0])
    ran = []
    mgr.push("X", lambda: ran.append("x"), ttl_sec=60)
    clock[0] = 61.0  # past expiry
    assert mgr.undo_last() is None
    assert ran == []


def test_peek_reports_most_recent_unexpired():
    clock = [0.0]
    mgr = UndoManager(clock=lambda: clock[0])
    mgr.push("A", lambda: None, ttl_sec=60)
    mgr.push("B", lambda: None, ttl_sec=60)
    assert mgr.peek().label == "B"


def test_undo_is_lifo():
    mgr = UndoManager(clock=lambda: 0.0)
    order = []
    mgr.push("A", lambda: order.append("A"))
    mgr.push("B", lambda: order.append("B"))
    mgr.undo_last()
    mgr.undo_last()
    assert order == ["B", "A"]


def test_state_snapshot_restore_statuses(tmp_path):
    from core.state import StateStore

    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    s.upsert_episode(show_slug="sh", guid="g1", title="A", pub_date="2026-01-01", mp3_url="u")
    s.upsert_episode(show_slug="sh", guid="g2", title="B", pub_date="2026-01-02", mp3_url="u")
    snap = s.snapshot_statuses(["pending"])
    assert len(snap) == 2
    s.clear_pending()  # → all done
    assert s.get_episode("g1")["status"] == "done"
    s.restore_statuses(snap)
    assert s.get_episode("g1")["status"] == "pending"
    assert s.get_episode("g2")["status"] == "pending"


def test_trash_roundtrip(tmp_path):
    from core.paths import trash_dir
    from ui.undo import trash_file

    data_dir = tmp_path / "data"
    data_dir.mkdir()
    f = tmp_path / "transcript.md"
    f.write_text("hello", encoding="utf-8")

    restore = trash_file(f, data_dir=data_dir)
    assert not f.exists()
    assert trash_dir(data_dir).exists()
    # undo restores the file with its original content
    restore()
    assert f.exists()
    assert f.read_text(encoding="utf-8") == "hello"
