"""Bulk export of selected transcripts (roadmap 4.1).

Export a list of transcript items (``{"title", "text"}``) to a single file in
Markdown, JSON, or PDF. Markdown + JSON are always available; PDF is best-effort
via ``fpdf2`` (listed in requirements) and raises a clear error if the optional
dependency isn't installed.
"""

from __future__ import annotations

import json
from pathlib import Path


class BulkExportError(RuntimeError):
    pass


def _export_md(items: list[dict], dest: Path) -> None:
    parts = []
    for it in items:
        parts.append(f"# {it.get('title', 'Untitled')}\n\n{it.get('text', '')}\n")
    dest.write_text("\n\n---\n\n".join(parts), encoding="utf-8")


def _export_json(items: list[dict], dest: Path) -> None:
    payload = [{"title": it.get("title", ""), "text": it.get("text", "")} for it in items]
    dest.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def _export_pdf(items: list[dict], dest: Path) -> None:
    try:
        from fpdf import FPDF
    except ImportError as e:
        raise BulkExportError(
            "PDF export needs the optional 'fpdf2' package — install it "
            "(pip install fpdf2) or export to Markdown/JSON instead."
        ) from e
    try:
        from fpdf.errors import FPDFException
    except ImportError:  # pragma: no cover - very old fpdf2
        FPDFException = Exception

    pdf = FPDF()
    pdf.set_auto_page_break(auto=True, margin=15)
    try:
        for it in items:
            pdf.add_page()
            # Reset x to the left margin before each block: newer fpdf2 leaves
            # the cursor at the RIGHT margin after multi_cell(0, …), so the next
            # full-width multi_cell would compute ~0 usable width and raise
            # "Not enough horizontal space to render a single character".
            pdf.set_x(pdf.l_margin)
            pdf.set_font("Helvetica", style="B", size=14)
            pdf.multi_cell(0, 8, it.get("title", "Untitled"))
            pdf.set_x(pdf.l_margin)
            pdf.set_font("Helvetica", size=11)
            # latin-1 fallback: core fonts can't encode all of Unicode.
            text = (it.get("text", "") or "").encode("latin-1", "replace").decode("latin-1")
            pdf.multi_cell(0, 6, text)
        pdf.output(str(dest))
    except FPDFException as e:
        # Pathological layout (e.g. an unbreakable token wider than the page) —
        # degrade to a clear error instead of crashing the caller.
        raise BulkExportError(f"PDF export failed to render: {e}") from e


def export(items: list[dict], fmt: str, dest) -> Path:
    """Export ``items`` to ``dest`` in ``md`` | ``json`` | ``pdf``."""
    dest = Path(dest)
    fmt = (fmt or "").lower()
    if fmt in ("md", "markdown"):
        _export_md(items, dest)
    elif fmt == "json":
        _export_json(items, dest)
    elif fmt == "pdf":
        _export_pdf(items, dest)
    else:
        raise BulkExportError(f"unsupported export format: {fmt!r} (use md, json, or pdf)")
    return dest
