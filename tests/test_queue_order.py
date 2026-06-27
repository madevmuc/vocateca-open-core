"""Queue order toggle: claim ordering per settings.queue_order (2.5)."""

from __future__ import annotations

from core.state import StateStore, claim_order_by


def test_claim_order_by_whitelist():
    assert "pub_date ASC" in claim_order_by("oldest_first")
    assert "pub_date DESC" in claim_order_by("newest_first")
    assert "duration_sec" in claim_order_by("shortest_first")
    # unknown/garbage falls back to oldest_first (never raw-interpolated)
    assert claim_order_by("nonsense") == claim_order_by("oldest_first")


def _seed(tmp_path):
    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    rows = [
        ("g_old", "2026-01-01", 1800),
        ("g_mid", "2026-03-01", 600),
        ("g_new", "2026-06-01", 3600),
    ]
    for guid, pub, dur in rows:
        s.upsert_episode(
            show_slug="sh", guid=guid, title=guid, pub_date=pub, mp3_url="u", duration_sec=dur
        )
    return s


def _claim_sequence(s, order):
    frag = claim_order_by(order)
    with s._conn() as c:
        rows = c.execute(
            f"SELECT guid FROM episodes WHERE status='pending' ORDER BY {frag}"
        ).fetchall()
    return [r["guid"] for r in rows]


def test_oldest_first(tmp_path):
    s = _seed(tmp_path)
    assert _claim_sequence(s, "oldest_first") == ["g_old", "g_mid", "g_new"]


def test_newest_first(tmp_path):
    s = _seed(tmp_path)
    assert _claim_sequence(s, "newest_first") == ["g_new", "g_mid", "g_old"]


def test_shortest_first(tmp_path):
    s = _seed(tmp_path)
    assert _claim_sequence(s, "shortest_first") == ["g_mid", "g_old", "g_new"]


def test_shortest_first_unknown_duration_last(tmp_path):
    s = _seed(tmp_path)
    s.upsert_episode(show_slug="sh", guid="g_nodur", title="x", pub_date="2026-02-01", mp3_url="u")
    seq = _claim_sequence(s, "shortest_first")
    assert seq[-1] == "g_nodur"  # NULL duration sorts last
