"""Design tokens — LIGHT + DARK dicts keyed by name.

Single source of truth for every themeable color + pill variant the UI
uses. Hex values come straight from the handoff document's token table
(see docs/design-handoff/README.md lines 38–56) and the per-component
dark-mode notes.

Design intent:
- `accent` is mode-locked: ochre in light, Apple-Podcasts purple in dark.
- `ring_track` is opaque in dark because the light-mode rgba value is
  too faint against `#1e1e1e`.
- Pill bg/fg tokens are split per-kind so `Pill.paintEvent`-ish code
  can read from tokens instead of baking variants into stylesheets.
"""

from __future__ import annotations

LIGHT: dict[str, str] = {
    # Accent family — mode-locked ochre
    "accent": "#b47a3a",
    "accent_hover": "#a66d2e",
    "accent_tint": "rgba(180, 122, 58, 0.12)",
    # Surfaces
    "bg": "#fafaf7",
    "surface": "#ffffff",
    "surface_alt": "#f4f2ee",
    # Text
    "ink": "#1a1a1a",
    "ink_2": "#3a3a3a",
    "ink_3": "#777777",
    # Lines
    "line": "#d8d4cb",
    "line_soft": "rgba(0, 0, 0, 0.08)",
    # Semantic
    "danger": "#c24a3d",
    "ok": "#4a8a5a",
    "warn": "#b8864a",
    # Progress ring track — rgba is OK on warm off-white bg.
    "ring_track": "rgba(0, 0, 0, 0.08)",
    # Pill variants — bg / fg per kind
    "pill_ok_bg": "rgba(180, 122, 58, 0.12)",
    "pill_ok_fg": "#b47a3a",
    "pill_running_bg": "#b47a3a",
    "pill_running_fg": "#ffffff",
    "pill_fail_bg": "rgba(194, 74, 61, 0.15)",
    "pill_fail_fg": "#c24a3d",
    "pill_pausing_bg": "rgba(184, 134, 74, 0.15)",
    "pill_pausing_fg": "#b8864a",
    "pill_idle_bg": "#f4f2ee",
    "pill_idle_fg": "#777777",
    # Always-dark panels (log viewer, first-run terminal strip). Same in
    # both modes — kept here so consumers still import from one place.
    "terminal_bg": "#1a1a1a",
    "terminal_fg": "#c8c3b4",
    # Tray icon text: near-black on light menu bar.
    "tray_fg": "#1a1a1a",
}


DARK: dict[str, str] = {
    # Accent family — mode-locked purple
    "accent": "#bf5af2",
    "accent_hover": "#cf73f5",
    "accent_tint": "rgba(191, 90, 242, 0.18)",
    # Surfaces
    "bg": "#1e1e1e",
    "surface": "#2a2a2a",
    "surface_alt": "#242424",
    # Text
    "ink": "#ececec",
    "ink_2": "#bfbfbf",
    "ink_3": "#8a8a8a",
    # Lines
    "line": "#3a3a3a",
    "line_soft": "rgba(255, 255, 255, 0.08)",
    # Semantic
    "danger": "#ff6a5a",
    "ok": "#54d97a",
    "warn": "#f0b955",
    # Progress ring track — opaque #3a3a3a, rgba is too faint on #1e1e1e.
    "ring_track": "#3a3a3a",
    # Pill variants. Note running uses accent (purple) at full opacity —
    # handoff lines 143–147 are explicit: the purple is saturated enough
    # to anchor the eye without tinting.
    "pill_ok_bg": "rgba(84, 217, 122, 0.16)",
    "pill_ok_fg": "#54d97a",
    "pill_running_bg": "#bf5af2",
    "pill_running_fg": "#ffffff",
    "pill_fail_bg": "rgba(255, 106, 90, 0.18)",
    "pill_fail_fg": "#ff6a5a",
    "pill_pausing_bg": "rgba(240, 185, 85, 0.18)",
    "pill_pausing_fg": "#f0b955",
    "pill_idle_bg": "#242424",
    "pill_idle_fg": "#8a8a8a",
    # Always-dark panels — same values as light mode.
    "terminal_bg": "#1a1a1a",
    "terminal_fg": "#c8c3b4",
    # Tray icon text: near-white on dark menu bar.
    "tray_fg": "#ececec",
}


def tokens_for(mode: str) -> dict[str, str]:
    """Return the token dict for the given mode ('light' | 'dark')."""
    return DARK if mode == "dark" else LIGHT
