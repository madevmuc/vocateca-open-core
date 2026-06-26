"""User-data paths — macOS-conventional location + one-time migration.

Call user_data_dir() from anywhere; the first call migrates legacy data from
scripts/paragraphos/data/ (if found) so the GUI, the wizard, and the CLI
all see the same canonical location.
"""

from __future__ import annotations

import shutil
from pathlib import Path

_MIGRATION_MARKER = ".migrated"
_LEGACY_CANDIDATES = [
    # Relative to this file's source tree (alias-mode dev install)
    Path(__file__).resolve().parent.parent / "data",
    # Previous names of the app (renamed 0.2 → 0.3)
    Path.home() / "Library" / "Application Support" / "Podtext",
    Path.home() / "Library" / "Application Support" / "Podcast Studio",
]
_done = False


def user_data_dir() -> Path:
    global _done
    target = Path.home() / "Library" / "Application Support" / "Paragraphos"
    target.mkdir(parents=True, exist_ok=True)
    if not _done:
        _done = True
        if not (target / _MIGRATION_MARKER).exists():
            _run_migration(target)
    return target


def trash_dir(data_dir: Path | None = None) -> Path:
    """Directory where soft-deleted files (e.g. undone transcript deletes) live.

    Defaults to ``<user_data_dir>/trash``; pass ``data_dir`` to override (tests).
    Created on demand."""
    base = Path(data_dir) if data_dir is not None else user_data_dir()
    t = base / "trash"
    t.mkdir(parents=True, exist_ok=True)
    return t


def _run_migration(target: Path) -> None:
    moved: list[str] = []
    for legacy in _LEGACY_CANDIDATES:
        if not legacy.exists():
            continue
        for name in ("watchlist.yaml", "settings.yaml", "state.sqlite", "state.sqlite-journal"):
            src = legacy / name
            dst = target / name
            if src.exists() and (not dst.exists() or dst.stat().st_size == 0):
                shutil.copy2(src, dst)
                moved.append(f"{legacy.name}/{name}")
    marker = target / _MIGRATION_MARKER
    marker.write_text(
        "Paragraphos data migrated. This file prevents re-migration on startup.\n"
        + ("moved:\n" + "\n".join(moved) if moved else "no legacy data found"),
        encoding="utf-8",
    )


def migrate_from_legacy(legacy_dir: Path) -> list[str]:
    """Back-compat shim — the main migration is now lazy inside user_data_dir()."""
    return []
