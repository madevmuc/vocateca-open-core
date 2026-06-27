"""Locale-driven time display format (daily-check field)."""

from __future__ import annotations

from core.timefmt import display_format, uses_ampm


def test_uses_ampm_detects_12h():
    assert uses_ampm("h:mm AP") is True
    assert uses_ampm("h:mm ap") is True
    assert uses_ampm("hh:mm A") is True


def test_uses_ampm_detects_24h():
    assert uses_ampm("HH:mm") is False
    assert uses_ampm("H:mm:ss") is False
    assert uses_ampm("") is False


def test_display_format():
    assert display_format(True) == "h:mm AP"
    assert display_format(False) == "HH:mm"
