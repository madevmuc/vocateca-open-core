"""Pill-kind mapping for the show-details episode table.

`deferred` ("waiting to be re-checked later", e.g. a live/premiere not yet
finished) and `skipped` (intentionally not processed) are *not* failures —
they must map to a non-`"fail"` pill kind. The episode table looks the
status string up in `_STATUS_PILL_KIND`, falling back to `"idle"` for
unknown statuses, so these entries must actually be present.
"""

from ui.show_details_dialog import _STATUS_PILL_KIND
from ui.widgets.pill import Pill


def test_deferred_pill_kind_is_not_fail():
    assert "deferred" in _STATUS_PILL_KIND
    kind = _STATUS_PILL_KIND["deferred"]
    assert kind != "fail"
    assert kind in Pill.ALLOWED_KINDS


def test_skipped_pill_kind_is_not_fail():
    kind = _STATUS_PILL_KIND["skipped"]
    assert kind != "fail"
    assert kind in Pill.ALLOWED_KINDS


def test_pill_kind_lookup_for_new_states():
    # The table does `_STATUS_PILL_KIND.get(status, "idle")`. Assert the new
    # states resolve to their intended kinds rather than silently falling
    # through to the "idle" default.
    assert _STATUS_PILL_KIND.get("deferred", "idle") == "pausing"
    assert _STATUS_PILL_KIND.get("skipped", "idle") == "idle"
