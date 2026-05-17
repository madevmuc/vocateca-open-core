"""Daily scheduler with catch-up logic."""

from __future__ import annotations

from datetime import datetime, time, timezone
from typing import Callable, Optional

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger


def _parse_hhmm(s: str) -> time:
    hh, mm = s.split(":")
    return time(int(hh), int(mm))


def should_catch_up(
    last_check_iso: Optional[str], daily_time_hhmm: str, now: Optional[datetime] = None
) -> bool:
    now = now or datetime.now(timezone.utc)
    slot = _parse_hhmm(daily_time_hhmm)
    today_slot = datetime.combine(now.date(), slot, tzinfo=now.tzinfo)
    if last_check_iso is None:
        return True
    last = datetime.fromisoformat(last_check_iso)
    # Past today's slot & last check was before today's slot → catch up.
    if now >= today_slot and last < today_slot:
        return True
    return False


def build_scheduler(daily_time_hhmm: str, job: Callable[[], None]) -> BackgroundScheduler:
    sched = BackgroundScheduler(timezone="UTC")
    hh, mm = daily_time_hhmm.split(":")
    sched.add_job(
        job, CronTrigger(hour=int(hh), minute=int(mm)), id="daily_check", replace_existing=True
    )
    return sched


def check_counts_as_success(*, stopped: bool, paused: bool, online: bool) -> bool:
    """A daily check only advances ``last_successful_check`` when it ran
    cleanly: not user-stopped / offline-paused, queue not paused, and the
    network was up. Individual feed errors still count as success — they
    have their own 1/3/7-day backoff, so one broken feed must not trigger
    an endless catch-up loop."""
    return not stopped and not paused and online
