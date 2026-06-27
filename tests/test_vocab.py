"""Auto-vocabulary prompt extraction + precedence + cache (1.2)."""

from __future__ import annotations

from core import vocab
from core.state import StateStore


def test_build_vocab_picks_repeated_proper_nouns():
    # "Bitcoin" and "Ethereum" recur mid-sentence; should be picked.
    text = (
        "Today we discuss Bitcoin and Ethereum. "
        "The price of Bitcoin rose while Ethereum fell. "
        "Many traders prefer Bitcoin over Ethereum these days."
    )
    out = vocab.build_vocab([text], min_freq=2)
    assert "Bitcoin" in out
    assert "Ethereum" in out


def test_build_vocab_skips_sentence_initial_only_and_stopwords():
    # "However" only ever starts a sentence → excluded. "The"/"And" stopwords.
    text = (
        "However the market moved. However nothing changed. "
        "However we persisted. And the team agreed. And the plan held."
    )
    out = vocab.build_vocab([text], min_freq=2)
    assert "However" not in out
    assert "The" not in out
    assert "And" not in out


def test_build_vocab_respects_max_chars():
    text = " ".join(
        f"We talked about {name} and {name} again with {name} once more."
        for name in ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf"]
    )
    out = vocab.build_vocab([text], min_freq=2, max_chars=20)
    assert len(out) <= 20


def test_resolve_precedence_manual_wins(tmp_path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    got = vocab.resolve_whisper_prompt(
        whisper_prompt="my manual prompt",
        auto_vocab=True,
        slug="sh",
        state=state,
        transcript_count=5,
        build=lambda: ["Bitcoin Bitcoin Bitcoin mid sentence here please"],
    )
    assert got == "my manual prompt"


def test_resolve_auto_when_no_manual(tmp_path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    got = vocab.resolve_whisper_prompt(
        whisper_prompt="",
        auto_vocab=True,
        slug="sh",
        state=state,
        transcript_count=3,
        build=lambda: ["We mention Bitcoin and Bitcoin and Bitcoin in the middle."],
    )
    assert "Bitcoin" in got


def test_resolve_none_when_auto_off(tmp_path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    got = vocab.resolve_whisper_prompt(
        whisper_prompt="",
        auto_vocab=False,
        slug="sh",
        state=state,
        transcript_count=3,
        build=lambda: ["Bitcoin Bitcoin Bitcoin"],
    )
    assert got == ""


def test_resolve_cache_reused_until_count_changes(tmp_path):
    state = StateStore(tmp_path / "s.sqlite")
    state.init_schema()
    calls = {"n": 0}

    def build():
        calls["n"] += 1
        return ["We talk about Bitcoin Bitcoin Bitcoin mid sentence here ok"]

    a = vocab.resolve_whisper_prompt(
        whisper_prompt="",
        auto_vocab=True,
        slug="sh",
        state=state,
        transcript_count=3,
        build=build,
    )
    b = vocab.resolve_whisper_prompt(
        whisper_prompt="",
        auto_vocab=True,
        slug="sh",
        state=state,
        transcript_count=3,
        build=build,
    )
    assert a == b
    assert calls["n"] == 1  # second call used the cache
    # count changes → rebuild
    vocab.resolve_whisper_prompt(
        whisper_prompt="",
        auto_vocab=True,
        slug="sh",
        state=state,
        transcript_count=4,
        build=build,
    )
    assert calls["n"] == 2
