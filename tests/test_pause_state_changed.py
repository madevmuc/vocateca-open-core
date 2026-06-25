"""_on_pause_state_changed: tray rebuild guard + deliberate ETA suppression.

Not a Qt widget test — patches _rebuild_tray_menu and drives the bound
method against a minimal stand-in self. Locks in: (a) no rebuild before
the first episode_done tick (total==0), (b) when ticked, rebuild is
called once with pausing=True and eta_sec=None (the cached tick ETA is a
whole-queue estimate that would contradict 'pausing').
"""

from __future__ import annotations

import types

import app as app_module


def _fake(last_tick):
    calls = []
    fake = types.SimpleNamespace()
    fake._last_tick = last_tick
    fake._rebuild_tray_menu = lambda **kw: calls.append(kw)
    return fake, calls


def test_no_rebuild_before_first_tick():
    fake, calls = _fake((0, 0, ""))
    app_module.ParagraphosApp._on_pause_state_changed(fake)
    assert calls == []


def test_rebuild_with_pausing_and_no_eta():
    fake, calls = _fake((3, 10, "Show — Ep"))
    app_module.ParagraphosApp._on_pause_state_changed(fake)
    assert len(calls) == 1
    kw = calls[0]
    assert kw["pausing"] is True
    assert kw["eta_sec"] is None
    assert kw["running"] is True
    assert kw["done"] == 3
    assert kw["total"] == 10
    assert kw["current_title"] == "Show — Ep"
