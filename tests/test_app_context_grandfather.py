# tests/test_app_context_grandfather.py
from core.watchlist_guard import GRANDFATHERED, is_decided
from ui.app_context import AppContext


def test_load_grandfathers_existing_shows_and_sets_hash(tmp_path):
    (tmp_path / "watchlist.yaml").write_text(
        "shows:\n- {slug: a, title: A, rss: 'http://h/a'}\n", encoding="utf-8"
    )
    ctx = AppContext.load(tmp_path)
    assert ctx.state.get_meta(GRANDFATHERED) == "1"
    assert is_decided(ctx.state, "a")
    assert ctx._watchlist_hash  # baseline recorded
