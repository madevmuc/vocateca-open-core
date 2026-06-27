from pathlib import Path

from core.opml import parse_opml


def test_parse_opml_returns_shows():
    shows = parse_opml(Path(__file__).parent / "fixtures" / "sample.opml")
    assert len(shows) == 2
    titles = {s["title"] for s in shows}
    assert titles == {"Immocation", "1 A Lage"}
    assert all(s["xmlUrl"].startswith("http") for s in shows)


def test_parse_opml_nested_and_skips_urlless(tmp_path):
    p = tmp_path / "n.opml"
    p.write_text(
        '<opml version="2.0"><body>'
        '<outline text="Show A" xmlUrl="https://a.test/rss"/>'
        '<outline title="Folder">'
        '<outline text="Show B" xmlUrl="https://b.test/feed"/>'
        "</outline>"
        '<outline text="No URL"/>'
        "</body></opml>",
        encoding="utf-8",
    )
    shows = parse_opml(p)
    assert {s["xmlUrl"] for s in shows} == {"https://a.test/rss", "https://b.test/feed"}


def test_parse_opml_blocks_xxe(tmp_path):
    import pytest

    p = tmp_path / "xxe.opml"
    p.write_text(
        '<?xml version="1.0"?>\n'
        '<!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>\n'
        '<opml><body><outline text="&xxe;" xmlUrl="https://x.test/rss"/></body></opml>',
        encoding="utf-8",
    )
    # defusedxml refuses entity-bearing documents.
    with pytest.raises(Exception):
        parse_opml(p)
