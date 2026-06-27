from pathlib import Path

from core.state import EpisodeStatus, StateStore


def _fresh(tmp_path: Path) -> StateStore:
    db = StateStore(tmp_path / "state.sqlite")
    db.init_schema()
    return db


def test_skipped_and_deferred_enum_exist():
    assert EpisodeStatus.SKIPPED.value == "skipped"
    assert EpisodeStatus.DEFERRED.value == "deferred"


def test_set_status_round_trips_new_states(tmp_path: Path):
    db = _fresh(tmp_path)
    db.upsert_episode(show_slug="s", guid="g", title="T", pub_date="2026-04-01", mp3_url="u")
    db.set_status("g", EpisodeStatus.DEFERRED)
    assert db.get_episode("g")["status"] == "deferred"
    db.set_status("g", EpisodeStatus.SKIPPED)
    assert db.get_episode("g")["status"] == "skipped"


def test_deferred_and_skipped_excluded_from_pending_pool(tmp_path: Path):
    db = _fresh(tmp_path)
    db.upsert_episode(show_slug="s", guid="g1", title="T1", pub_date="2026-04-01", mp3_url="u")
    db.upsert_episode(show_slug="s", guid="g2", title="T2", pub_date="2026-04-02", mp3_url="u")
    db.set_status("g1", EpisodeStatus.DEFERRED)
    db.set_status("g2", EpisodeStatus.SKIPPED)
    pend = db.list_by_status("s", EpisodeStatus.PENDING)
    guids = {p["guid"] for p in pend}
    assert "g1" not in guids
    assert "g2" not in guids


def test_deferred_not_counted_as_failed(tmp_path: Path):
    db = _fresh(tmp_path)
    db.upsert_episode(show_slug="s", guid="g", title="T", pub_date="2026-04-01", mp3_url="u")
    db.set_status("g", EpisodeStatus.DEFERRED)
    failed = db.list_by_status("s", EpisodeStatus.FAILED)
    assert "g" not in {f["guid"] for f in failed}


def test_paused_enum_exists():
    assert EpisodeStatus.PAUSED.value == "paused"


def test_delete_episodes_for_show_purges_rows(tmp_path: Path):
    """Removing a show purges its episode rows so re-adding the same channel
    starts fresh (no leftover 'done' episodes blocking the queue)."""
    db = _fresh(tmp_path)
    for i in range(3):
        db.upsert_episode(
            show_slug="ch", guid=f"v{i}", title="T", pub_date="2026-04-01", mp3_url="u"
        )
    db.upsert_episode(show_slug="other", guid="x", title="T", pub_date="2026-04-01", mp3_url="u")
    db.set_status("v0", EpisodeStatus.DONE)
    n = db.delete_episodes_for_show("ch")
    assert n == 3
    assert db.get_episode("v0") is None
    assert db.get_episode("v1") is None
    # An unrelated show is untouched.
    assert db.get_episode("x") is not None
