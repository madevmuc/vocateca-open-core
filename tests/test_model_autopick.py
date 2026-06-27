"""GPU/Metal flag + model auto-pick heuristic (8.1)."""

from __future__ import annotations

from core.hw import recommend_model
from core.transcriber import _build_whisper_cmd


def test_recommend_model_by_class():
    # high-end → turbo; mid → medium; low → small/base
    assert recommend_model(cores=10, ram_gb=32) == "large-v3-turbo"
    assert recommend_model(cores=8, ram_gb=16) == "large-v3-turbo"
    assert recommend_model(cores=6, ram_gb=8) == "medium"
    assert recommend_model(cores=4, ram_gb=4) == "small"
    assert recommend_model(cores=2, ram_gb=2) == "base"


def _cmd(**kw):
    base = dict(
        whisper_bin="whisper-cli",
        model_path="m.bin",
        whisper_input="a.wav",
        language="de",
        threads=4,
        stem="out",
        fast_mode=False,
        processors=1,
        whisper_prompt="",
    )
    base.update(kw)
    return _build_whisper_cmd(**base)


def test_metal_enabled_no_disable_flag():
    cmd = _cmd(metal_enabled=True)
    assert "-ng" not in cmd and "--no-gpu" not in cmd


def test_metal_disabled_adds_no_gpu():
    cmd = _cmd(metal_enabled=False)
    assert "-ng" in cmd or "--no-gpu" in cmd
