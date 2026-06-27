"""AGENTS.md must steer automated operators to the blessed CLI path."""

from pathlib import Path


def test_agents_doc_points_to_blessed_path():
    root = Path(__file__).resolve().parent.parent
    txt = (root / "AGENTS.md").read_text(encoding="utf-8")
    assert "cli.py add" in txt
    assert "--backlog" in txt
    assert "watchlist.yaml" in txt
    assert "backlog" in txt
