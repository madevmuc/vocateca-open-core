"""Re-upload near-duplicate detection by title similarity (3.5)."""

from __future__ import annotations

from core.dedupe import (
    find_near_duplicates,
    normalize_title,
    resolve_duplicates,
    title_similarity,
)


def test_normalize_strips_noise():
    assert normalize_title("  Episode 12: The BIG Deal! (re-upload) ") == normalize_title(
        "episode 12 the big deal re-upload"
    )


def test_identical_titles_max_similarity():
    assert title_similarity("Hello World", "hello world") == 1.0


def test_near_duplicate_detected():
    a = "Fix & Flip — 10 Fragen an einen Makler"
    b = "Fix und Flip - 10 Fragen an einen Makler (Reupload)"
    assert title_similarity(a, b) > 0.7


def test_distinct_titles_low_similarity():
    assert title_similarity("The housing market in 2026", "Cooking pasta at home") < 0.4


def test_find_near_duplicates_groups():
    titles = [
        ("g1", "Episode 5 — Interest rates"),
        ("g2", "Episode 5 - Interest Rates (re-upload)"),
        ("g3", "Episode 6 — Rent control"),
    ]
    dups = find_near_duplicates(titles, threshold=0.85)
    # g1/g2 are near-dups; g3 stands alone
    flagged = {guid for pair in dups for guid in pair}
    assert "g1" in flagged and "g2" in flagged
    assert "g3" not in flagged


def test_resolve_duplicates_keeps_one_pending():
    eps = [
        {
            "guid": "g1",
            "title": "Episode 5 — Interest rates",
            "status": "pending",
            "pub_date": "2026-01-01",
        },
        {
            "guid": "g2",
            "title": "Episode 5 - Interest Rates (re-upload)",
            "status": "pending",
            "pub_date": "2026-01-02",
        },
        {
            "guid": "g3",
            "title": "Episode 6 — Rent control",
            "status": "pending",
            "pub_date": "2026-01-03",
        },
    ]
    skip = resolve_duplicates(eps)
    # The later re-upload (g2) is skipped; the earlier original (g1) kept; g3 alone.
    assert skip == ["g2"]


def test_resolve_duplicates_never_skips_done():
    eps = [
        {"guid": "g1", "title": "The Big Show", "status": "done", "pub_date": "2026-01-02"},
        {
            "guid": "g2",
            "title": "The Big Show (reupload)",
            "status": "pending",
            "pub_date": "2026-01-01",
        },
    ]
    # Even though g2 is earlier, the DONE episode is the keeper; the pending dup is skipped.
    assert resolve_duplicates(eps) == ["g2"]


def test_resolve_duplicates_distinct_kept():
    eps = [
        {
            "guid": "g1",
            "title": "Monday market update",
            "status": "pending",
            "pub_date": "2026-01-01",
        },
        {
            "guid": "g2",
            "title": "Cooking risotto tonight",
            "status": "pending",
            "pub_date": "2026-01-02",
        },
    ]
    assert resolve_duplicates(eps) == []
