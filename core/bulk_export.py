"""Bulk export of selected transcripts (roadmap 4.1).

Export a list of transcript items (``{"title", "text"}``) to a single file in
Markdown, JSON, HTML, or PDF. Markdown / JSON / HTML are always available; PDF is
best-effort via ``fpdf2`` (listed in requirements) and raises a clear error if
the optional dependency isn't installed.
"""

from __future__ import annotations

import html as _html
import json
import re
from pathlib import Path

# Confidence markers (``==word==``, 1.3) → <mark> in HTML output.
_HIGHLIGHT_RE = re.compile(r"==(.+?)==", re.DOTALL)


class BulkExportError(RuntimeError):
    pass


def _export_md(items: list[dict], dest: Path) -> None:
    parts = []
    for it in items:
        parts.append(f"# {it.get('title', 'Untitled')}\n\n{it.get('text', '')}\n")
    dest.write_text("\n\n---\n\n".join(parts), encoding="utf-8")


_HTML_STYLE = (
    "body{max-width:42rem;margin:2rem auto;padding:0 1rem;"
    "font:16px/1.6 -apple-system,Helvetica,Arial,sans-serif;color:#1a1a1a;background:#fff}"
    "h1{font-size:1.5rem;margin:2rem 0 .5rem}article+article{border-top:1px solid #ddd}"
    "mark{background:#fff3b0;padding:0 .1em}p{margin:.6rem 0;white-space:pre-wrap}"
    "@media(prefers-color-scheme:dark){body{color:#e6e6e6;background:#1a1a1a}"
    "article+article{border-color:#444}mark{background:#5a4a00;color:#fff}}"
)


def _export_html(items: list[dict], dest: Path) -> None:
    """Render the items as one clean, self-contained HTML document.

    Text is HTML-escaped (then ``==word==`` confidence markers become
    ``<mark>``) and split into <p> paragraphs on blank lines."""
    blocks: list[str] = []
    for it in items:
        title = _html.escape(it.get("title", "Untitled"))
        text = it.get("text", "") or ""
        paras = []
        for para in re.split(r"\n\s*\n", text):
            if not para.strip():
                continue
            esc = _html.escape(para)
            esc = _HIGHLIGHT_RE.sub(r"<mark>\1</mark>", esc)
            paras.append(f"<p>{esc}</p>")
        blocks.append(f"<article>\n<h1>{title}</h1>\n" + "\n".join(paras) + "\n</article>")
    doc = (
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        "<title>Paragraphos transcripts</title>\n"
        f"<style>{_HTML_STYLE}</style>\n</head>\n<body>\n"
        + "\n".join(blocks)
        + "\n</body>\n</html>\n"
    )
    dest.write_text(doc, encoding="utf-8")


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
    """Export ``items`` to ``dest`` in ``md`` | ``json`` | ``html`` | ``pdf``."""
    dest = Path(dest)
    fmt = (fmt or "").lower()
    if fmt in ("md", "markdown"):
        _export_md(items, dest)
    elif fmt == "json":
        _export_json(items, dest)
    elif fmt in ("html", "htm"):
        _export_html(items, dest)
    elif fmt == "pdf":
        _export_pdf(items, dest)
    else:
        raise BulkExportError(f"unsupported export format: {fmt!r} (use md, json, html, or pdf)")
    return dest
