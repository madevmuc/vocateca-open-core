"""Watch-folder post-transcribe action: move-to-done / delete + retroactive sweep."""

from __future__ import annotations

from pathlib import Path

from core.state import EpisodeStatus, StateStore
from core.watch_post import apply_post_action, collect_retroactive, done_dir


def _touch(p: Path) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"audio")
    return p


def test_keep_is_noop(tmp_path):
    src = _touch(tmp_path / "a.mp3")
    assert apply_post_action(src, "keep", tmp_path) is None
    assert src.exists()


def test_move_relocates_into_done(tmp_path):
    src = _touch(tmp_path / "a.mp3")
    dest = apply_post_action(src, "move", tmp_path)
    assert dest == done_dir(tmp_path) / "a.mp3"
    assert dest.exists()
    assert not src.exists()


def test_move_handles_name_collision(tmp_path):
    _touch(done_dir(tmp_path) / "a.mp3")  # pre-existing in done/
    src = _touch(tmp_path / "a.mp3")
    dest = apply_post_action(src, "move", tmp_path)
    assert dest == done_dir(tmp_path) / "a_1.mp3"
    assert dest.exists()
    assert not src.exists()


def test_delete_removes_source(tmp_path):
    src = _touch(tmp_path / "a.mp3")
    assert apply_post_action(src, "delete", tmp_path) is None
    assert not src.exists()


def test_missing_source_is_noop(tmp_path):
    assert apply_post_action(tmp_path / "ghost.mp3", "move", tmp_path) is None


def test_does_not_move_files_already_in_done(tmp_path):
    src = _touch(done_dir(tmp_path) / "a.mp3")
    # A file already living under done/ should not be moved again.
    assert apply_post_action(src, "move", tmp_path) is None
    assert src.exists()


def test_collect_retroactive_finds_done_local_sources(tmp_path):
    root = tmp_path / "watch"
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    # Two done episodes with on-disk local sources under the watch root, one
    # pending, and one done whose source is outside the root.
    f1 = _touch(root / "show/ep1.mp3")
    f2 = _touch(root / "show/ep2.mp3")
    outside = _touch(tmp_path / "elsewhere/ep3.mp3")
    for guid, title, path, status in [
        ("g1", "ep1", f1, EpisodeStatus.DONE),
        ("g2", "ep2", f2, EpisodeStatus.DONE),
        ("g3", "ep3", outside, EpisodeStatus.DONE),
        ("g4", "ep4", root / "show/ep4.mp3", EpisodeStatus.PENDING),
    ]:
        state.upsert_episode(
            show_slug="show", guid=guid, title=title, pub_date="2026-01-01", mp3_url="u"
        )
        state.set_meta(f"local_path:{guid}", str(path))
        state.set_status(guid, status)

    found = collect_retroactive(state, ["show"], root)
    guids = {g for g, _ in found}
    assert guids == {"g1", "g2"}  # only done + under-root + existing


def test_pipeline_hook_moves_local_source_on_done(tmp_path):
    """core.pipeline._apply_watch_post moves a local source when set to 'move'."""
    from core.pipeline import _apply_watch_post

    root = tmp_path / "watch"
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    src = _touch(root / "a.mp3")
    state.upsert_episode(show_slug="s", guid="g1", title="a", pub_date="2026-01-01", mp3_url="u")
    state.set_meta("local_path:g1", str(src))

    class _Ctx:
        pass

    ctx = _Ctx()
    ctx.state = state
    ctx.watch_folder_post = "move"
    ctx.watch_folder_root = str(root)
    _apply_watch_post(ctx, "g1")
    assert not src.exists()
    assert (done_dir(root) / "a.mp3").exists()


def test_pipeline_hook_keep_is_noop(tmp_path):
    from core.pipeline import _apply_watch_post

    root = tmp_path / "watch"
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    src = _touch(root / "a.mp3")
    state.upsert_episode(show_slug="s", guid="g1", title="a", pub_date="2026-01-01", mp3_url="u")
    state.set_meta("local_path:g1", str(src))

    class _Ctx:
        pass

    ctx = _Ctx()
    ctx.state = state
    ctx.watch_folder_post = "keep"
    ctx.watch_folder_root = str(root)
    _apply_watch_post(ctx, "g1")
    assert src.exists()  # untouched
