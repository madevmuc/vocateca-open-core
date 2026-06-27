"""Re-upload near-duplicate detection (roadmap 3.5).

Detect likely re-uploads of the same episode by **title similarity** — feeds and
channels frequently re-post the same content with a tweaked title ("(re-upload)",
punctuation/spelling drift). This is a non-destructive *reporting* helper: it
surfaces candidate duplicate pairs for the user to act on rather than silently
skipping episodes (a false positive would drop a legitimate episode).

Audio-fingerprint dedup (catching re-uploads with unrelated titles) is the
heavier follow-up — see ``docs/plans/dedupe-fingerprint-design.md``.
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher

_NOISE = re.compile(r"[^\w\s]", re.UNICODE)
_WS = re.compile(r"\s+")
# common re-upload markers + trivial connector words that shouldn't drive a match
_DROP_WORDS = {"reupload", "re", "upload", "und", "and", "the", "der", "die", "das", "a", "an"}


def normalize_title(title: str) -> str:
    """Lowercase, strip punctuation + re-upload markers, collapse whitespace."""
    t = (title or "").lower()
    t = _NOISE.sub(" ", t)
    words = [w for w in _WS.sub(" ", t).strip().split(" ") if w and w not in _DROP_WORDS]
    return " ".join(words)


def title_similarity(a: str, b: str) -> float:
    """Similarity in [0, 1] between two titles after normalisation."""
    na, nb = normalize_title(a), normalize_title(b)
    if not na or not nb:
        return 0.0
    return SequenceMatcher(None, na, nb).ratio()


def find_near_duplicates(
    items: list[tuple[str, str]], *, threshold: float = 0.85
) -> list[tuple[str, str]]:
    """Return ``(guid_a, guid_b)`` pairs whose titles exceed ``threshold``.

    ``items`` is a list of ``(guid, title)``. O(n²); fine for a single show's
    episode list."""
    pairs: list[tuple[str, str]] = []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            if title_similarity(items[i][1], items[j][1]) >= threshold:
                pairs.append((items[i][0], items[j][0]))
    return pairs


def resolve_duplicates(episodes: list[dict], *, threshold: float = 0.9) -> list[str]:
    """Decide which episodes to skip as re-uploads (3.5 auto-skip).

    ``episodes`` is a list of dicts with ``guid``, ``title``, ``status``,
    ``pub_date``. For each near-duplicate cluster keep ONE canonical episode and
    return the guids of the rest to mark SKIPPED. A done/in-flight episode is
    always preferred as the keeper over a pending one (never un-do completed
    work); among same-class duplicates the earliest ``pub_date`` is kept.

    The default threshold (0.9) is deliberately stricter than the reporting
    helper's 0.85 — auto-skipping is destructive, so we only act on very strong
    matches. Returns guids in input order, never including a keeper.
    """
    _ACTIVE = {"done", "downloading", "downloaded", "transcribing"}

    def _rank(ep: dict) -> tuple:
        # Lower sorts first = preferred keeper: active before pending, then
        # earliest pub_date, then stable by guid.
        active = 0 if (ep.get("status") in _ACTIVE) else 1
        return (active, ep.get("pub_date") or "", ep.get("guid") or "")

    skip: list[str] = []
    skipped_set: set[str] = set()
    n = len(episodes)
    for i in range(n):
        a = episodes[i]
        if a["guid"] in skipped_set:
            continue
        for j in range(i + 1, n):
            b = episodes[j]
            if b["guid"] in skipped_set:
                continue
            if title_similarity(a.get("title", ""), b.get("title", "")) >= threshold:
                # The lower-ranked of the pair is the keeper; the other is dropped.
                loser = sorted((a, b), key=_rank)[1]
                # Only skip a PENDING loser — never skip an already-active/done one.
                if loser.get("status") == "pending" and loser["guid"] not in skipped_set:
                    skip.append(loser["guid"])
                    skipped_set.add(loser["guid"])
    return [g for g in (e["guid"] for e in episodes) if g in skipped_set]
