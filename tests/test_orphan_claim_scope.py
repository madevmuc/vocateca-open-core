"""Regression: orphan-claim must not re-claim rows downloaded mid-run.

Before this fix, `_DownloadPool._claim_next_processable` claimed any row
with status='downloaded' in scope. But `download_phase` sets that status
between MP3 download and the transcribe worker's dequeue, so a second
download worker could claim a just-downloaded row as an "orphan" and push
a duplicate outcome onto the queue. The result was done_idx > total in
the per-episode notification (e.g. "14/11").

The fix snapshots orphan guids at run-start and scopes the claim to that
set; rows that *become* downloaded mid-run are no longer claimable.
"""

from __future__ import annotations

import threading
from queue import Queue

from core.state import StateStore
from ui.worker_thread import _DownloadPool


def _make_pool(state, scope_slug, orphan_guids):
    return _DownloadPool(
        ctx=type("Ctx", (), {"state": state})(),
        show_by_slug={},
        ep_num_map={},
        scope_slugs=[scope_slug],
        pctx_for=lambda show: None,
        out_q=Queue(),
        host_counter={},
        host_lock=threading.Lock(),
        host_cap=1,
        stop_flag=threading.Event(),
        workers=1,
        orphan_guids=orphan_guids,
    )


def test_orphan_claim_ignores_mid_run_downloaded(tmp_path):
    state = StateStore(tmp_path / "state.sqlite")
    state.init_schema()
    # A real orphan from a prior run.
    state.upsert_episode(
        show_slug="show1", guid="orphan-1", title="A", pub_date="2026-01-01", mp3_url="u"
    )
    # An in-pass row that the current run just finished downloading.
    state.upsert_episode(
        show_slug="show1", guid="midrun-1", title="B", pub_date="2026-01-02", mp3_url="u"
    )
    with state._conn() as c:
        c.execute("UPDATE episodes SET status='downloaded' WHERE guid IN ('orphan-1', 'midrun-1')")

    # Snapshot at run-start: only the true orphan is captured.
    pool = _make_pool(state, "show1", orphan_guids=["orphan-1"])

    first = pool._claim_next_processable()
    assert first is not None
    row, prior = first
    assert row["guid"] == "orphan-1"
    assert prior == "downloaded"

    # The mid-run downloaded row must NOT be claimable as an orphan.
    second = pool._claim_next_processable()
    assert second is None, "mid-run downloaded row was wrongly re-claimed as orphan"


def test_orphan_claim_empty_snapshot(tmp_path):
    """No true orphans at run start → orphan branch returns nothing even
    when rows transition through 'downloaded' during the run."""
    state = StateStore(tmp_path / "state.sqlite")
    state.init_schema()
    state.upsert_episode(
        show_slug="show1", guid="midrun-1", title="A", pub_date="2026-01-01", mp3_url="u"
    )
    with state._conn() as c:
        c.execute("UPDATE episodes SET status='downloaded' WHERE guid='midrun-1'")

    pool = _make_pool(state, "show1", orphan_guids=[])
    assert pool._claim_next_processable() is None
