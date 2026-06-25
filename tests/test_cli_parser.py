"""Argparse + helper sanity for the expanded CLI.

Doesn't actually run the commands (those would touch ~/Library state);
just verifies that every subcommand parses with realistic args, that the
list of registered commands hasn't accidentally regressed, and that
``_coerce_value`` handles each scalar type we expose to ``set`` /
``set-setting``.
"""

from __future__ import annotations

import argparse

import pytest

import cli


def _expected_commands() -> set[str]:
    return {
        # existing
        "add",
        "shows",
        "list",
        "check",
        "import-feeds",
        # inspection
        "status",
        "episodes",
        "failed",
        "show",
        "settings",
        "feed-health",
        # queue control
        "pause",
        "resume",
        "stop",
        "clear-queue",
        "priority",
        "run-next",
        "retranscribe",
        "retry-failed",
        # show management
        "enable",
        "disable",
        "remove",
        "set",
        # feed retry
        "retry-feed",
        "retry-all-feeds",
        # settings
        "set-setting",
    }


def _build_parser() -> argparse.ArgumentParser:
    """Reach into cli.main() to grab the configured ArgumentParser without
    actually executing any command. We do this by monkey-patching
    ``parse_args`` to short-circuit before dispatch."""
    captured: dict[str, argparse.ArgumentParser] = {}

    real = argparse.ArgumentParser.parse_args

    def fake_parse_args(self, *a, **kw):
        captured["parser"] = self
        raise SystemExit(0)

    argparse.ArgumentParser.parse_args = fake_parse_args  # type: ignore
    try:
        with pytest.raises(SystemExit):
            cli.main()
    finally:
        argparse.ArgumentParser.parse_args = real  # type: ignore
    return captured["parser"]


def test_all_expected_subcommands_registered():
    parser = _build_parser()
    sub_action = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    registered = set(sub_action.choices.keys())
    missing = _expected_commands() - registered
    assert not missing, f"missing CLI commands: {sorted(missing)}"


@pytest.mark.parametrize(
    "argv",
    [
        ["status", "--json"],
        ["shows", "--json"],
        ["show", "ted", "--json"],
        ["episodes", "ted", "--status", "pending", "--limit", "5", "--json"],
        ["failed", "--show", "ted", "--limit", "10", "--json"],
        ["settings", "--json"],
        ["feed-health", "--show", "ted", "--json"],
        ["pause"],
        ["resume"],
        ["stop"],
        ["clear-queue"],
        ["priority", "abc-123", "50"],
        ["run-next", "abc-123"],
        ["retranscribe", "abc-123"],
        ["retry-failed", "--show", "ted", "--window-hours", "48"],
        ["retry-failed", "--all-time"],
        ["enable", "ted"],
        ["disable", "ted"],
        ["remove", "ted", "-y", "--purge-state"],
        ["set", "ted", "language=en"],
        ["retry-feed", "ted"],
        ["retry-all-feeds"],
        ["set-setting", "parallel_transcribe", "4"],
        ["check", "--show", "ted", "--limit", "3"],
        ["add", "https://example.com/feed.rss", "--backlog", "all"],
        ["import-feeds"],
        ["list", "--json"],
    ],
)
def test_parser_accepts_command(argv, monkeypatch):
    """Every documented invocation pattern parses without arg errors.
    Stops short of dispatch by patching the registered fn with a no-op."""
    parser = _build_parser()
    sub_action = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    # Replace each subparser's stored fn with a sentinel so a stray
    # exception during dispatch isn't mistaken for a parsing error.
    for sp in sub_action.choices.values():
        sp.set_defaults(fn=lambda _ns: 0)

    ns = parser.parse_args(argv)
    assert callable(ns.fn)


@pytest.mark.parametrize(
    "default,raw,expected",
    [
        (True, "false", False),
        (True, "1", True),
        (False, "yes", True),
        (False, "OFF", False),
        (1, "42", 42),
        (1.0, "3.14", 3.14),
        ("", "hello", "hello"),
        ("default", "", ""),
    ],
)
def test_coerce_value_happy_paths(default, raw, expected):
    assert cli._coerce_value(default, raw) == expected


def test_coerce_value_rejects_garbage_for_bool():
    with pytest.raises(ValueError):
        cli._coerce_value(True, "maybe")


def test_show_settable_keys_are_real_show_fields():
    """Catch typos: every key in _SHOW_SETTABLE must exist on the Show
    pydantic model, otherwise `cli.py set` would crash at runtime."""
    from core.models import Show

    show_fields = set(Show.model_fields.keys())
    leftover = set(cli._SHOW_SETTABLE) - show_fields
    assert not leftover, f"_SHOW_SETTABLE keys not on Show: {sorted(leftover)}"


def test_add_requires_backlog():
    parser = _build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["add", "Some Podcast"])  # missing --backlog → error


def test_add_accepts_backlog_and_flags():
    parser = _build_parser()
    ns = parser.parse_args(
        ["add", "http://h/rss", "--backlog", "last:5", "--slug", "x", "--lang", "de", "--yes"]
    )
    assert ns.backlog == "last:5" and ns.slug == "x" and ns.yes is True
