"""Finder-reveal command builder (path display affordance)."""

from __future__ import annotations

from pathlib import Path

from core.reveal import reveal_command


def test_directory_opens_the_folder(tmp_path: Path):
    assert reveal_command(tmp_path) == ["open", str(tmp_path)]


def test_file_is_revealed_with_dash_R(tmp_path: Path):
    f = tmp_path / "x.txt"
    f.write_text("hi", encoding="utf-8")
    assert reveal_command(f) == ["open", "-R", str(f)]


def test_nonexistent_path_falls_back_to_nearest_existing_parent(tmp_path: Path):
    missing = tmp_path / "a" / "b" / "c"
    # Nothing under tmp_path/a exists → reveal the nearest existing ancestor.
    assert reveal_command(missing) == ["open", str(tmp_path)]


def test_blank_path_returns_empty(tmp_path: Path):
    assert reveal_command("") == []
    assert reveal_command(None) == []


def test_user_home_is_expanded():
    cmd = reveal_command("~")
    assert cmd[0] == "open"
    assert cmd[-1] == str(Path("~").expanduser())
