"""Crash visibility + bug-report bundle (roadmap 6.4).

* ``install_excepthook`` routes uncaught exceptions to a log callback (the
  activity log / events) so a crash leaves a trace instead of vanishing.
* ``build_bundle`` zips up recent logs, *redacted* settings, recent events, and
  version fingerprints into a single file the user can attach to a bug report.

Redaction strips anything path- or secret-shaped (absolute paths, tokens) so the
bundle is safe to share.
"""

from __future__ import annotations

import json
import platform
import sys
import traceback
import zipfile
from pathlib import Path

# Settings keys whose values are filesystem paths — replaced wholesale.
_PATH_KEYS = {
    "output_root",
    "obsidian_vault_path",
    "knowledge_hub_root",
    "export_root",
    "watch_folder_root",
}
# Substrings marking a key as secret-ish — value replaced.
_SECRET_HINTS = ("token", "secret", "password", "api_key", "key")


def redact_settings(raw: dict) -> dict:
    """Return a copy of ``raw`` with paths + secrets redacted."""
    out: dict = {}
    for k, v in raw.items():
        if k in _PATH_KEYS and v:
            out[k] = "<redacted-path>"
        elif any(h in k.lower() for h in _SECRET_HINTS) and v:
            out[k] = "<redacted>"
        elif isinstance(v, str) and v.startswith("/"):
            out[k] = "<redacted-path>"
        else:
            out[k] = v
    return out


def _versions() -> str:
    lines = [
        f"platform: {platform.platform()}",
        f"python: {platform.python_version()}",
    ]
    try:
        from core.version import VERSION

        lines.append(f"paragraphos: {VERSION}")
    except Exception:
        pass
    return "\n".join(lines) + "\n"


def build_bundle(*, settings, state, dest, log_dir=None) -> Path:
    """Zip redacted settings + recent events + versions + logs into ``dest``."""
    dest = Path(dest)
    try:
        raw = settings.model_dump()
    except Exception:
        raw = dict(getattr(settings, "__dict__", {}))
    redacted = redact_settings(raw)

    try:
        events_rows = state.query_events(limit=500)
    except Exception:
        events_rows = []

    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("bugreport/settings.json", json.dumps(redacted, indent=2, default=str))
        z.writestr("bugreport/events.json", json.dumps(events_rows, indent=2, default=str))
        z.writestr("bugreport/versions.txt", _versions())
        if log_dir is not None:
            ld = Path(log_dir)
            if ld.is_dir():
                for log_file in sorted(ld.glob("*.log")):
                    try:
                        z.write(log_file, f"bugreport/logs/{log_file.name}")
                    except OSError:
                        pass
    return dest


def install_excepthook(log) -> None:
    """Install a ``sys.excepthook`` that routes uncaught exceptions to ``log``
    (a ``Callable[[str], None]``), then defers to the previous hook so the
    traceback still reaches stderr."""
    previous = sys.excepthook

    def _hook(exc_type, exc, tb):
        try:
            summary = "".join(traceback.format_exception_only(exc_type, exc)).strip()
            log(f"Uncaught exception: {summary}")
        except Exception:
            pass
        try:
            previous(exc_type, exc, tb)
        except Exception:
            pass

    sys.excepthook = _hook
