"""Queue reorder persisted as priority (2.1)."""

from __future__ import annotations

from core.state import StateStore, claim_order_by


def _seed(tmp_path):
    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    for guid, pub in [("g1", "2026-01-01"), ("g2", "2026-01-02"), ("g3", "2026-01-03")]:
        s.upsert_episode(show_slug="sh", guid=guid, title=guid, pub_date=pub, mp3_url="u")
    return s


def _claim_order(s):
    frag = claim_order_by("oldest_first")
    with s._conn() as c:
        rows = c.execute(
            f"SELECT guid FROM episodes WHERE status='pending' ORDER BY {frag}"
        ).fetchall()
    return [r["guid"] for r in rows]


def test_set_priorities_drives_claim_order(tmp_path):
    s = _seed(tmp_path)
    # Visual order chosen by the user: g3, g1, g2.
    s.set_priorities(["g3", "g1", "g2"])
    assert _claim_order(s) == ["g3", "g1", "g2"]


def test_set_priorities_partial(tmp_path):
    s = _seed(tmp_path)
    # Only bump g2 to the top; others keep default priority 0 (date order).
    s.set_priorities(["g2"])
    order = _claim_order(s)
    assert order[0] == "g2"


def test_move_to_top_beats_run_now_bump(tmp_path):
    s = _seed(tmp_path)
    s.set_priority("g1", 10)  # simulate a "Run now" bump on g1
    s.set_priorities(["g3"])  # move g3 to the very top
    assert _claim_order(s)[0] == "g3"


def test_move_to_bottom_sinks(tmp_path):
    s = _seed(tmp_path)
    s.set_priority("g1", 10)  # g1 bumped up
    s.move_to_bottom(["g1"])  # then sunk to the bottom
    assert _claim_order(s)[-1] == "g1"
