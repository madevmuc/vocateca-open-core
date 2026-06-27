"""Edit YouTube show settings in Show Details dialog (Task 4.6).

For YouTube shows the Advanced section exposes editable controls for
language, transcript/caption preference, and skip-Shorts. All three round
trip through ``_save`` -> ``save_watchlist`` (written to ``watchlist.yaml``).
The skip-Shorts toggle is YouTube-only: it is never constructed for podcast
shows, so ``_skip_shorts_toggle`` stays ``None`` and Save leaves
``skip_shorts`` untouched.
"""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PyQt6.QtWidgets import QApplication

from core.models import Settings, Show, Watchlist
from core.state import StateStore
from ui.app_context import AppContext

_app_ref = QApplication.instance() or QApplication([])
_keepalive: list = []


@pytest.fixture
def qapp():
    return _app_ref


def _make_ctx(tmp_path, show: Show) -> AppContext:
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    settings = Settings()
    settings.output_root = str(tmp_path / "out")
    watchlist = Watchlist(shows=[show])
    watchlist.save(data_dir / "watchlist.yaml")
    state = StateStore(data_dir / "state.sqlite")
    state.init_schema()
    return AppContext(
        data_dir=data_dir,
        settings=settings,
        watchlist=watchlist,
        state=state,
        library=None,  # type: ignore[arg-type]
    )


def _make_dialog(show: Show, tmp_path):
    from ui.show_details_dialog import ShowDetailsDialog

    ctx = _make_ctx(tmp_path, show)
    dlg = ShowDetailsDialog(ctx, show.slug)
    _keepalive.append(dlg)
    return dlg


def _select_data(combo, value):
    """Select the combo row whose itemData == value."""
    for i in range(combo.count()):
        if combo.itemData(i) == value:
            combo.setCurrentIndex(i)
            return
    raise AssertionError(f"no combo item with data {value!r}")


def test_youtube_settings_round_trip(qapp, tmp_path):
    """Language, transcript-pref, and skip-Shorts all persist via _save."""
    show = Show(
        slug="ch",
        title="Channel",
        rss="https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdef",
        source="youtube",
        skip_shorts=True,
        youtube_transcript_pref="captions",
        language="de",
    )
    dlg = _make_dialog(show, tmp_path)

    assert dlg._skip_shorts_toggle is not None
    dlg._skip_shorts_toggle.setChecked(False)
    _select_data(dlg.transcript_pref_combo, "whisper")
    _select_data(dlg._language_combo, "en")
    dlg._save()

    # In-memory show is mutated before accept().
    persisted = next(s for s in dlg.ctx.watchlist.shows if s.slug == "ch")
    assert persisted.skip_shorts is False
    assert persisted.youtube_transcript_pref == "whisper"
    assert persisted.language == "en"

    # And it survives a reload from disk.
    reloaded = Watchlist.load(tmp_path / "data" / "watchlist.yaml")
    disk_show = next(s for s in reloaded.shows if s.slug == "ch")
    assert disk_show.skip_shorts is False
    assert disk_show.youtube_transcript_pref == "whisper"
    assert disk_show.language == "en"


def test_skip_shorts_toggle_absent_for_podcast(qapp, tmp_path):
    """Podcast shows never get the YouTube-only toggle; Save is a no-op for it."""
    show = Show(slug="p", title="P", rss="https://feed", source="podcast")
    dlg = _make_dialog(show, tmp_path)
    assert dlg._skip_shorts_toggle is None
    # Save must not crash and must not flip the model's skip_shorts default.
    dlg._save()
    persisted = next(s for s in dlg.ctx.watchlist.shows if s.slug == "p")
    assert persisted.skip_shorts is True


def test_transcript_pref_combo_has_no_auto_captions(qapp, tmp_path):
    """auto-captions is a dead option: the combo must offer exactly the two
    live codes (captions, whisper) and nothing else."""
    show = Show(
        slug="ch",
        title="Channel",
        rss="https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdef",
        source="youtube",
    )
    dlg = _make_dialog(show, tmp_path)
    combo = dlg.transcript_pref_combo
    assert combo is not None
    codes = {combo.itemData(i) for i in range(combo.count())}
    assert codes == {"captions", "whisper"}


def test_skip_shorts_defaults_checked(qapp, tmp_path):
    """Toggle initial state mirrors the show's skip_shorts flag."""
    on = Show(
        slug="on",
        title="On",
        rss="https://ytfeed",
        source="youtube",
        skip_shorts=True,
    )
    dlg_on = _make_dialog(on, tmp_path / "a")
    assert dlg_on._skip_shorts_toggle is not None
    assert dlg_on._skip_shorts_toggle.isChecked() is True

    off = Show(
        slug="off",
        title="Off",
        rss="https://ytfeed",
        source="youtube",
        skip_shorts=False,
    )
    dlg_off = _make_dialog(off, tmp_path / "b")
    assert dlg_off._skip_shorts_toggle is not None
    assert dlg_off._skip_shorts_toggle.isChecked() is False
