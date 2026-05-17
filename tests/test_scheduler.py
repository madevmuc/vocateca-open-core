from datetime import datetime, timezone

from core.scheduler import build_scheduler, check_counts_as_success, should_catch_up


def test_catch_up_needed_if_no_last_check():
    assert (
        should_catch_up(None, "09:00", now=datetime(2026, 4, 20, 12, 0, tzinfo=timezone.utc))
        is True
    )


def test_no_catch_up_if_checked_today_after_slot():
    last = datetime(2026, 4, 20, 9, 30, tzinfo=timezone.utc)
    now = datetime(2026, 4, 20, 14, 0, tzinfo=timezone.utc)
    assert should_catch_up(last.isoformat(), "09:00", now) is False


def test_catch_up_if_today_but_before_slot():
    last = datetime(2026, 4, 19, 9, 5, tzinfo=timezone.utc)
    now = datetime(2026, 4, 20, 10, 0, tzinfo=timezone.utc)
    assert should_catch_up(last.isoformat(), "09:00", now) is True


def test_no_catch_up_if_before_todays_slot_and_checked_yesterday_after_slot():
    last = datetime(2026, 4, 19, 9, 5, tzinfo=timezone.utc)
    now = datetime(2026, 4, 20, 8, 0, tzinfo=timezone.utc)
    assert should_catch_up(last.isoformat(), "09:00", now) is False


def test_build_scheduler_registers_job():
    calls = []
    sched = build_scheduler("09:00", lambda: calls.append(1))
    assert sched.get_job("daily_check") is not None


def test_success_when_clean_run_online():
    assert check_counts_as_success(stopped=False, paused=False, online=True) is True


def test_not_success_when_stopped():
    assert check_counts_as_success(stopped=True, paused=False, online=True) is False


def test_not_success_when_paused():
    assert check_counts_as_success(stopped=False, paused=True, online=True) is False


def test_not_success_when_offline():
    assert check_counts_as_success(stopped=False, paused=False, online=False) is False
