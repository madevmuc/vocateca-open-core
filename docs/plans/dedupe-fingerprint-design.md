# Re-upload dedupe — audio-fingerprint design (follow-up to 3.5)

- **Date:** 2026-06-27
- **Status:** Design note (deferred from the roadmap-execution run)
- **Shipped in the run:** title-similarity detection (`core/dedupe.py`) +
  `cli.py find-duplicates <slug>` (non-destructive reporting).

## Problem

Title similarity catches the common case (same episode re-posted with a tweaked
title) but misses re-uploads with **unrelated titles** (e.g. a "best of"
re-cut, or a channel re-posting under a new headline). Catching those needs a
content fingerprint, not a string compare.

## Proposed approach

1. **Fingerprint** — compute a cheap perceptual audio fingerprint per episode
   after download. Options, lightest first:
   - **Chromaprint / `fpcalc`** (AcoustID): industry-standard audio fingerprint;
     compare via Hamming distance on the 32-bit subfingerprint stream. Needs the
     `fpcalc` binary (Apache-2.0/LGPL) — a documented optional dependency, kept
     off the default path like the diarization model.
   - **MFCC min-hash** (pure-Python via numpy): no extra binary, but heavier and
     less robust than Chromaprint.
2. **Store** the fingerprint in a new `episodes.audio_fingerprint TEXT` column
   (additive migration, like `duration_sec`).
3. **Compare** a new episode's fingerprint against existing fingerprints for the
   same show (and optionally cross-show), flagging matches above a distance
   threshold as `SKIPPED` reason `audio-duplicate` (or surfacing them via the
   existing `find-duplicates` report for confirmation).

## Why deferred

- Adds a binary dependency (`fpcalc`) + a model-like setup step.
- Fingerprint extraction is CPU work best folded into the transcribe pipeline,
  which interacts with the parallel-transcription work (2.2, also deferred).
- The title-similarity reporter already covers the dominant real-world case
  safely (non-destructive), so the high-risk fingerprint path can wait for an
  explicit opt-in.

## Interface sketch

```python
# core/fingerprint.py (future)
def fingerprint_audio(path: Path) -> str | None: ...     # fpcalc → compact str
def fingerprint_distance(a: str, b: str) -> float: ...    # 0 = identical
def is_audio_duplicate(fp: str, existing: list[str], *, max_distance: float) -> bool: ...
```
