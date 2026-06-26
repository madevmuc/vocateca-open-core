"""Tests for the YouTube URL mode in AddShowDialog."""

from __future__ import annotations

import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication

from core.models import Settings

_app_ref = QApplication.instance() or QApplication([])
_keepalive: list = []


def _make_dialog(tmp_path, settings: Settings):
    from ui.add_show_dialog import AddShowDialog
    from ui.app_context import AppContext

    ctx = AppContext.load(tmp_path)
    ctx.settings = settings
    dlg = AddShowDialog(ctx, None)
    _keepalive.append(dlg)
    return dlg


def _yt_mode_present(dlg) -> bool:
    return any(b.property("mode") == "youtube" for b in dlg._mode_buttons.buttons())


def _wait_for_resolve(dlg, timeout_ms: int = 3000) -> None:
    """Pump the event loop until the YouTube resolve thread finishes."""
    import time

    start = time.monotonic()
    while time.monotonic() - start < timeout_ms / 1000.0:
        thread = getattr(dlg, "_yt_resolve_thread", None)
        if thread is None or not thread.isRunning():
            _app_ref.processEvents()
            return
        _app_ref.processEvents()
        time.sleep(0.01)


def _wait_for_enumerate(dlg, timeout_ms: int = 5000) -> None:
    """Pump the event loop until the off-thread channel enumeration finishes.

    ``_add_from_youtube`` is now asynchronous: it starts a worker thread and
    returns, and the save (or "no videos" info dialog) happens later in the
    queued ``done``/``error`` slot. Mirror the robust ``_resolve`` pattern —
    block on the worker (immune to the just-started ``isRunning()==False``
    race) then pump until the queued slot has run (``_yt_enumerating`` clears).
    """
    import time

    t = getattr(dlg, "_yt_enumerate_thread", None)
    if t is not None:
        t.wait(timeout_ms)
    start = time.monotonic()
    while getattr(dlg, "_yt_enumerating", False) and time.monotonic() - start < timeout_ms / 1000.0:
        _app_ref.processEvents()
        time.sleep(0.01)
    _app_ref.processEvents()


def test_youtube_mode_visible_when_setting_on(tmp_path):
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    assert _yt_mode_present(dlg)
    assert hasattr(dlg, "youtube_url_input")


def test_youtube_mode_hidden_when_setting_off(tmp_path):
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=False))
    assert not _yt_mode_present(dlg)


def test_paste_channel_url_triggers_preview_fetch(tmp_path, monkeypatch):
    called = {}
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda cid: (
            called.update(cid=cid),
            {
                "channel_id": cid,
                "title": "Mr Beast",
                "video_count": 700,
                "artwork_url": "",
            },
        )[1],
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/channel/UCabc1234567890123456789")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    assert called.get("cid") == "UCabc1234567890123456789"
    assert dlg._loaded_yt_preview["title"] == "Mr Beast"


def test_handle_url_resolves_then_previews(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr(
        "core.youtube_meta.resolve_handle_to_channel_id",
        lambda h: "UCabc1234567890123456789",
    )
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda cid: (
            seen.update(cid=cid),
            {"channel_id": cid, "title": "T", "video_count": 1, "artwork_url": ""},
        )[1],
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/@somehandle")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    assert seen.get("cid") == "UCabc1234567890123456789"


def test_channel_url_routes_through_resolver(tmp_path, monkeypatch):
    """A /c/ or /user/ URL (kind "channel_url") must resolve via
    resolve_channel_url_to_id, not be mistaken for a literal channel id."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr(
        "core.youtube_meta.resolve_channel_url_to_id",
        lambda u: "UCabc1234567890123456789",
    )
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda cid: (
            seen.update(cid=cid),
            {"channel_id": cid, "title": "Veritasium", "video_count": 1, "artwork_url": ""},
        )[1],
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/c/Veritasium")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    assert seen.get("cid") == "UCabc1234567890123456789"
    assert dlg._loaded_yt_preview["title"] == "Veritasium"


def test_add_yt_channel_persists_show(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    cid = "UCabc1234567890123456789"
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda c: {
            "channel_id": cid,
            "title": "Mr Beast",
            "video_count": 700,
            "artwork_url": "https://example.com/cover.jpg",
        },
    )
    monkeypatch.setattr(
        "core.youtube_meta.enumerate_channel_videos",
        lambda c, *, limit=None, date_after=None, include_shorts=False, full=False: _vids(1),
    )
    # The worker also builds the RSS feed window; mock it (1 dated video).
    monkeypatch.setattr(
        "core.rss.build_manifest",
        lambda url, **kw: [
            {
                "guid": "v00",
                "title": "Ep 0",
                "pubDate": "2026-06-01",
                "mp3_url": "https://www.youtube.com/watch?v=v00",
                "description": "",
            }
        ],
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText(f"https://www.youtube.com/channel/{cid}")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    # Bypass the modal accept() — call _do_save directly via the YT add path.
    # Enumeration is off-thread now, so wait for the queued save to land.
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    shows = dlg.updated_watchlist.shows
    assert any(s.source == "youtube" and s.slug == "mr-beast" for s in shows)
    yt = next(s for s in shows if s.source == "youtube")
    assert yt.rss == f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
    assert yt.artwork_url == "https://example.com/cover.jpg"


def test_resolve_thread_emits_step_signals(tmp_path, monkeypatch):
    """The resolve thread must emit at least one `step` signal for the UI."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr(
        "core.youtube_meta.resolve_handle_to_channel_id",
        lambda h: "UCabc1234567890123456789",
    )
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda cid: {"channel_id": cid, "title": "T", "video_count": 1, "artwork_url": ""},
    )
    # Wrap the thread class so we can attach our spy BEFORE start() is called.
    import ui.add_show_dialog as mod

    real_cls = mod._YoutubeResolveThread
    steps: list = []

    class _Spy(real_cls):  # type: ignore[misc, valid-type]
        def start(self, *a, **kw):  # noqa: D401
            self.step.connect(lambda c, t, lbl: steps.append((c, t, lbl)))
            return super().start(*a, **kw)

    monkeypatch.setattr(mod, "_YoutubeResolveThread", _Spy)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/@somehandle")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    # Handle path emits two step signals (resolve + preview).
    assert len(steps) >= 1
    assert hasattr(dlg, "yt_progress")


def test_install_gate_when_ytdlp_missing(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: False)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    # The install button is shown; resolve is gated.
    assert not dlg._yt_install_btn.isHidden()
    assert not dlg.youtube_url_input.isEnabled()


# --------------------------------------------------------------------------- #
# Reworked YouTube page: slug field, captions toggle, backfill semantics       #
# --------------------------------------------------------------------------- #

_CID = "UCabc1234567890123456789"


def _window(videos):
    """Shape a list of yt-dlp video dicts like ``core.rss.build_manifest`` of a
    YouTube channel feed: guid (bare id) + dated pubDate + watch URL, no
    duration_sec (YouTube Atom feeds carry no duration)."""
    out = []
    for v in videos:
        ud = str(v.get("upload_date") or "")
        pub = f"{ud[:4]}-{ud[4:6]}-{ud[6:8]}" if len(ud) == 8 and ud.isdigit() else ud
        out.append(
            {
                "guid": v["id"],
                "title": v.get("title") or v["id"],
                "pubDate": pub,
                "mp3_url": f"https://www.youtube.com/watch?v={v['id']}",
                "description": "",
                "duration": "00:00:00",
            }
        )
    return out


def _resolve(
    dlg, monkeypatch, title="Mr Beast", artwork="", videos=None, window=None, first_video=""
):
    """Drive a channel URL through resolve and wait for the worker thread.

    The off-thread enumerate worker now ALSO calls ``core.rss.build_manifest``
    for the feed window and merges it with the deep full-extraction enumerate,
    so both seams are mocked here. ``window`` defaults to the same ``videos``
    (total overlap — the common case); pass it explicitly to model a feed
    window that differs from the deep enumeration. The enumerate mock accepts
    the new ``full=`` / ``date_after=`` kwargs so the worker call doesn't
    TypeError."""
    videos = list(videos or [])
    win = _window(videos if window is None else window)
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda c: {
            "channel_id": c,
            "title": title,
            "video_count": len(videos),
            "artwork_url": artwork,
        },
    )

    def _fake_enum(c, *, limit=None, date_after=None, include_shorts=False, full=False):
        return list(videos)

    monkeypatch.setattr("core.youtube_meta.enumerate_channel_videos", _fake_enum)
    monkeypatch.setattr("core.rss.build_manifest", lambda url, **kw: list(win))
    # The first-video date is fetched eagerly on resolve (no real yt-dlp here).
    # Tests exercising the 'since date' default pass first_video="YYYY-MM-DD".
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_first_video_date",
        lambda c: first_video,
    )
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText(f"https://www.youtube.com/channel/{_CID}")
    dlg._on_youtube_url_resolve()
    # Block on the worker thread (immune to the just-started isRunning()==False
    # race), then pump until the queued preview signal is delivered.
    import time

    t = getattr(dlg, "_yt_resolve_thread", None)
    if t is not None:
        t.wait(5000)
    start = time.monotonic()
    while not dlg._loaded_yt_preview and time.monotonic() - start < 5.0:
        _app_ref.processEvents()
        time.sleep(0.01)
    # The eager first-video fetch starts on resolve-done — settle it so the
    # 'since' field reflects its result (or the empty default).
    ft = getattr(dlg, "_yt_first_video_thread", None)
    if ft is not None:
        ft.wait(5000)
    _app_ref.processEvents()


def _vids(n):
    # upload_date drives pubDate; spread across June 2026 so date filters bite.
    return [
        {"id": f"v{i:02d}", "title": f"Ep {i}", "upload_date": f"202606{i + 1:02d}"}
        for i in range(n)
    ]


def _counts(dlg, slug):
    from core.state import EpisodeStatus

    pending = dlg.ctx.state.list_by_status(slug, EpisodeStatus.PENDING)
    done = dlg.ctx.state.list_by_status(slug, EpisodeStatus.DONE)
    return len(pending), len(done)


def test_slug_autofills_from_channel_and_is_editable(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Mr Beast", videos=_vids(1))
    # Defaults to the slugified channel name.
    assert dlg._yt_slug_input.text() == "mr-beast"
    # A hand-edited slug is honoured by the add path.
    dlg._yt_slug_input.setText("beast-custom")
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    assert any(s.slug == "beast-custom" for s in dlg.updated_watchlist.shows)


def test_lang_combo_offers_curated_list_with_auto(tmp_path):
    """The transcript-language combo offers a curated multi-language list
    plus an explicit "auto" option (channel default / detect)."""
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    codes = [dlg._yt_lang_combo.itemData(i) for i in range(dlg._yt_lang_combo.count())]
    assert dlg._yt_lang_combo.count() >= 10
    for expected in ("de", "en", "es", "fr", "auto"):
        assert expected in codes


def test_lang_combo_seeds_from_settings(tmp_path):
    """The combo's initial selection follows Settings.youtube_default_language."""
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True, youtube_default_language="fr"))
    assert dlg._yt_lang_combo.currentData() == "fr"


def test_lang_combo_seeds_auto_from_settings(tmp_path):
    """`youtube_default_language="auto"` selects the auto option."""
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True, youtube_default_language="auto"))
    assert dlg._yt_lang_combo.currentData() == "auto"


def test_youtube_languages_constant_shape():
    """The shared picker list includes auto plus the expected codes."""
    from ui.languages import YOUTUBE_LANGUAGES

    codes = [c for _label, c in YOUTUBE_LANGUAGES]
    assert ("Auto (channel default / detect)", "auto") in YOUTUBE_LANGUAGES
    for expected in ("de", "en", "es", "fr", "it", "auto"):
        assert expected in codes
    assert len(YOUTUBE_LANGUAGES) >= 10


def test_captions_checkbox_sets_transcript_pref(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    # Settings default is "captions" → checkbox starts checked.
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Chan A", videos=_vids(1))
    assert dlg._yt_captions_chk.isChecked()
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    show = next(s for s in dlg.updated_watchlist.shows if s.slug == "chan-a")
    assert show.youtube_transcript_pref == "captions"


def test_captions_unchecked_means_whisper(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Chan B", videos=_vids(1))
    dlg._yt_captions_chk.setChecked(False)
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    show = next(s for s in dlg.updated_watchlist.shows if s.slug == "chan-b")
    assert show.youtube_transcript_pref == "whisper"


def test_only_new_marks_whole_baseline_done(tmp_path, monkeypatch):
    """'Only new' seeds the current videos as a DONE baseline so nothing in
    the back-catalogue transcribes — only future uploads will."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Base", videos=_vids(5))
    # Default radio is "Only new".
    assert dlg._yt_backfill_choice() == "Only new"
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    pending, done = _counts(dlg, "base")
    assert pending == 0
    assert done == 5


def test_last5_keeps_videos_pending(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Keep", videos=_vids(5))
    for b in dlg._yt_backfill_grp.buttons():
        if b.text() == "Last 5":
            b.setChecked(True)
            break
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    pending, _done = _counts(dlg, "keep")
    assert pending == 5


def test_since_date_filters_to_videos_on_or_after_cutoff(tmp_path, monkeypatch):
    from PyQt6.QtCore import QDate

    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    # 5 videos: pubDates 2026-06-01 .. 2026-06-05.
    _resolve(dlg, monkeypatch, title="Since", videos=_vids(5))
    dlg._yt_since_chk.setChecked(True)
    dlg._yt_since_date.setDate(QDate(2026, 6, 3))
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    pending, _done = _counts(dlg, "since")
    # 2026-06-03, -04, -05 stay pending; the two older ones are dropped.
    assert pending == 3


def test_since_date_defaults_to_channel_first_video(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    # This channel's first upload is 2012-05-04; it's fetched EAGERLY on
    # resolve (_resolve waits for that worker), so the field defaults to it.
    _resolve(dlg, monkeypatch, title="Old Chan", videos=_vids(3), first_video="2012-05-04")
    # Defaults to the first video WITHOUT the user enabling the checkbox, and
    # the hint shows the concrete date.
    assert dlg._yt_since_date.date().toString("yyyy-MM-dd") == "2012-05-04"
    assert "2012-05-04" in dlg._yt_since_hint.text()


def test_since_date_empty_first_video_keeps_placeholder(tmp_path, monkeypatch):
    """If the channel's first-video lookup yields nothing, the field keeps its
    placeholder and the hint stays generic (no crash, no bogus date)."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="No Date", videos=_vids(2), first_video="")
    assert "first video" in dlg._yt_since_hint.text()
    assert dlg._yt_first_video_date == ""


def test_initial_mode_youtube_hides_switcher(tmp_path, monkeypatch):
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    from ui.add_show_dialog import AddShowDialog
    from ui.app_context import AppContext

    ctx = AppContext.load(tmp_path)
    ctx.settings = Settings(sources_youtube=True)
    dlg = AddShowDialog(ctx, None, initial_mode="youtube")
    _keepalive.append(dlg)
    assert not dlg._mode_switcher.isVisible()
    assert dlg.windowTitle() == "Add YouTube Channel"
    # The YouTube radio is the active mode.
    active = dlg._mode_buttons.checkedButton()
    assert active is not None and active.property("mode") == "youtube"


# --------------------------------------------------------------------------- #
# Off-thread, cancellable channel enumeration                                  #
# --------------------------------------------------------------------------- #


def _record_information(monkeypatch) -> list:
    """Spy on QMessageBox.information (conftest stubs it to a silent no-op)."""
    from PyQt6.QtWidgets import QMessageBox

    calls: list = []
    monkeypatch.setattr(
        QMessageBox,
        "information",
        staticmethod(lambda *a, **k: (calls.append(a), QMessageBox.StandardButton.Ok)[1]),
        raising=False,
    )
    return calls


def test_enumerate_runs_off_thread_and_seeds(tmp_path, monkeypatch):
    """The Add path runs enumeration on a worker thread and then seeds."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Off Thread", videos=_vids(3))
    # Keep the videos pending so we can count them.
    for b in dlg._yt_backfill_grp.buttons():
        if b.text() == "Last 5":
            b.setChecked(True)
            break
    dlg._add_from_youtube()
    # A real worker thread was used for the enumeration.
    assert dlg._yt_enumerate_thread is not None
    _wait_for_enumerate(dlg)
    pending, _done = _counts(dlg, "off-thread")
    assert pending == 3


def test_enumerate_empty_shows_info_and_does_not_save(tmp_path, monkeypatch):
    """An empty enumeration shows the 'No videos' info and saves nothing."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Empty Chan", videos=[])
    info = _record_information(monkeypatch)
    n_before = len(dlg.updated_watchlist.shows)
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    assert len(dlg.updated_watchlist.shows) == n_before
    assert info  # the "No videos" dialog fired


def test_since_marks_predate_window_done(tmp_path, monkeypatch):
    """'Since <cutoff>' baselines the feed window: pre-cutoff window videos are
    marked done (even when the deep date-filtered enumerate omits them), and
    on/after-cutoff videos stay pending.

    The deep enumerate honours date_after (returns only on/after the cutoff);
    the always-fetched RSS window still carries the pre-cutoff videos, so the
    merged manifest seeds them and the baseline marks them done."""
    from PyQt6.QtCore import QDate

    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    # 5 dated videos 2026-06-01 .. 2026-06-05; window carries all five.
    _resolve(dlg, monkeypatch, title="Since Win", videos=_vids(5))

    # Re-wire the deep enumerate to honour date_after, so the pre-cutoff videos
    # arrive ONLY via the feed window — proving the window is what gets them
    # marked done.
    def _enum_after(c, *, limit=None, date_after=None, include_shorts=False, full=False):
        out = _vids(5)
        if date_after:
            cut = date_after.replace("-", "")
            out = [v for v in out if v["upload_date"] >= cut]
        return out

    monkeypatch.setattr("core.youtube_meta.enumerate_channel_videos", _enum_after)

    dlg._yt_since_chk.setChecked(True)
    dlg._yt_since_date.setDate(QDate(2026, 6, 3))
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    pending, done = _counts(dlg, "since-win")
    # 06-03, -04, -05 pending; the two pre-cutoff (window-only) ones done.
    assert pending == 3
    assert done == 2


def test_last5_seeds_exactly_five_pending_rest_done(tmp_path, monkeypatch):
    """Headline regression for bug 2: 'Last 5' must seed exactly 5 pending and
    the rest done — the feed window (~15) is part of the seeded baseline, so the
    daily feed-poll can't later queue the other ~10 as pending."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    # 15 dated videos — the same set seen by the feed window AND the deep
    # enumerate (total overlap), mirroring a real channel's recent window.
    _resolve(dlg, monkeypatch, title="Last Five", videos=_vids(15))
    for b in dlg._yt_backfill_grp.buttons():
        if b.text() == "Last 5":
            b.setChecked(True)
            break
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    pending, done = _counts(dlg, "last-five")
    assert pending == 5
    assert done == 10


def test_backfill_episodes_have_dates(tmp_path, monkeypatch):
    """Bug 1 fix: seeded episodes carry real pub dates (full extraction +
    dated feed window), not the empty pubDate the flat path produced."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    _resolve(dlg, monkeypatch, title="Dated", videos=_vids(3))
    for b in dlg._yt_backfill_grp.buttons():
        if b.text() == "Last 5":
            b.setChecked(True)
            break
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    # Read the seeded episodes back from state — every one has a non-empty date.
    from core.state import EpisodeStatus

    eps = dlg.ctx.state.list_by_status("dated", EpisodeStatus.PENDING)
    assert eps  # something was seeded
    assert all(e["pub_date"] for e in eps)
    # The exact mocked dates survive (v00 → 2026-06-01).
    v00 = dlg.ctx.state.get_episode("v00")
    assert v00 is not None and v00["pub_date"] == "2026-06-01"


def test_duration_seeded(tmp_path, monkeypatch):
    """A deep-extracted video with a numeric duration seeds duration_sec on the
    episode row (the merge keeps the deep duration over the duration-less feed
    window)."""
    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    vids = [{"id": "v00", "title": "Ep 0", "upload_date": "20260601", "duration": 615}]
    _resolve(dlg, monkeypatch, title="Has Dur", videos=vids)
    # Duration comes from the deep full extraction — pick a deep mode ("Last 5"),
    # not the default "Only new" (which seeds the duration-less RSS window only).
    for b in dlg._yt_backfill_grp.buttons():
        if b.text() == "Last 5":
            b.setChecked(True)
            break
    dlg._add_from_youtube()
    _wait_for_enumerate(dlg)
    ep = dlg.ctx.state.get_episode("v00")
    assert ep is not None
    assert ep["duration_sec"] == 615


# --------------------------------------------------------------------------- #
# Pasting a video URL offers to add its channel                                #
# --------------------------------------------------------------------------- #


def _patch_question(monkeypatch, answer):
    """Patch the modal QMessageBox.question the dialog sees → `answer`.

    The dialog imports ``QMessageBox`` into its own module namespace, but
    ``question`` is a static method on the (shared) class object, so patching
    it on ``ui.add_show_dialog.QMessageBox`` patches the single class the
    dialog actually calls. conftest leaves ``question`` unstubbed on purpose.
    """
    import ui.add_show_dialog as mod

    monkeypatch.setattr(
        mod.QMessageBox,
        "question",
        staticmethod(lambda *a, **k: answer),
        raising=False,
    )


def test_video_url_offers_channel_and_proceeds_on_yes(tmp_path, monkeypatch):
    from PyQt6.QtWidgets import QMessageBox

    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    _patch_question(monkeypatch, QMessageBox.StandardButton.Yes)
    seen = {}
    monkeypatch.setattr(
        "core.youtube_meta.resolve_video_to_channel_id",
        lambda vid: (seen.update(vid=vid), "UCabc1234567890123456789")[1],
    )
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda cid: {
            "channel_id": cid,
            "title": "Rick Astley",
            "video_count": 1,
            "artwork_url": "",
        },
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    # It went video → channel → preview, all off the GUI thread.
    assert seen.get("vid") == "dQw4w9WgXcQ"
    assert dlg._loaded_yt_preview["title"] == "Rick Astley"


def test_video_resolve_is_reentrancy_safe(tmp_path, monkeypatch):
    """Regression: the channel-offer modal steals focus from the URL field,
    re-firing editingFinished → _on_youtube_url_resolve while the modal is up.
    The re-entrancy guard must drop that second entry (no duplicate dialog, no
    second resolve thread clobbering the running one). Without the guard this
    test would recurse until the stack overflows."""
    from PyQt6.QtWidgets import QMessageBox

    import ui.add_show_dialog as mod

    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    monkeypatch.setattr(
        "core.youtube_meta.resolve_video_to_channel_id",
        lambda vid: "UCabc1234567890123456789",
    )
    monkeypatch.setattr(
        "core.youtube_meta.fetch_channel_preview",
        lambda cid: {
            "channel_id": cid,
            "title": "Reentrant",
            "video_count": 1,
            "artwork_url": "",
        },
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    calls = {"n": 0}

    def reentrant_question(*a, **k):
        calls["n"] += 1
        # Simulate the focus-steal re-firing the slot WHILE the modal is open.
        dlg._on_youtube_url_resolve()
        return QMessageBox.StandardButton.Yes

    monkeypatch.setattr(
        mod.QMessageBox, "question", staticmethod(reentrant_question), raising=False
    )

    dlg._on_youtube_url_resolve()
    # The re-entrant call hit the guard and returned → modal shown exactly once.
    assert calls["n"] == 1
    _wait_for_resolve(dlg)
    assert dlg._loaded_yt_preview["title"] == "Reentrant"


def test_video_url_declined_does_not_proceed(tmp_path, monkeypatch):
    from PyQt6.QtWidgets import QMessageBox

    monkeypatch.setattr("core.ytdlp.is_installed", lambda: True)
    _patch_question(monkeypatch, QMessageBox.StandardButton.No)
    # These must never be called when the user declines.
    monkeypatch.setattr(
        "core.youtube_meta.resolve_video_to_channel_id",
        lambda vid: (_ for _ in ()).throw(AssertionError("should not resolve")),
    )
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    dlg._activate_youtube_mode()
    dlg.youtube_url_input.setText("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    dlg._on_youtube_url_resolve()
    _wait_for_resolve(dlg)
    # No preview was loaded and Add stays disabled.
    assert not getattr(dlg, "_loaded_yt_preview", None)
    assert not dlg._yt_add_btn.isEnabled()
    # And the UI is left in a clean (non-error) state.
    assert dlg.yt_status.property("kind") != "fail"


def test_youtube_placeholder_mentions_video_channel_offer(tmp_path):
    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    placeholder = dlg.youtube_url_input.placeholderText().lower()
    assert "channel" in placeholder
    assert "offer" in placeholder


def test_duplicate_channel_rejected_in_gui(tmp_path, monkeypatch):
    """Re-adding the same channel under a different slug must be rejected by
    the channel-id dedup, appending nothing to the watchlist."""
    from PyQt6.QtWidgets import QMessageBox

    from core.models import Show
    from core.youtube import rss_url_for_channel_id

    dlg = _make_dialog(tmp_path, Settings(sources_youtube=True))
    rss = rss_url_for_channel_id(_CID)
    dlg.updated_watchlist.shows.append(
        Show(slug="existing", title="Existing", rss=rss, source="youtube")
    )
    before = len(dlg.updated_watchlist.shows)

    captured: dict = {}
    monkeypatch.setattr(
        QMessageBox,
        "warning",
        staticmethod(lambda *a, **k: (captured.update(args=a), QMessageBox.StandardButton.Ok)[1]),
        raising=False,
    )

    dlg._do_save(
        {
            "source": "youtube",
            "rss": rss,
            "slug": "different",
            "title": "X",
            "manifest": [],
        }
    )

    # No second show for the channel was appended.
    assert len(dlg.updated_watchlist.shows) == before
    # The warning named the existing show.
    assert any("existing" in str(a).lower() for a in captured.get("args", ()))
