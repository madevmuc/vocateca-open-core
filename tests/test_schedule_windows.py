"""Processing-window gating (2.3)."""

from __future__ import annotations

from core.schedule_windows import within_windows


def test_empty_windows_always_allowed():
    assert within_windows("03:00", []) is True


def test_simple_window():
    assert within_windows("13:00", ["09:00-17:00"]) is True
    assert within_windows("18:00", ["09:00-17:00"]) is False


def test_midnight_wrap_window():
    assert within_windows("23:30", ["22:00-06:00"]) is True
    assert within_windows("02:00", ["22:00-06:00"]) is True
    assert within_windows("12:00", ["22:00-06:00"]) is False


def test_multiple_windows():
    wins = ["06:00-09:00", "22:00-23:59"]
    assert within_windows("07:00", wins) is True
    assert within_windows("22:30", wins) is True
    assert within_windows("15:00", wins) is False


def test_non_zero_padded_input():
    # "8:00" must compare correctly against "08:30" (zero-pad normalisation).
    assert within_windows("08:30", ["8:00-9:00"]) is True
    assert within_windows("09:30", ["8:00-9:00"]) is False


def test_malformed_window_ignored():
    # A bad entry must not crash; it's simply skipped.
    assert within_windows("07:00", ["garbage", "06:00-09:00"]) is True
    assert within_windows("15:00", ["garbage"]) is False
