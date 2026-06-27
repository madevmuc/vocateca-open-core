# Speaker diarization — design (roadmap 1.5)

- **Date:** 2026-06-27 · **Status:** BUILT (2026-06-27). Real sherpa-onnx backend
  (`diarize_audio`, optional dep, lazy import → `DiarizationUnavailable`), pure
  unit-tested alignment (`speaker_at` / `relabel_srt` / `_label_speakers`), and a
  best-effort flag-gated pipeline hook (`_maybe_diarize`) that relabels the SRT
  with A/B/C speaker tags after transcribe. Settings checkbox + worker wiring +
  `Settings.diarization_model_dir`. Off by default.
- **Remaining follow-up:** model auto-download UX, and 16 kHz-mono WAV
  conversion before the sherpa call (`diarize_audio` reads WAV; podcast audio is
  MP3), plus optional speaker-labelled markdown body (SRT is labelled today).
- **Shipped (original seam):** `core/diarize.py` `diarize_segments(enabled=…)`,
  gated by the `diarization_enabled` setting (default off).

## Why design-only

Local diarization needs a **new dependency** (`sherpa-onnx`, Apache-2.0) **plus a
one-time model download** (~70–200 MB). Per Operating Rule 5, adding a model
download to the default path and validating it overnight isn't safe — so the run
ships the integration seam + this plan.

## Proposed integration

1. **Dependency:** `sherpa-onnx` (Apache-2.0), added as an *optional* extra
   (like `fpdf2`), imported lazily inside `core/diarize.py` only when enabled.
2. **Model:** a segmentation model (e.g. `sherpa-onnx-pyannote-segmentation`) +
   speaker-embedding model, fetched once into `<user_data_dir>/models/diarize/`
   via the existing `core.model_download` pattern (TOFU SHA-256 pin, progress
   surfaced in Settings). Gated behind an explicit user opt-in.
3. **Pipeline:** after a successful transcribe, when `diarization_enabled`, run
   `diarize_segments(audio_path)` → `[SpeakerSegment(start, end, "A"/"B"/…)]`,
   then align segments to the SRT timestamps and prefix each transcript block
   with its speaker label. Store nothing new in SQLite; the labels live in the
   markdown + SRT.
4. **Output:** frontmatter gains `speakers: N`; transcript blocks become
   `**A:** …` / `**B:** …`; SRT cues get a `<v A>` voice tag.
5. **Performance:** diarization is CPU-heavy — run it under the same load
   profile as whisper, and only on shows that opt in (a per-show toggle could
   follow).

## Skeleton contract (shipped)

`diarize_segments(path, *, enabled)`: returns `[]` when disabled (callers leave
the transcript untouched); raises `DiarizationUnavailable` when enabled, so an
opt-in without the backend fails loudly rather than silently doing nothing.

## Follow-up checklist

- [ ] Add `sherpa-onnx` optional dependency + import guard.
- [ ] Model fetch + TOFU pin + Settings download UI.
- [ ] Real `diarize_segments` implementation returning `SpeakerSegment`s.
- [ ] SRT/markdown alignment + speaker labelling in `core/export.py`.
- [ ] Tests with a tiny fixture audio + a stubbed sherpa backend.
