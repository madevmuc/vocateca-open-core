"""Parallel-transcription worker resolution (2.2)."""

from __future__ import annotations

from core.load import resolve_transcribe_workers


def test_default_keeps_profile_choice():
    # transcribe_concurrency == 1 (default) must not reduce a "full" profile's 2.
    assert resolve_transcribe_workers(2, 1) == 2
    assert resolve_transcribe_workers(1, 1) == 1


def test_override_raises_cap():
    assert resolve_transcribe_workers(1, 4) == 4
    assert resolve_transcribe_workers(2, 3) == 3


def test_floors_at_one():
    assert resolve_transcribe_workers(0, 0) == 1
    assert resolve_transcribe_workers(0, 1) == 1


def test_ram_cap_limits_workers():
    # 4 requested, but only 6 GB RAM at 3 GB/worker → capped to 2.
    assert resolve_transcribe_workers(1, 4, ram_gb=6, per_worker_gb=3.0) == 2
    # Plenty of RAM → no cap.
    assert resolve_transcribe_workers(1, 4, ram_gb=64, per_worker_gb=3.0) == 4
    # Tiny RAM still floors at 1.
    assert resolve_transcribe_workers(1, 4, ram_gb=2, per_worker_gb=3.0) == 1
    # ram_gb=None disables the cap.
    assert resolve_transcribe_workers(1, 4, ram_gb=None) == 4


def test_concurrent_claim_never_double_claims(tmp_path):
    """Many threads claiming concurrently must each get a distinct episode (2.2)."""
    import threading

    from core.state import StateStore, claim_order_by

    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    n = 40
    for i in range(n):
        s.upsert_episode(
            show_slug="sh",
            guid=f"g{i:03d}",
            title=f"e{i}",
            pub_date=f"2026-01-{(i % 28) + 1:02d}",
            mp3_url="u",
        )
    order = claim_order_by("oldest_first")
    claimed: list[str] = []
    lock = threading.Lock()

    def worker():
        while True:
            row = s.claim_one_pending(["sh"], order)
            if row is None:
                return
            with lock:
                claimed.append(row["guid"])

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(claimed) == n
    assert len(set(claimed)) == n  # no guid claimed twice
