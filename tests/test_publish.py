"""Static transcript site + RSS publishing (10.4)."""

from __future__ import annotations

import xml.etree.ElementTree as ET

from core.publish import publish_site

_ITEMS = [
    {"slug": "ep-1", "title": "First Episode", "date": "2026-01-01", "text": "Hello alpha world."},
    {
        "slug": "ep-2",
        "title": "Second Episode",
        "date": "2026-02-01",
        "text": "Goodbye beta world.",
    },
]


def test_generates_index_and_pages(tmp_path):
    out = publish_site(_ITEMS, tmp_path, site_title="My Show")
    assert (out / "index.html").exists()
    index = (out / "index.html").read_text(encoding="utf-8")
    assert "First Episode" in index and "Second Episode" in index
    assert (out / "ep-1.html").exists()
    page = (out / "ep-1.html").read_text(encoding="utf-8")
    assert "Hello alpha world." in page


def test_client_side_search_asset_present(tmp_path):
    out = publish_site(_ITEMS, tmp_path)
    assert (out / "search.js").exists()
    assert (out / "search-index.json").exists()


def test_rss_is_valid(tmp_path):
    out = publish_site(_ITEMS, tmp_path, site_title="My Show")
    rss = out / "rss.xml"
    assert rss.exists()
    root = ET.fromstring(rss.read_text(encoding="utf-8"))
    assert root.tag == "rss"
    titles = [t.text for t in root.iter("title")]
    assert "First Episode" in titles
    items = list(root.iter("item"))
    assert len(items) == 2


def test_html_escaping(tmp_path):
    items = [{"slug": "x", "title": "A & B <tag>", "date": "2026-01-01", "text": "1 < 2 & 3"}]
    out = publish_site(items, tmp_path)
    page = (out / "x.html").read_text(encoding="utf-8")
    assert "<tag>" not in page  # the title's literal tag must be escaped
    assert "&lt;tag&gt;" in page or "&amp;" in page
