# tests/test_backlog.py
import pytest

from core.backlog import BacklogError, apply_backlog, parse_backlog
from core.state import StateStore


def _seed(tmp_path, n=10):
    st = StateStore(tmp_path / "s.sqlite")
    st.init_schema()
    manifest = []
    for i in range(n):
        guid = f"g{i}"
        # pub_date ascending; i=0 oldest, i=n-1 newest
        pub = f"2026-01-{i + 1:02d}T00:00:00"
        st.upsert_episode(
            show_slug="x", guid=guid, title=f"t{i}", pub_date=pub, mp3_url=f"http://h/{i}.mp3"
        )
        manifest.append({"guid": guid, "pubDate": pub})
    return st, manifest


def _count(st, status):
    with st._conn() as c:
        return c.execute(
            "SELECT COUNT(*) n FROM episodes WHERE show_slug='x' AND status=?", (status,)
        ).fetchone()["n"]


def test_parse_canonical_modes():
    assert parse_backlog("all") == ("all", None)
    assert parse_backlog("recent") == ("recent", None)
    assert parse_backlog("last:5") == ("last", 5)
    assert parse_backlog("since:2026-01-05") == ("since", "2026-01-05")


def test_parse_rejects_garbage():
    with pytest.raises(BacklogError):
        parse_backlog("last:notanumber")
    with pytest.raises(BacklogError):
        parse_backlog("since:nope")
    with pytest.raises(BacklogError):
        parse_backlog("bogus")


def test_apply_all_leaves_everything_pending(tmp_path):
    st, manifest = _seed(tmp_path)
    apply_backlog(st, "x", ("all", None), manifest)
    assert _count(st, "pending") == 10


def test_apply_last_keeps_newest_n(tmp_path):
    st, manifest = _seed(tmp_path)
    apply_backlog(st, "x", ("last", 3), manifest)
    assert _count(st, "pending") == 3
    assert _count(st, "done") == 7


def test_apply_recent_keeps_one(tmp_path):
    st, manifest = _seed(tmp_path)
    apply_backlog(st, "x", ("recent", None), manifest)
    assert _count(st, "pending") == 1


def test_apply_since_marks_older_done(tmp_path):
    st, manifest = _seed(tmp_path)
    # keep episodes with pub_date >= 2026-01-06  → i in 5..9 = 5 pending
    apply_backlog(st, "x", ("since", "2026-01-06"), manifest)
    assert _count(st, "pending") == 5


def test_apply_since_keeps_unparseable_pubdate_pending(tmp_path):
    st, manifest = _seed(tmp_path, n=3)
    # add an episode with a junk pubDate to the DB + manifest
    st.upsert_episode(
        show_slug="x", guid="gjunk", title="junk", pub_date="not-a-date", mp3_url="http://h/j.mp3"
    )
    manifest.append({"guid": "gjunk", "pubDate": "not-a-date"})
    apply_backlog(st, "x", ("since", "2026-01-06"), manifest)
    with st._conn() as c:
        status = c.execute("SELECT status FROM episodes WHERE guid='gjunk'").fetchone()["status"]
    assert status == "pending"  # fail-open: unparseable date is kept
