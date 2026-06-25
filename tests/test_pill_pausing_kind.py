from ui.themes.tokens import DARK, LIGHT
from ui.widgets.pill import Pill


def test_pausing_is_allowed_kind():
    assert "pausing" in Pill.ALLOWED_KINDS


def test_both_themes_define_pausing_pill_tokens():
    for theme in (LIGHT, DARK):
        assert "pill_pausing_bg" in theme
        assert "pill_pausing_fg" in theme
