"""Event-driven webhooks (roadmap 10.1).

A bus subscriber dispatches user-configured webhooks when matching events fire:

* ``kind="command"`` — run a local script with the event JSON on stdin.
* ``kind="post"`` — HTTP POST the event JSON to a URL (validated by ``safe_url``
  to block SSRF against private/loopback hosts).

Dispatch runs in a worker thread and **every failure is logged and swallowed**,
never blocking the pipeline. Matching/serialisation are pulled out as pure
functions for testing.
"""

from __future__ import annotations

import json
import logging
import subprocess
import threading

from core.security import safe_url

_logger = logging.getLogger("paragraphos.webhooks")

_COMMAND_TIMEOUT_SEC = 30
_POST_TIMEOUT_SEC = 15


def event_to_json(event) -> str:
    """Serialise an Event to a JSON string for delivery."""
    return json.dumps(
        {
            "type": event.type,
            "ts": event.ts,
            "show_slug": event.show_slug,
            "guid": event.guid,
            "payload": event.payload or {},
        },
        ensure_ascii=False,
    )


def webhook_matches(webhook: dict, event_type: str) -> bool:
    """Whether ``webhook`` should fire for ``event_type``.

    ``events`` is a list of exact types / prefixes (``"episode."``); an empty
    list means "all". A disabled webhook never matches."""
    if not webhook.get("enabled", True):
        return False
    patterns = webhook.get("events") or []
    if not patterns:
        return True
    for pat in patterns:
        if pat == "" or pat == event_type:
            return True
        if pat.endswith(".") and event_type.startswith(pat):
            return True
    return False


def _run_command(target: str, event) -> None:
    """Run ``target`` as a script, feeding the event JSON on stdin.

    ``target`` is shell-word-split so a command may carry arguments
    (e.g. ``"/path/notify.sh --tag run"``); a bare path still works."""
    import shlex

    argv = shlex.split(target)
    if not argv:
        return
    subprocess.run(
        argv,
        input=event_to_json(event),
        text=True,
        timeout=_COMMAND_TIMEOUT_SEC,
        capture_output=True,
    )


def _http_post(target: str, event) -> None:
    """POST the event JSON to ``target`` after an SSRF safety check."""
    safe_url(target)  # raises UnsafeURLError for private/loopback/non-http
    import httpx

    httpx.post(
        target,
        content=event_to_json(event),
        headers={"Content-Type": "application/json"},
        timeout=_POST_TIMEOUT_SEC,
    )


def _dispatch_one(event, wh: dict, *, run_command=_run_command, http_post=_http_post) -> None:
    """Run a single matching webhook; failures are logged and swallowed."""
    try:
        if not webhook_matches(wh, event.type):
            return
        kind = wh.get("kind")
        target = wh.get("target") or ""
        if not target:
            return
        if kind == "command":
            run_command(target, event)
        elif kind == "post":
            http_post(target, event)
    except Exception:
        _logger.exception("webhook dispatch failed for %s → %s", event.type, wh.get("target"))


def dispatch(
    event, webhooks: list[dict], *, run_command=_run_command, http_post=_http_post
) -> None:
    """Synchronously dispatch ``event`` to all matching webhooks (in order).

    Each webhook's failure is logged and swallowed so one bad hook never blocks
    the others or the caller. Executors are injectable for testing."""
    for wh in webhooks or []:
        _dispatch_one(event, wh, run_command=run_command, http_post=http_post)


def install(get_settings) -> None:
    """Subscribe a non-blocking webhook dispatcher to the event bus.

    ``get_settings`` returns the current Settings (read fresh per event so the
    list stays live). Dispatch runs in a daemon thread so the pipeline never
    waits on a slow webhook."""
    from core import events

    def _on_event(event) -> None:
        try:
            settings = get_settings()
            if not getattr(settings, "webhooks_enabled", False):
                return
            hooks = list(getattr(settings, "webhooks", []) or [])
            matching = [wh for wh in hooks if webhook_matches(wh, event.type)]
            # One daemon thread per matching hook so a slow command hook doesn't
            # delay the others in the same event's batch (and never blocks the
            # bus emit / pipeline).
            for wh in matching:
                threading.Thread(
                    target=_dispatch_one, args=(event, wh), name="webhook-dispatch", daemon=True
                ).start()
        except Exception:
            _logger.exception("webhook install handler failed")

    events.subscribe_once("", _on_event)
