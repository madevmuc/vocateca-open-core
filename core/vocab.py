"""Auto-vocabulary prompt builder (roadmap 1.2).

Mine likely proper nouns / domain terms from a show's past transcripts and
offer them as a whisper ``--prompt`` so recurring names spell correctly. Pure,
dependency-free heuristics; cached per show in the state ``meta`` table and
rebuilt only when the show's transcript count changes.
"""

from __future__ import annotations

import re
from collections import Counter

# A small bilingual (DE/EN) stopword set — capitalised sentence openers and
# common nouns we never want as "vocabulary". German nouns are always
# capitalised, so this list is deliberately broad on the German side.
_STOPWORDS = {
    # English
    "the",
    "and",
    "but",
    "however",
    "this",
    "that",
    "these",
    "those",
    "there",
    "then",
    "they",
    "their",
    "what",
    "when",
    "where",
    "while",
    "with",
    "from",
    "your",
    "you",
    "our",
    "его",
    "she",
    "his",
    "her",
    "him",
    "for",
    "not",
    "are",
    "was",
    "were",
    "have",
    "has",
    "had",
    "will",
    "would",
    "could",
    "should",
    "can",
    "may",
    "might",
    "also",
    "some",
    "many",
    "most",
    "more",
    "today",
    "now",
    "here",
    "ok",
    "yes",
    "no",
    "we",
    "i",
    "it",
    "is",
    "of",
    "in",
    "on",
    "to",
    "at",
    "by",
    "as",
    "an",
    "a",
    "once",
    "again",
    "please",
    "about",
    "over",
    "days",
    "mid",
    "sentence",
    # German
    "der",
    "die",
    "das",
    "und",
    "oder",
    "aber",
    "denn",
    "weil",
    "dass",
    "dann",
    "doch",
    "noch",
    "auch",
    "sehr",
    "viel",
    "viele",
    "mehr",
    "hier",
    "heute",
    "jetzt",
    "wir",
    "ihr",
    "sie",
    "ich",
    "ein",
    "eine",
    "einen",
    "einem",
    "eines",
    "mit",
    "von",
    "für",
    "auf",
    "aus",
    "bei",
    "nach",
    "vor",
    "über",
    "unter",
    "zwischen",
    "ist",
    "sind",
    "war",
    "waren",
    "wird",
    "werden",
    "haben",
    "hat",
    "hatte",
    "kann",
    "könnte",
    "soll",
    "sollte",
    "diese",
    "dieser",
    "dieses",
    "was",
    "wenn",
    "wann",
    "wo",
    "während",
}

_WORD_RE = re.compile(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'’-]*")
_SENT_SPLIT = re.compile(r"[.!?\n]+")


def _is_proper(token: str) -> bool:
    """A capitalised word that isn't all-caps noise and isn't a stopword."""
    if len(token) < 2:
        return False
    if token.lower() in _STOPWORDS:
        return False
    return token[0].isupper()


def build_vocab(transcripts: list[str], *, max_chars: int = 200, min_freq: int = 3) -> str:
    """Return a comma-separated vocabulary string mined from ``transcripts``.

    Heuristic: collect capitalised tokens (and adjacent capitalised bigrams)
    that appear at least once **not** at the start of a sentence (so genuine
    proper nouns, not just sentence openers, qualify), drop stopwords, rank by
    frequency (≥ ``min_freq`` non-initial occurrences), and join with ", "
    until ``max_chars``.
    """
    freq: Counter[str] = Counter()
    eligible: set[str] = set()  # tokens seen at least once mid-sentence
    for text in transcripts:
        for sentence in _SENT_SPLIT.split(text):
            words = _WORD_RE.findall(sentence)
            prev_proper: str | None = None
            for idx, w in enumerate(words):
                if not _is_proper(w):
                    prev_proper = None
                    continue
                non_initial = idx > 0
                if non_initial:
                    eligible.add(w)
                    freq[w] += 1
                    # adjacent capitalised bigram (e.g. "New York")
                    if prev_proper is not None:
                        bigram = f"{prev_proper} {w}"
                        eligible.add(bigram)
                        freq[bigram] += 1
                prev_proper = w

    ranked = sorted(
        (t for t in eligible if freq[t] >= min_freq),
        key=lambda t: (-freq[t], t),
    )
    out: list[str] = []
    length = 0
    for term in ranked:
        add = (2 if out else 0) + len(term)
        if length + add > max_chars:
            break
        out.append(term)
        length += add
    return ", ".join(out)


def resolve_whisper_prompt(
    *,
    whisper_prompt: str,
    auto_vocab: bool,
    slug: str,
    state,
    transcript_count: int,
    build,
) -> str:
    """Resolve the effective whisper prompt for a show.

    Precedence: a non-empty manual ``whisper_prompt`` always wins; otherwise,
    when ``auto_vocab`` is on, return a cached/rebuilt vocabulary string; else
    "". The vocab is cached in ``meta["vocab:{slug}"]`` keyed by
    ``meta["vocab_count:{slug}"]`` and rebuilt only when ``transcript_count``
    changes. ``build`` is a zero-arg callable returning the transcript texts.
    """
    if whisper_prompt and whisper_prompt.strip():
        return whisper_prompt
    if not auto_vocab:
        return ""
    cached = state.get_meta(f"vocab:{slug}")
    cached_count = state.get_meta(f"vocab_count:{slug}")
    if cached is not None and cached_count == str(transcript_count):
        return cached
    vocab_str = build_vocab(build())
    state.set_meta(f"vocab:{slug}", vocab_str)
    state.set_meta(f"vocab_count:{slug}", str(transcript_count))
    return vocab_str
