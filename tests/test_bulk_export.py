"""Bulk export of selected transcripts (4.1)."""

from __future__ import annotations

import json

import pytest

from core.bulk_export import BulkExportError, export

_ITEMS = [
    {"title": "Episode One", "text": "Hello world.\nSecond line."},
    {"title": "Episode Two", "text": "Another transcript body."},
]


def test_export_markdown(tmp_path):
    dest = tmp_path / "out.md"
    export(_ITEMS, "md", dest)
    body = dest.read_text(encoding="utf-8")
    assert "Episode One" in body
    assert "Episode Two" in body
    assert "Another transcript body." in body


def test_export_json(tmp_path):
    dest = tmp_path / "out.json"
    export(_ITEMS, "json", dest)
    data = json.loads(dest.read_text(encoding="utf-8"))
    assert [d["title"] for d in data] == ["Episode One", "Episode Two"]


def test_export_unknown_format_raises(tmp_path):
    with pytest.raises(BulkExportError):
        export(_ITEMS, "docx", tmp_path / "x.docx")


def test_export_pdf_produces_or_reports(tmp_path):
    dest = tmp_path / "out.pdf"
    try:
        export(_ITEMS, "pdf", dest)
    except BulkExportError as e:
        # Acceptable: PDF dependency not installed — must be a clear message.
        assert "pdf" in str(e).lower()
    else:
        assert dest.exists() and dest.stat().st_size > 0
