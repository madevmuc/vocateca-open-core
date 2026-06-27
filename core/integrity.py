"""Pre-transcribe integrity checks (roadmap 6.5).

Two cheap guards run just before whisper is invoked:

1. **Model hash** — verify the GGML model file's SHA-256 against the
   Trust-On-First-Use pin (``core.security.verify_model``). A mismatch means the
   model file changed unexpectedly (corruption / tampering / silent upgrade).
2. **Audio non-truncation** — the file must be non-empty and start with a
   recognised audio container magic; a zero-byte or garbage file is a truncated
   download that whisper would only fail on much later with a cryptic message.

Both return a short reason string on failure (for ``FAILED`` status +
``episode.failed``) or ``None`` when the check passes / can't be evaluated.
"""

from __future__ import annotations

from pathlib import Path

MODEL_HASH_MISMATCH = "model-hash-mismatch"
AUDIO_TRUNCATED = "audio-truncated"
AUDIO_MISSING = "audio-missing"


def check_audio_integrity(path) -> str | None:
    """Return a failure reason if the audio file is missing/empty/non-audio."""
    p = Path(path)
    try:
        size = p.stat().st_size
    except OSError:
        return AUDIO_MISSING
    if size == 0:
        return AUDIO_TRUNCATED
    try:
        with open(p, "rb") as f:
            head = f.read(12)
    except OSError:
        return AUDIO_MISSING
    from core.security import looks_like_audio

    if not looks_like_audio(head):
        return AUDIO_TRUNCATED
    return None


def check_model_integrity(model_path, model_name: str) -> str | None:
    """Return a failure reason if the model file's hash mismatches its TOFU pin.

    A first-use model (no pin yet) is pinned and passes. Non-mismatch errors
    (e.g. the model file is missing) are not treated as integrity failures here —
    whisper surfaces those with a clearer message.
    """
    try:
        from core.security import verify_model

        verify_model(Path(model_path), model_name)
    except ValueError:
        return MODEL_HASH_MISMATCH
    except Exception:
        return None
    return None
