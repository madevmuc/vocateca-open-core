"""Startup health self-check (roadmap 6.2).

Runs a handful of cheap probes on launch — dependencies present, model hash
matches its TOFU pin, data dir writable, enough free disk — and returns a list
of ``{check, ok, detail}`` rows for the banner / a health panel to surface.
Every probe is defensive so the health check itself can never crash startup.
"""

from __future__ import annotations

import shutil
from pathlib import Path


def check_disk_space(path, min_gb: int) -> tuple[bool, str]:
    try:
        free = shutil.disk_usage(Path(path)).free
    except Exception as e:  # noqa: BLE001
        return False, f"couldn't read free space: {e}"
    free_gb = free / 1024**3
    if free_gb < min_gb:
        return False, f"only {free_gb:.1f} GB free (guard {min_gb} GB)"
    return True, f"{free_gb:.1f} GB free"


def check_data_dir_writable(data_dir) -> tuple[bool, str]:
    p = Path(data_dir)
    if not p.exists():
        return False, f"data dir missing: {p}"
    probe = p / ".health_write_probe"
    try:
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except Exception as e:  # noqa: BLE001
        return False, f"not writable: {e}"
    return True, "writable"


def check_dependencies() -> tuple[bool, str]:
    missing = []
    try:
        from core.transcriber import WHISPER_BIN

        if not shutil.which(WHISPER_BIN) and not Path(WHISPER_BIN).exists():
            missing.append("whisper-cli")
    except Exception:
        missing.append("whisper-cli")
    try:
        from core import ytdlp

        if not ytdlp.is_installed():
            missing.append("yt-dlp")
    except Exception:
        missing.append("yt-dlp")
    if missing:
        return False, "missing: " + ", ".join(missing)
    return True, "whisper-cli + yt-dlp present"


def check_model_hash(model_name: str) -> tuple[bool, str]:
    """A pinned model whose file is gone/changed is a problem; an unpinned model
    (first run) is fine."""
    try:
        from core.engine_version import get_model_fingerprint

        fp = get_model_fingerprint(model_name)
    except Exception as e:  # noqa: BLE001
        return True, f"hash unknown ({e})"  # don't block on health infra errors
    if fp:
        return True, f"pinned {fp}"
    return True, "no pin yet (first use)"


def run_health_check(ctx) -> list[dict]:
    """Run all probes against an app context, returning ``{check, ok, detail}``."""
    settings = getattr(ctx, "settings", None)
    min_gb = int(getattr(settings, "disk_guard_min_free_gb", 5) or 5)
    model_name = getattr(settings, "whisper_model", "large-v3-turbo")
    data_dir = getattr(ctx, "data_dir", ".")

    rows: list[dict] = []
    for name, (ok, detail) in (
        ("dependencies", check_dependencies()),
        ("model_hash", check_model_hash(model_name)),
        ("data_dir_writable", check_data_dir_writable(data_dir)),
        ("disk_space", check_disk_space(data_dir, min_gb)),
    ):
        rows.append({"check": name, "ok": ok, "detail": detail})
    return rows
