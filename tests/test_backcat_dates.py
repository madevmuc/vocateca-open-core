"""Back-catalogue real upload-date backfill (3.1)."""

from __future__ import annotations

from core.backcat_dates import resolve_real_dates, update_pub_dates
from core.state import StateStore


def test_resolve_real_dates_parses_upload_date():
    def fake_enumerate(channel_id, *, full):
        assert full is True
        return [
            {"id": "v1", "upload_date": "20260115"},
            {"id": "v2", "upload_date": "20260220"},
            {"id": "v3"},  # no date → skipped
        ]

    out = resolve_real_dates("UCabc", enumerate_fn=fake_enumerate)
    assert out == {"v1": "2026-01-15", "v2": "2026-02-20"}


def test_update_pub_dates_only_changes_differing(tmp_path):
    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    s.upsert_episode(show_slug="sh", guid="v1", title="A", pub_date="2026-06-26", mp3_url="u")
    s.upsert_episode(show_slug="sh", guid="v2", title="B", pub_date="2026-02-20", mp3_url="u")
    n = update_pub_dates(s, {"v1": "2026-01-15", "v2": "2026-02-20", "v9": "2026-01-01"})
    # v1 changed, v2 identical (no-op), v9 missing → 1 update
    assert n == 1
    assert s.get_episode("v1")["pub_date"] == "2026-01-15"
    assert s.get_episode("v2")["pub_date"] == "2026-02-20"
