# Streaming transcription — design (roadmap 8.2)

- **Date:** 2026-06-27 · **Status:** Design only (escape hatch — highest risk)

## Goal

Start transcribing while the audio is still downloading, to cut end-to-end
latency for long episodes.

## Why design-only

whisper.cpp's `whisper-cli` wants a **complete input file** — it isn't a
streaming API. True overlap requires **chunking**: split the incoming audio into
time windows, transcribe each as it completes, then stitch. That introduces
boundary-word errors, timestamp re-basing, and partial-file decoding — a
substantial subsystem that can't be safely validated overnight.

## Proposed approach (chunked pseudo-streaming)

1. **Chunked download → chunked transcribe.** As the downloader writes the
   `.part`, a watcher splits it into N-second WAV windows (via ffmpeg, seeking
   by byte/time offsets once enough is buffered) with a small overlap (~5 s) to
   avoid cutting words.
2. **Per-chunk whisper.** Transcribe each window as it's ready; re-base each
   chunk's timestamps by its window offset.
3. **Stitch.** Concatenate, de-duplicating the overlap region (align on the last
   few words of chunk *i* vs the first of chunk *i+1*).
4. **Fallback.** If chunking/stitching confidence is low, fall back to the
   current whole-file path. Gate the whole thing behind a default-off setting.

## Risks

- Word/sentence boundaries across chunks (mitigated by overlap + alignment).
- Timestamp drift; SRT correctness.
- ffmpeg seek accuracy on a growing `.part` file.
- Net latency win only materialises for long episodes on fast disks.

## Skeleton

No runtime skeleton shipped (a no-op flag would add surface without value). The
seam is the existing `download_phase` → `transcribe_phase` split: a future
`streaming_enabled` setting would route to a `core/streaming.py` chunker between
them. This document is the deliverable for 8.2.

## Follow-up checklist

- [ ] `streaming_enabled` setting (default off).
- [ ] `core/streaming.py`: chunker + per-chunk transcribe + stitch.
- [ ] Overlap-dedup alignment + timestamp re-basing.
- [ ] Whole-file fallback + tests on a multi-chunk fixture.
