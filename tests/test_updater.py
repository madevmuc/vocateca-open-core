from datetime import datetime, timedelta, timezone

from core.updater import _parse_semver, is_newer, should_notify_tag, should_recheck_update

_NOW = datetime(2026, 5, 17, 12, 0, tzinfo=timezone.utc)


def test_parse_semver_strips_v_prefix():
    assert _parse_semver("v0.5.0") == (0, 5, 0)
    assert _parse_semver("0.5.0") == (0, 5, 0)


def test_parse_semver_handles_prerelease():
    assert _parse_semver("v1.0.0-beta.2") == (1, 0, 0)


def test_is_newer():
    assert is_newer("v0.5.1", "0.5.0")
    assert is_newer("1.0.0", "0.9.9")
    assert not is_newer("0.5.0", "0.5.0")
    assert not is_newer("0.5.0", "0.5.1")


def test_is_newer_tolerates_extra_metadata():
    assert is_newer("v0.6.0-beta", "0.5.0")


def test_check_for_update_uses_configured_repo(monkeypatch):
    from core import updater

    calls = []

    class FakeResp:
        status_code = 200

        def json(self):
            return {"tag_name": "v1.1.0", "html_url": "x"}

    def fake_get(url, **kw):
        calls.append(url)
        return FakeResp()

    class FakeClient:
        def get(self, url, **kw):
            return fake_get(url, **kw)

    monkeypatch.setattr(updater, "get_client", lambda: FakeClient())

    import threading

    notified = threading.Event()
    updater.check_for_update(
        local_version="1.0.0",
        on_update_available=lambda t, u: notified.set(),
        repo="alice/paragraphos-fork",
        timeout=1.0,
    )
    notified.wait(timeout=2.0)
    assert notified.is_set()
    assert len(calls) == 1
    assert any("alice/paragraphos-fork" in u for u in calls)


def test_recheck_when_never_checked():
    assert should_recheck_update(None, _NOW) is True
    assert should_recheck_update("", _NOW) is True


def test_no_recheck_within_interval():
    last = (_NOW - timedelta(hours=5)).isoformat()
    assert should_recheck_update(last, _NOW) is False


def test_recheck_after_interval():
    last = (_NOW - timedelta(hours=25)).isoformat()
    assert should_recheck_update(last, _NOW) is True


def test_recheck_at_exact_boundary():
    last = (_NOW - timedelta(hours=24)).isoformat()
    assert should_recheck_update(last, _NOW) is True


def test_recheck_on_garbage_timestamp():
    assert should_recheck_update("not-a-date", _NOW) is True


def test_should_notify_tag_only_on_change():
    assert should_notify_tag("", "v1.4.0") is True
    assert should_notify_tag("v1.3.0", "v1.4.0") is True
    assert should_notify_tag("v1.4.0", "v1.4.0") is False


def test_recheck_on_naive_timestamp():
    # A tz-less stored timestamp must degrade to a defensive re-check,
    # not raise TypeError out of the activation slot.
    assert should_recheck_update("2026-05-17T00:00:00", _NOW) is True


def test_respects_non_default_interval():
    last = (_NOW - timedelta(hours=2)).isoformat()
    assert should_recheck_update(last, _NOW, min_interval_h=1.0) is True
    assert should_recheck_update(last, _NOW, min_interval_h=5.0) is False
