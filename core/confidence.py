"""Whisper confidence parsing + low-confidence marking (roadmap 1.3).

When ``settings.confidence_marking_enabled`` is on, the transcriber asks
whisper-cli for a token-level JSON (``--output-json-full``). This module parses
that JSON into per-token ``{text, p}`` records, computes a mean confidence, and
renders a body where sub-threshold tokens are wrapped in Obsidian
``==highlight==`` spans so a reader can spot shaky words at a glance.

All parsing is defensive: a malformed/partial JSON yields an empty token list
rather than raising, so confidence marking never breaks a successful transcribe.
"""

from __future__ import annotations

import json
import re

# whisper.cpp emits non-word "special" tokens for timestamps / control, e.g.
# "[_TT_50]", "[_BEG_]", "[_EOT_]". They carry no transcript text — skip them.
_SPECIAL_TOKEN_RE = re.compile(r"^\s*\[_[A-Z]+_?\d*\]\s*$")


def parse_json_full(path) -> list[dict]:
    """Parse a whisper ``--output-json-full`` file into ``[{text, p}, ...]``.

    Returns an empty list on any read/parse error or unexpected shape.
    """
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return []
    tokens: list[dict] = []
    for seg in data.get("transcription", []) or []:
        for tok in seg.get("tokens", []) or []:
            text = tok.get("text", "")
            if not text or _SPECIAL_TOKEN_RE.match(text):
                continue
            try:
                p = float(tok.get("p", 0.0))
            except (TypeError, ValueError):
                p = 0.0
            tokens.append({"text": text, "p": p})
    return tokens


def mean_confidence(tokens: list[dict]) -> float:
    """Mean token probability, or 0.0 for an empty list."""
    if not tokens:
        return 0.0
    return sum(t.get("p", 0.0) for t in tokens) / len(tokens)


def mark_low_confidence(tokens: list[dict], threshold: float) -> str:
    """Reconstruct the transcript text, wrapping sub-threshold tokens in
    Obsidian ``==highlight==`` markers.

    Whisper token ``text`` carries its own leading space; we keep the space
    outside the marker so ``== word ==`` never appears mid-line.
    """
    out: list[str] = []
    for tok in tokens:
        text = tok.get("text", "")
        if not text:
            continue
        if tok.get("p", 1.0) < threshold:
            lead = text[: len(text) - len(text.lstrip())]
            core_text = text.strip()
            if core_text:
                out.append(f"{lead}=={core_text}==")
            else:
                out.append(text)
        else:
            out.append(text)
    return "".join(out).strip()
