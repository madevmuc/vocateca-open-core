"""Power-state detection + battery load adaptation (8.4)."""

from __future__ import annotations

from core.power import parse_pmset_on_battery

_BATT = (
    "Now drawing from 'Battery Power'\n"
    " -InternalBattery-0 (id=12345)\t95%; discharging; 5:23 remaining present: true\n"
)
_AC = (
    "Now drawing from 'AC Power'\n"
    " -InternalBattery-0 (id=12345)\t100%; charged; 0:00 remaining present: true\n"
)


def test_parse_on_battery():
    assert parse_pmset_on_battery(_BATT) is True


def test_parse_on_ac():
    assert parse_pmset_on_battery(_AC) is False


def test_parse_empty_assumes_ac():
    assert parse_pmset_on_battery("") is False


def test_effective_load_level_on_battery():
    from core.power import effective_load_level

    # pause_on_battery off → no change; on → drop to battery_load_level
    assert (
        effective_load_level("full", on_battery=True, pause_on_battery=False, battery_level="quiet")
        == "full"
    )
    assert (
        effective_load_level("full", on_battery=True, pause_on_battery=True, battery_level="quiet")
        == "quiet"
    )
    assert (
        effective_load_level("full", on_battery=False, pause_on_battery=True, battery_level="quiet")
        == "full"
    )


def test_should_pause_for_battery():
    from core.power import should_pause_for_battery

    # off → never pause regardless of power state
    assert should_pause_for_battery(pause_queue_on_battery=False, on_battery_now=True) is False
    # on + on battery → pause
    assert should_pause_for_battery(pause_queue_on_battery=True, on_battery_now=True) is True
    # on + plugged in → don't pause
    assert should_pause_for_battery(pause_queue_on_battery=True, on_battery_now=False) is False
