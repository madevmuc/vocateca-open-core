"""Watch-folder post-transcribe actions (Settings → Local sources → "After
transcribing").

Once a watched file's transcript is written, the original dropped file can be
left in place ("keep"), moved into a ``done/`` subfolder of the watch root
("move"), or deleted ("delete"). The original source path is recorded by
``local_source.ingest_file`` as the ``local_path:<guid>`` meta.

All functions are pure/best-effort and safe to call repeatedly: a file already
under ``done/`` is never moved again, and a missing source is a no-op.
"""

from __future__ import annotations

import logging
import shutil
from pathlib import Path

logger = logging.getLogger(__name__)


def done_dir(root) -> Path:
    """The ``done/`` subfolder of the watch root."""
    return Path(root).expanduser() / "done"


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (ValueError, OSError):
        return False


def _unique_dest(dest: Path) -> Path:
    """Return ``dest`` or, if it exists, ``stem_1.suffix`` / ``stem_2`` …"""
    if not dest.exists():
        return dest
    stem, suffix = dest.stem, dest.suffix
    i = 1
    while True:
        cand = dest.with_name(f"{stem}_{i}{suffix}")
        if not cand.exists():
            return cand
        i += 1


def apply_post_action(src, post: str, root) -> Path | None:
    """Apply the post-transcribe action to ``src``.

    - ``move``  → relocate into ``done/`` (collision-safe). Returns the new path.
    - ``delete``→ unlink the source. Returns None.
    - ``keep``/unknown → no-op. Returns None.

    No-op (returns None) when the source is missing or already lives under
    ``done/``. Best-effort: I/O errors are logged, not raised."""
    src = Path(src)
    root = Path(root).expanduser()
    if post not in ("move", "delete"):
        return None
    if not src.exists() or not src.is_file():
        return None
    dd = done_dir(root)
    if _is_under(src, dd):  # already filed away
        return None
    try:
        if post == "delete":
            src.unlink()
            return None
        dd.mkdir(parents=True, exist_ok=True)
        dest = _unique_dest(dd / src.name)
        shutil.move(str(src), str(dest))
        return dest
    except OSError as e:  # pragma: no cover - filesystem failure
        logger.warning("watch post-action %s failed for %s: %s", post, src, e)
        return None


def collect_retroactive(state, slugs, root) -> list[tuple[str, Path]]:
    """Find already-transcribed local sources eligible for a retroactive move.

    Returns ``(guid, source_path)`` for every DONE episode in ``slugs`` whose
    recorded ``local_path`` still exists, sits under ``root``, and isn't already
    in ``done/``."""
    from core.state import EpisodeStatus

    root = Path(root).expanduser()
    dd = done_dir(root)
    out: list[tuple[str, Path]] = []
    for slug in slugs:
        for ep in state.list_by_status(slug, EpisodeStatus.DONE):
            raw = state.get_meta(f"local_path:{ep['guid']}")
            if not raw:
                continue
            p = Path(raw)
            if p.is_file() and _is_under(p, root) and not _is_under(p, dd):
                out.append((ep["guid"], p))
    return out
