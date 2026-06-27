# Parallel transcription — design (roadmap 2.2)

- **Date:** 2026-06-27 · **Status:** Design + flag-gated skeleton (escape hatch)
- **Shipped:** `transcribe_concurrency` setting (default **1** = serial, safe).
  The worker already spawns `load_profile.parallel` transcribe workers off one
  shared queue; this note covers making the cap user-controllable + safe.

## Why design-only

whisper.cpp is already heavily multi-threaded per invocation, so running N
whisper processes concurrently mostly **oversubscribes** the CPU/GPU and can be
*slower* plus memory-risky (each large-v3 process holds the model). Validating a
safe concurrency policy across machine classes isn't an overnight change, so the
default stays 1.

## Current architecture (relevant)

`ui/worker_thread.py`: `_DownloadPool` (N download threads) feeds a bounded
`queue.Queue`; `_TranscribeWorker`s drain it. The worker already creates
`n_tr = load_profile.parallel` transcribe workers — so the *plumbing* for
parallel transcribe exists; the gap is a **user-facing, machine-aware cap** and
back-pressure tuning.

## Proposed change

1. Resolve effective transcribe workers as
   `min(transcribe_concurrency, load_profile.parallel, sane_cap_for(ram))` where
   `sane_cap_for` keeps ≥ model-size RAM headroom per worker (large-v3 ≈ 2–3 GB).
2. Surface `transcribe_concurrency` in Settings (1–N) with a warning that >1 is
   for many-core / small-model setups.
3. Keep the bounded queue for back-pressure; ensure per-episode `transcribe_pct`
   meta keys don't collide (already per-guid).
4. Bench on Apple Silicon (turbo vs medium) before raising the default.

## Skeleton (shipped)

The setting exists and defaults to 1, so behaviour is unchanged and safe. Wiring
`transcribe_concurrency` into the worker's `n_tr` (clamped) is the first
follow-up step.

## Follow-up checklist

- [ ] Clamp `n_tr` by `transcribe_concurrency` + a RAM-aware cap.
- [ ] Settings spinbox + guidance copy.
- [ ] Benchmarks per model/machine class; pick a safe default.
- [ ] Tests: claim/queue invariants hold with >1 worker (no double-processing).
