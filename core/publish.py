"""Static searchable transcript site + RSS export (roadmap 10.4).

``publish_site`` renders a self-contained folder: an ``index.html`` listing all
transcripts with a client-side search box, one HTML page per transcript, a
``search-index.json`` + ``search.js`` for offline full-text filtering, and an
``rss.xml`` feed. No server, no build step — open ``index.html`` or host the
folder anywhere static.
"""

from __future__ import annotations

import html
import json
from pathlib import Path

_SEARCH_JS = """\
async function loadIndex() {
  const res = await fetch('search-index.json');
  return await res.json();
}
let INDEX = [];
loadIndex().then(data => { INDEX = data; });
function runSearch(q) {
  q = (q || '').toLowerCase().trim();
  const ul = document.getElementById('results');
  ul.innerHTML = '';
  for (const item of INDEX) {
    if (!q || item.title.toLowerCase().includes(q) || item.text.toLowerCase().includes(q)) {
      const li = document.createElement('li');
      const a = document.createElement('a');
      a.href = item.slug + '.html';
      a.textContent = item.title + ' (' + item.date + ')';
      li.appendChild(a);
      ul.appendChild(li);
    }
  }
}
document.addEventListener('DOMContentLoaded', () => {
  const box = document.getElementById('q');
  box.addEventListener('input', () => runSearch(box.value));
  runSearch('');
});
"""

_PAGE_TMPL = """\
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title></head>
<body>
<p><a href="index.html">&larr; All transcripts</a></p>
<h1>{title}</h1>
<p><em>{date}</em></p>
<pre style="white-space:pre-wrap;font-family:inherit">{text}</pre>
</body></html>
"""

_INDEX_TMPL = """\
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{site_title}</title></head>
<body>
<h1>{site_title}</h1>
<input id="q" type="search" placeholder="Search transcripts…" style="width:100%;padding:8px">
<ul id="results">{static_list}</ul>
<script src="search.js"></script>
</body></html>
"""


def _rss(items: list[dict], site_title: str) -> str:
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<rss version="2.0"><channel>',
        f"<title>{html.escape(site_title)}</title>",
        "<description>Transcripts</description>",
    ]
    for it in items:
        parts.append("<item>")
        parts.append(f"<title>{html.escape(it.get('title', ''))}</title>")
        parts.append(f"<pubDate>{html.escape(str(it.get('date', '')))}</pubDate>")
        parts.append(f"<guid>{html.escape(it.get('slug', ''))}</guid>")
        parts.append(f"<link>{html.escape(it.get('slug', ''))}.html</link>")
        parts.append("</item>")
    parts.append("</channel></rss>")
    return "\n".join(parts)


def publish_site(
    items: list[dict], dest_dir, *, site_title: str = "Paragraphos Transcripts"
) -> Path:
    """Render a static searchable transcript site + RSS into ``dest_dir``."""
    dest = Path(dest_dir)
    dest.mkdir(parents=True, exist_ok=True)

    for it in items:
        slug = it.get("slug", "untitled")
        page = _PAGE_TMPL.format(
            title=html.escape(it.get("title", "Untitled")),
            date=html.escape(str(it.get("date", ""))),
            text=html.escape(it.get("text", "")),
        )
        (dest / f"{slug}.html").write_text(page, encoding="utf-8")

    static_list = "".join(
        f'<li><a href="{html.escape(it.get("slug", ""))}.html">'
        f"{html.escape(it.get('title', 'Untitled'))} "
        f"({html.escape(str(it.get('date', '')))})</a></li>"
        for it in items
    )
    (dest / "index.html").write_text(
        _INDEX_TMPL.format(site_title=html.escape(site_title), static_list=static_list),
        encoding="utf-8",
    )
    (dest / "search.js").write_text(_SEARCH_JS, encoding="utf-8")
    search_index = [
        {
            "slug": it.get("slug", ""),
            "title": it.get("title", ""),
            "date": str(it.get("date", "")),
            "text": it.get("text", ""),
        }
        for it in items
    ]
    (dest / "search-index.json").write_text(
        json.dumps(search_index, ensure_ascii=False), encoding="utf-8"
    )
    (dest / "rss.xml").write_text(_rss(items, site_title), encoding="utf-8")
    return dest
