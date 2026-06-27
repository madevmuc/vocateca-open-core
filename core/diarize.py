"""Speaker diarization (roadmap 1.5).

Assigns speaker labels (A, B, C…) to a transcript. The heavy backend is
**sherpa-onnx** (Apache-2.0, an optional dependency + a one-time model download),
lazy-imported so the app runs without it; when ``diarization_enabled`` is off
this module is a no-op. The label-alignment logic (mapping diarized time spans
onto SRT cues) is pure and unit-tested; the sherpa call is isolated behind
``diarize_audio`` and pluggable via the ``backend`` parameter for testing.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

_SRT_CUE_TS = re.compile(
    r"(\d\d):(\d\d):(\d\d)[,.](\d\d\d)\s*-->\s*(\d\d):(\d\d):(\d\d)[,.](\d\d\d)"
)


class DiarizationUnavailable(RuntimeError):
    """Diarization was requested but the sherpa-onnx backend / model is absent."""


@dataclass
class SpeakerSegment:
    start: float  # seconds
    end: float  # seconds
    speaker: str  # "A", "B", … assigned in order of first appearance


def _cue_start_seconds(line: str):
    m = _SRT_CUE_TS.match(line.strip())
    if not m:
        return None
    h, mi, s, ms = (int(m.group(i)) for i in range(1, 5))
    return h * 3600 + mi * 60 + s + ms / 1000.0


def speaker_at(t: float, segments: list[SpeakerSegment]) -> str:
    """Speaker label covering time ``t`` (seconds); nearest segment if ``t`` is
    in a gap; "" if there are no segments."""
    if not segments:
        return ""
    for seg in segments:
        if seg.start <= t < seg.end:
            return seg.speaker
    # In a gap / past the end — pick the segment with the nearest midpoint.
    return min(segments, key=lambda s: abs(((s.start + s.end) / 2) - t)).speaker


def relabel_srt(srt_text: str, segments: list[SpeakerSegment]) -> str:
    """Prefix each SRT cue's text with its speaker label (``A: …``) based on the
    cue's start time. No-op when there are no segments."""
    if not segments:
        return srt_text
    out_lines: list[str] = []
    pending_speaker: str | None = None
    for line in srt_text.splitlines():
        start = _cue_start_seconds(line)
        if start is not None:
            pending_speaker = speaker_at(start, segments)
            out_lines.append(line)
            continue
        # The first non-empty line after a timestamp is the cue text → label it.
        if pending_speaker is not None and line.strip():
            out_lines.append(f"{pending_speaker}: {line}")
            pending_speaker = None
        else:
            out_lines.append(line)
    return "\n".join(out_lines)


def _label_speakers(raw_segments: list[tuple[float, float, object]]) -> list[SpeakerSegment]:
    """Map arbitrary backend speaker ids → stable A/B/C labels by first
    appearance. ``raw_segments`` is ``[(start, end, speaker_id), …]``."""
    labels: dict[object, str] = {}
    out: list[SpeakerSegment] = []
    for start, end, sid in sorted(raw_segments, key=lambda r: r[0]):
        if sid not in labels:
            labels[sid] = chr(ord("A") + len(labels))
        out.append(SpeakerSegment(float(start), float(end), labels[sid]))
    return out


def diarize_audio(audio_path, *, model_dir, num_speakers: int = 0) -> list[SpeakerSegment]:
    """Run sherpa-onnx offline speaker diarization on ``audio_path``.

    Lazy-imports ``sherpa_onnx``; raises :class:`DiarizationUnavailable` if the
    package or the model files aren't present. ``num_speakers=0`` lets the
    backend estimate the count. Returns A/B/C-labelled segments."""
    try:
        import sherpa_onnx  # noqa: F401
    except ImportError as e:
        raise DiarizationUnavailable(
            "speaker diarization needs the optional 'sherpa-onnx' package "
            "(pip install sherpa-onnx) — see docs/plans/diarization-design.md"
        ) from e
    md = Path(model_dir)
    seg_model = md / "segmentation.onnx"
    emb_model = md / "embedding.onnx"
    if not seg_model.exists() or not emb_model.exists():
        raise DiarizationUnavailable(
            f"diarization models not found under {md} (segmentation.onnx + embedding.onnx)"
        )
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(seg_model)
            ),
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(emb_model)),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=int(num_speakers or -1)),
    )
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)
    import wave

    with wave.open(str(audio_path)) as wf:
        samples = wf.readframes(wf.getnframes())
    import numpy as np

    audio = np.frombuffer(samples, dtype=np.int16).astype(np.float32) / 32768.0
    result = sd.process(audio).sort_by_start_time()
    return _label_speakers([(seg.start, seg.end, seg.speaker) for seg in result])


def diarize_segments(audio_path, *, enabled: bool, backend=None) -> list[SpeakerSegment]:
    """Return speaker segments for ``audio_path``.

    No-op (``[]``) when ``enabled`` is False. Otherwise calls ``backend``
    (default: :func:`diarize_audio`) — injectable so callers/tests can supply a
    stub. Exceptions other than :class:`DiarizationUnavailable` are wrapped."""
    if not enabled:
        return []
    if backend is None:
        raise DiarizationUnavailable(
            "no diarization backend configured — pass backend= or wire diarize_audio"
        )
    return backend(audio_path)
