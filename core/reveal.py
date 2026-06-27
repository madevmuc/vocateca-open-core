"""Reveal a path in the macOS Finder.

Used by every place in the UI that shows a folder/file path, so the user can
jump straight to it. The command builder is a pure function (tested); the
``reveal_in_finder`` wrapper runs it best-effort.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

logger = logging.getLogger(__name__)


def reveal_command(path) -> list[str]:
    """Build the ``open`` argv that reveals ``path`` in Finder.

    - existing directory → ``open <dir>`` (opens the folder)
    - existing file → ``open -R <file>`` (reveals + selects it in its folder)
    - missing path → ``open <nearest-existing-ancestor>`` so a not-yet-created
      output folder still opens somewhere useful
    - blank/None → ``[]`` (caller should no-op)
    """
    if not path:
        return []
    p = Path(path).expanduser()
    if p.is_dir():
        return ["open", str(p)]
    if p.is_file():
        return ["open", "-R", str(p)]
    # Missing — walk up to the nearest existing ancestor.
    for ancestor in p.parents:
        if ancestor.is_dir():
            return ["open", str(ancestor)]
    return []


def reveal_in_finder(path) -> bool:
    """Reveal ``path`` in Finder. Returns True if a command was launched.

    Best-effort: a failure to spawn ``open`` is logged, never raised."""
    cmd = reveal_command(path)
    if not cmd:
        return False
    try:
        subprocess.Popen(cmd)  # noqa: S603 — fixed argv, user-chosen path
        return True
    except OSError as e:  # pragma: no cover - platform/spawn failure
        logger.warning("reveal_in_finder failed for %s: %s", path, e)
        return False
