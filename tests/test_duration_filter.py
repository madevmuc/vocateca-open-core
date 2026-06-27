"""Per-show duration filters (3.3)."""

from __future__ import annotations

from core.filters import duration_filter_reason, resolve_duration_bounds


def test_inside_range_passes():
    assert duration_filter_reason(1200, 600, 1800) is None


def test_below_min_skipped():
    assert duration_filter_reason(300, 600, 0) == "duration-out-of-range"


def test_above_max_skipped():
    assert duration_filter_reason(3600, 0, 1800) == "duration-out-of-range"


def test_unknown_duration_passes():
    assert duration_filter_reason(None, 600, 1800) is None
    assert duration_filter_reason(0, 600, 1800) is None


def test_zero_bounds_no_limit():
    assert duration_filter_reason(99999, 0, 0) is None


def test_download_phase_skips_out_of_range(tmp_path):
    from core.library import LibraryIndex
    from core.pipeline import PipelineContext, download_phase
    from core.state import EpisodeStatus, StateStore

    s = StateStore(tmp_path / "s.sqlite")
    s.init_schema()
    s.upsert_episode(
        show_slug="sh",
        guid="g1",
        title="Short one",
        pub_date="2026-01-01",
        mp3_url="http://x/a.mp3",
        duration_sec=120,
    )
    ctx = PipelineContext(
        state=s,
        library=LibraryIndex(tmp_path / "out"),
        output_root=tmp_path / "out",
        whisper_prompt="",
        retention_days=7,
        delete_mp3_after=False,
        min_duration_sec=600,
        max_duration_sec=0,
    )
    outcome = download_phase("g1", ctx)
    assert outcome.result is not None
    assert outcome.result.action == "skipped"
    assert "duration-out-of-range" in outcome.result.detail
    assert s.get_episode("g1")["status"] == EpisodeStatus.SKIPPED.value


def test_resolve_bounds_prefers_show_over_settings():
    # show value wins when non-zero; falls back to settings default when 0
    assert resolve_duration_bounds(show_min=600, show_max=0, def_min=120, def_max=2400) == (
        600,
        2400,
    )
    assert resolve_duration_bounds(show_min=0, show_max=0, def_min=120, def_max=2400) == (120, 2400)
    assert resolve_duration_bounds(show_min=0, show_max=900, def_min=0, def_max=0) == (0, 900)
