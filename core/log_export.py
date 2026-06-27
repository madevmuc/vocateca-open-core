"""Export filtered event-log rows to JSON or CSV (roadmap 7.3).

Rows are the dicts returned by ``StateStore.query_events`` (``id, ts, type,
show_slug, guid, payload``). JSON keeps the nested payload; CSV flattens payload
to a JSON string in one column.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

_CSV_COLUMNS = ["id", "ts", "type", "show_slug", "guid", "payload"]


def export_events(rows: list[dict], fmt: str, dest) -> Path:
    """Write ``rows`` to ``dest`` as ``json`` or ``csv``. Returns the path."""
    dest = Path(dest)
    fmt = (fmt or "").lower()
    if fmt == "json":
        dest.write_text(
            json.dumps(rows, indent=2, ensure_ascii=False, default=str), encoding="utf-8"
        )
    elif fmt == "csv":
        with open(dest, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=_CSV_COLUMNS, extrasaction="ignore")
            writer.writeheader()
            for r in rows:
                row = dict(r)
                if isinstance(row.get("payload"), (dict, list)):
                    row["payload"] = json.dumps(row["payload"], ensure_ascii=False)
                writer.writerow(row)
    else:
        raise ValueError(f"unsupported export format: {fmt!r} (use 'json' or 'csv')")
    return dest
