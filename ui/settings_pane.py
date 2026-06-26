"""Settings pane — auto-saves on every change, grouped by theme."""

from __future__ import annotations

from pathlib import Path

from PyQt6.QtCore import QEvent, QObject, Qt, QTime, QTimer
from PyQt6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QComboBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QRadioButton,
    QScrollArea,
    QSizePolicy,
    QSpinBox,
    QTimeEdit,
    QVBoxLayout,
    QWidget,
)


class _NoScrollFilter(QObject):
    """Eat ``QEvent.Wheel`` on the watched widget. Installed on every
    QSpinBox / QComboBox / QSlider in the settings pane so a stray
    scroll over a focused field doesn't silently change the value."""

    def eventFilter(self, _obj, event):  # noqa: N802 — Qt API
        if event.type() == QEvent.Type.Wheel:
            return True  # consumed; don't step the value
        return False


class _FieldContainer(QWidget):
    """Wrapper that propagates heightForWidth from its child layout up
    to QFormLayout so wrapped hint labels don't get clipped by a row
    height sized against the one-line sizeHint."""

    def __init__(self, parent=None):
        super().__init__(parent)
        sp = QSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Minimum)
        sp.setHeightForWidth(True)
        self.setSizePolicy(sp)

    def hasHeightForWidth(self) -> bool:
        return True

    def heightForWidth(self, w: int) -> int:
        lay = self.layout()
        if lay is None:
            return super().heightForWidth(w)
        return lay.heightForWidth(w)


_MODEL_DIR = Path.home() / ".config" / "open-wispr" / "models"

# Sane lower bounds per whisper model (bytes). Anything less than this is
# almost certainly a truncated/partial download — the real files from
# huggingface are all multi-hundred-MB. Numbers are rough lower bounds
# (~half the known ggml-*.bin size), not exact expected sizes.
_MODEL_MIN_BYTES: dict[str, int] = {
    "base": 70 * 1024 * 1024,  # real ~148 MB
    "small": 200 * 1024 * 1024,  # real ~488 MB
    "medium": 700 * 1024 * 1024,  # real ~1.5 GB
    "large-v3": 1_400 * 1024 * 1024,  # real ~3.1 GB
    "large-v3-turbo": 400 * 1024 * 1024,  # real ~809 MB
}
# Floor: below this we flag a partial download regardless of model pick.
_MODEL_FLOOR_BYTES = 100 * 1024 * 1024


def _model_path(name: str) -> Path:
    return _MODEL_DIR / f"ggml-{name}.bin"


def _model_installed(name: str) -> bool:
    return _model_path(name).exists()


def _human_size(n: int) -> str:
    """'1.5 GB', '340 MB', '512 KB'. Whisper models are always MB+, so
    we don't bother with finer granularity than KB."""
    step = 1024.0
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < step or unit == "TB":
            if unit in ("B", "KB"):
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= step
    return f"{n} B"  # unreachable


def _theme_tokens() -> dict:
    """Backwards-compatible shim around `ui.themes.current_tokens()`.

    Kept so in-file call sites don't churn, but the canonical accessor now
    lives on `ui.themes` so every UI module can share one implementation.
    """
    from ui.themes import current_tokens

    return current_tokens()


def _section(title: str) -> QLabel:
    lbl = QLabel(f"<b>{title}</b>")
    tokens = _theme_tokens()
    # Use primary ink so headlines are readable on both light and dark
    # backgrounds (palette(mid) was too close to the window bg in dark
    # mode). Border stays muted to keep the divider subtle.
    lbl.setStyleSheet(
        f"padding:10px 0 4px 0; color:{tokens['ink']}; font-size:13px; "
        f"border-bottom:1px solid {tokens['line']}; margin-top:8px;"
    )
    return lbl


class SettingsPane(QWidget):
    def __init__(self, ctx):
        super().__init__()
        self.ctx = ctx
        self._save_timer = QTimer(self)
        self._save_timer.setSingleShot(True)
        self._save_timer.timeout.connect(self._do_save)

        # Everything below lives inside a scrollable container so the pane
        # works at any window height.
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        outer.addWidget(scroll)

        inner = QWidget()
        inner.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Minimum)
        scroll.setWidget(inner)
        root = QVBoxLayout(inner)

        # ── Sources ────────────────────────────────────────────
        # Which feed types Paragraphos pulls from. At least one must stay
        # on — unchecking both snaps Podcasts back so the app always has
        # something to do on a check pass.
        root.addWidget(_section("Sources"))
        self.podcasts_checkbox = QCheckBox("Podcasts (RSS)")
        self.podcasts_checkbox.setObjectName("sources_podcasts_checkbox")
        self.podcasts_checkbox.setChecked(bool(self.ctx.settings.sources_podcasts))
        self.podcasts_checkbox.toggled.connect(self._on_sources_changed)
        root.addWidget(self.podcasts_checkbox)
        self.youtube_checkbox = QCheckBox("YouTube channels")
        self.youtube_checkbox.setObjectName("sources_youtube_checkbox")
        self.youtube_checkbox.setChecked(bool(self.ctx.settings.sources_youtube))
        self.youtube_checkbox.toggled.connect(self._on_sources_changed)
        root.addWidget(self.youtube_checkbox)
        sources_hint = QLabel(
            "<span style='color: palette(placeholder-text); font-size: 11px;'>"
            "At least one source must stay enabled. Disable a source to skip "
            "its feeds during the next check pass without removing the shows."
            "</span>"
        )
        sources_hint.setWordWrap(True)
        root.addWidget(sources_hint)

        # ── Local sources ──────────────────────────────────────
        # Watch-folder ingest: drop files into a folder and Paragraphos
        # auto-queues them. Top-level subfolders become shows. Knobs: the
        # toggle, the root path, post-transcribe disposition, and the
        # max-duration guard (files longer than this skip to Failed
        # instead of wasting hours on a mis-drop).
        root.addWidget(_section("Local sources"))
        f_local = QFormLayout()

        self.watch_folder_enabled_cb = QCheckBox("Auto-queue files dropped into the folder below")
        self.watch_folder_enabled_cb.setObjectName("watch_folder_enabled_checkbox")
        self.watch_folder_enabled_cb.setChecked(
            bool(getattr(self.ctx.settings, "watch_folder_enabled", False))
        )
        self.watch_folder_enabled_cb.toggled.connect(self._schedule_save)
        self._add_field(
            f_local,
            "Watch folder",
            self.watch_folder_enabled_cb,
            hint="auto-queue files dropped into the folder below",
            hint_kind="info",
        )

        self.watch_folder_root = QLineEdit(
            getattr(self.ctx.settings, "watch_folder_root", "") or ""
        )
        self.watch_folder_root.setObjectName("watch_folder_root_edit")
        self.watch_folder_root.textChanged.connect(self._schedule_save)
        wf_row = QHBoxLayout()
        wf_row.addWidget(self.watch_folder_root)
        wf_pick = QPushButton("Browse…")
        wf_pick.clicked.connect(self._pick_watch_folder)
        wf_row.addWidget(wf_pick)
        self._add_field(
            f_local,
            "Folder path",
            self._row_widget(wf_row),
            hint="top-level subfolders become shows",
            hint_kind="info",
        )

        self.watch_folder_post_combo = QComboBox()
        self.watch_folder_post_combo.setObjectName("watch_folder_post_combo")
        for label, code in (
            ("Keep in place", "keep"),
            ("Move to done/", "move"),
            ("Delete", "delete"),
        ):
            self.watch_folder_post_combo.addItem(label, code)
        _cur_post = getattr(self.ctx.settings, "watch_folder_post", "keep") or "keep"
        for i in range(self.watch_folder_post_combo.count()):
            if self.watch_folder_post_combo.itemData(i) == _cur_post:
                self.watch_folder_post_combo.setCurrentIndex(i)
                break
        self.watch_folder_post_combo.currentIndexChanged.connect(self._schedule_save)
        self._add_field(
            f_local,
            "After transcribing",
            self.watch_folder_post_combo,
            hint="what to do with each file once its transcript is written",
            hint_kind="info",
        )

        self.local_max_duration_hours = QSpinBox()
        self.local_max_duration_hours.setObjectName("local_max_duration_hours_spin")
        self.local_max_duration_hours.setRange(1, 48)
        self.local_max_duration_hours.setSuffix(" h")
        self.local_max_duration_hours.setValue(
            int(getattr(self.ctx.settings, "local_max_duration_hours", 4))
        )
        self.local_max_duration_hours.valueChanged.connect(self._schedule_save)
        self._add_field(
            f_local,
            "Max duration (hours)",
            self.local_max_duration_hours,
            hint="files longer than this go to Failed instead of transcribing",
            hint_kind="info",
        )
        root.addLayout(f_local)

        # ── Library & output ───────────────────────────────────
        root.addWidget(_section("Library & output"))
        f1 = QFormLayout()
        self.output = QLineEdit(self.ctx.settings.output_root)
        self.output.textChanged.connect(self._schedule_save)
        pick_row = QHBoxLayout()
        pick_row.addWidget(self.output)
        pick = QPushButton("Browse…")
        pick.clicked.connect(self._pick_dir)
        pick_row.addWidget(pick)
        self._add_field(
            f1,
            "Output root",
            self._row_widget(pick_row),
            hint="markdown transcripts land here, one folder per show",
            hint_kind="info",
        )

        self.export_root = QLineEdit(self.ctx.settings.export_root)
        self.export_root.textChanged.connect(self._schedule_save)
        exp_row = QHBoxLayout()
        exp_row.addWidget(self.export_root)
        exp_pick = QPushButton("Browse…")
        exp_pick.clicked.connect(self._pick_export)
        exp_row.addWidget(exp_pick)
        self._add_field(f1, "Export ZIP target", self._row_widget(exp_row))

        self.obsidian_path = QLineEdit(self.ctx.settings.obsidian_vault_path)
        self.obsidian_path.textChanged.connect(self._schedule_save)
        self.obsidian_path.textChanged.connect(self._refresh_obsidian_preview)
        self.obsidian_name = QLineEdit(self.ctx.settings.obsidian_vault_name)
        self.obsidian_name.textChanged.connect(self._schedule_save)
        self.obsidian_name.textChanged.connect(self._refresh_obsidian_preview)
        self.output.textChanged.connect(self._refresh_obsidian_preview)

        self.kb_root = QLineEdit(self.ctx.settings.knowledge_hub_root)
        self.kb_root.textChanged.connect(self._schedule_save)
        kb_row = QHBoxLayout()
        kb_row.addWidget(self.kb_root)
        kb_pick = QPushButton("Browse…")
        kb_pick.clicked.connect(self._pick_kb_root)
        kb_row.addWidget(kb_pick)
        kb_hint, kb_kind = self._kb_root_hint(self.kb_root.text())
        self._add_field(
            f1,
            "Knowledge-hub root (optional)",
            self._row_widget(kb_row),
            hint=kb_hint,
            hint_kind=kb_kind,
        )
        root.addLayout(f1)

        # ── Obsidian ───────────────────────────────────────────
        # Vault path, vault name, picker, and a live write-target preview
        # — uses _add_field like the surrounding sections so labels align
        # right and field columns line up across the entire pane.
        root.addWidget(_section("Obsidian"))
        obsidian_form = QFormLayout()
        obs_row = QHBoxLayout()
        obs_row.addWidget(self.obsidian_path)
        _pick = QPushButton("Pick…")
        _pick.clicked.connect(self._pick_obsidian)
        obs_row.addWidget(_pick)
        self._add_field(obsidian_form, "Vault path", self._row_widget(obs_row))
        self._add_field(obsidian_form, "Vault name", self.obsidian_name)
        self.obsidian_preview = QLabel("")
        self.obsidian_preview.setObjectName("obsidian_preview")
        self.obsidian_preview.setStyleSheet("color: palette(placeholder-text); font-size: 11px;")
        self.obsidian_preview.setWordWrap(True)
        self._add_field(obsidian_form, "", self.obsidian_preview)
        root.addLayout(obsidian_form)

        # Populate the preview line once, now that all three source
        # widgets (output / obsidian_path / obsidian_name) exist.
        self._refresh_obsidian_preview()

        # ── Output formats ─────────────────────────────────────
        # Markdown is always saved. SRT is opt-in — it carries per-segment
        # timestamps so you can cite "at 12:34" in your notes. Keeping both
        # default-on preserves behaviour for upgraders.
        root.addWidget(_section("Output formats"))

        md_cb = QCheckBox("Markdown (.md) — always saved")
        md_cb.setObjectName("output_markdown_checkbox")
        md_cb.setChecked(True)
        md_cb.setEnabled(False)
        root.addWidget(md_cb)

        self.save_srt_cb = QCheckBox("SRT subtitles (.srt)")
        self.save_srt_cb.setObjectName("output_srt_checkbox")
        self.save_srt_cb.setChecked(bool(self.ctx.settings.save_srt))
        self.save_srt_cb.toggled.connect(self._schedule_save)
        root.addWidget(self.save_srt_cb)

        formats_hint = QLabel(
            "<span style='color: palette(placeholder-text); font-size: 11px;'>"
            "SRT carries per-segment timestamps. Keep it on if you'd like to "
            'quote passages with an <i>"at 12:34"</i> reference in your notes. '
            "Transcripts (.md) are always saved.</span>"
        )
        formats_hint.setWordWrap(True)
        root.addWidget(formats_hint)

        # ── YouTube ────────────────────────────────────────────
        # Visible only when Sources → YouTube channels is checked. The
        # whole group hides/shows live as the Sources toggle flips.
        self._yt_section = _section("YouTube")
        self._yt_widgets: list[QWidget] = []
        root.addWidget(self._yt_section)
        self._yt_widgets.append(self._yt_section)

        yt_form = QFormLayout()
        self.yt_default_lang_combo = QComboBox()
        self.yt_default_lang_combo.setObjectName("youtube_default_language_combo")
        self.yt_default_lang_combo.addItem("German (de)", userData="de")
        self.yt_default_lang_combo.addItem("English (en)", userData="en")
        _cur_yt_lang = getattr(self.ctx.settings, "youtube_default_language", "de") or "de"
        for i in range(self.yt_default_lang_combo.count()):
            if self.yt_default_lang_combo.itemData(i) == _cur_yt_lang:
                self.yt_default_lang_combo.setCurrentIndex(i)
                break
        self.yt_default_lang_combo.currentIndexChanged.connect(self._schedule_save)
        self._add_field(
            yt_form,
            "Default transcript language",
            self.yt_default_lang_combo,
            hint=(
                "Used when adding a new YouTube channel — pre-fills the show's "
                "language. Caption fetch tries this language first, then English, "
                "then any other manual sub the video has."
            ),
            hint_kind="info",
        )
        # Keep references so the YouTube-source toggle can hide the
        # widgets together. _add_field returns None, so we wrap the form
        # in a container we can show/hide.
        yt_form_holder = QWidget()
        yt_form_holder.setLayout(yt_form)
        root.addWidget(yt_form_holder)
        self._yt_widgets.append(yt_form_holder)
        self._refresh_yt_section_visibility()

        # ── Interface ──────────────────────────────────────────
        # Power-user toggle for the bottom log dock that appears across
        # all pages. The Logs sidebar entry + Ctrl+L shortcut stay
        # available regardless — this is purely about the persistent
        # bottom panel.
        root.addWidget(_section("Interface"))
        self.show_log_dock_cb = QCheckBox("Show log panel at the bottom of every page")
        self.show_log_dock_cb.setObjectName("show_log_dock_checkbox")
        self.show_log_dock_cb.setChecked(bool(getattr(self.ctx.settings, "show_log_dock", False)))
        self.show_log_dock_cb.toggled.connect(self._on_show_log_dock_toggled)
        root.addWidget(self.show_log_dock_cb)
        log_dock_hint = QLabel(
            "<span style='color: palette(placeholder-text); font-size: 11px;'>"
            "Off by default. The Logs entry in the sidebar still works regardless."
            "</span>"
        )
        log_dock_hint.setWordWrap(True)
        root.addWidget(log_dock_hint)

        # ── Schedule & monitoring ──────────────────────────────
        root.addWidget(_section("Schedule & monitoring"))
        f2 = QFormLayout()
        self.time = QTimeEdit(QTime.fromString(self.ctx.settings.daily_check_time, "HH:mm"))
        self.time.timeChanged.connect(self._schedule_save)
        time_row = QHBoxLayout()
        time_row.addWidget(self.time)
        check_now_btn = QPushButton("Check now")
        check_now_btn.setToolTip("Trigger a feed-check + transcribe pass immediately")
        check_now_btn.clicked.connect(self._check_now_from_settings)
        time_row.addWidget(check_now_btn)
        time_row.addStretch()
        self._add_field(
            f2,
            "Daily check time",
            self._row_widget(time_row),
            hint="runs in the background — Mac must be awake",
            hint_kind="info",
        )
        self.catchup = QCheckBox()
        self.catchup.setChecked(self.ctx.settings.catch_up_missed)
        self.catchup.stateChanged.connect(self._schedule_save)
        self._add_field(
            f2,
            "Catch-up missed runs",
            self.catchup,
            hint="recommended — runs immediately on wake if a check was missed",
            hint_kind="good",
        )
        self.update_check = QCheckBox()
        self.update_check.setChecked(self.ctx.settings.update_check_enabled)
        self.update_check.stateChanged.connect(self._schedule_save)
        self._add_field(
            f2,
            "Check for updates",
            self.update_check,
            hint="checks GitHub for new releases on launch and when reopened",
            hint_kind="info",
        )
        self.auto_start = QCheckBox()
        self.auto_start.setChecked(self.ctx.settings.auto_start_queue)
        self.auto_start.stateChanged.connect(self._schedule_save)
        self._add_field(
            f2,
            "Auto-start queue on launch",
            self.auto_start,
            hint="start checking + transcribing automatically when you open Paragraphos",
            hint_kind="good",
        )
        self.auto_start_delay = QSpinBox()
        self.auto_start_delay.setRange(0, 60)
        self.auto_start_delay.setSuffix(" s")
        self.auto_start_delay.setValue(
            int(getattr(self.ctx.settings, "auto_start_delay_seconds", 5))
        )
        self.auto_start_delay.valueChanged.connect(self._schedule_save)
        self._add_field(
            f2,
            "Auto-start delay",
            self.auto_start_delay,
            hint="wait this long after launch before the queue starts (lets the window paint first)",
            hint_kind="info",
        )
        root.addLayout(f2)

        # ── Notifications ──────────────────────────────────────
        root.addWidget(_section("Notifications"))
        f3 = QFormLayout()
        self.notify = QCheckBox()
        self.notify.setChecked(self.ctx.settings.notify_on_success)
        self.notify.stateChanged.connect(self._schedule_save)
        notify_row = QHBoxLayout()
        notify_row.addWidget(self.notify)
        sys_btn = QPushButton("Open macOS Notification settings…")
        sys_btn.clicked.connect(self._open_notification_prefs)
        notify_row.addWidget(sys_btn)
        notify_row.addStretch()
        self._add_field(
            f3,
            "Notify on successful transcription",
            self._row_widget(notify_row),
            hint="if silent: re-enable in macOS → Notifications",
            hint_kind="info",
        )

        self.notify_mode = QComboBox()
        for label, code in (
            ("Per-episode", "per_episode"),
            ("Daily summary (one message per run)", "daily_summary"),
            ("Off", "off"),
        ):
            self.notify_mode.addItem(label, code)
        idx = next(
            (
                i
                for i in range(self.notify_mode.count())
                if self.notify_mode.itemData(i) == self.ctx.settings.notify_mode
            ),
            0,
        )
        self.notify_mode.setCurrentIndex(idx)
        self.notify_mode.currentIndexChanged.connect(self._schedule_save)
        self._add_field(f3, "Notification frequency", self.notify_mode)
        root.addLayout(f3)

        # ── Transcription engine ───────────────────────────────
        root.addWidget(_section("Transcription engine"))
        f4 = QFormLayout()
        model_row = QHBoxLayout()
        self.model = QComboBox()
        for m in ("base", "small", "medium", "large-v3", "large-v3-turbo"):
            self.model.addItem(m)
        self.model.setCurrentText(self.ctx.settings.whisper_model)
        self.model.currentTextChanged.connect(self._on_model_changed)
        model_row.addWidget(self.model)
        self.model_status = QLabel()
        self.model_status.setStyleSheet(f"color: {_theme_tokens()['ink_3']}; font-style: italic;")
        model_row.addWidget(self.model_status, stretch=1)
        self._add_field(
            f4,
            "Whisper model",
            self._row_widget(model_row),
            hint="best accuracy/speed balance on Apple Silicon — recommended",
            hint_kind="good",
        )
        self._update_model_status()

        # Hintergrundlast — named levels; each derives whisper parallelism +
        # threads + macOS scheduling tier (core/load.py). Replaces the old
        # Parallel-workers / Multi-processor-split spinboxes.
        self.load_quiet = QRadioButton("Leise — nimmt nur wenig, bleibt unsichtbar")
        self.load_balanced = QRadioButton(
            "Ausgewogen — nutzt freie Kerne, weicht beim Arbeiten zurück"
        )
        self.load_full = QRadioButton("Volle Leistung — so schnell wie möglich")
        self._load_buttons = {
            "quiet": self.load_quiet,
            "balanced": self.load_balanced,
            "full": self.load_full,
        }
        self._load_group = QButtonGroup(self)
        for lvl, rb in self._load_buttons.items():
            rb.setProperty("level", lvl)
            self._load_group.addButton(rb)
        # Set the initial state BEFORE wiring signals so construction doesn't
        # fire a spurious save (mirrors the other fields in this pane).
        self._load_buttons.get(self.ctx.settings.load_level, self.load_balanced).setChecked(True)
        for rb in self._load_buttons.values():
            rb.toggled.connect(self._on_load_level_changed)

        self.background_priority = QCheckBox("Mit Hintergrund-Priorität laufen (immer)")
        self.background_priority.setChecked(self.ctx.settings.background_priority)
        self.background_priority.stateChanged.connect(self._on_load_level_changed)

        self._load_readout = QLabel()
        self._load_readout.setStyleSheet(f"color: {_theme_tokens()['ink_3']}; font-style: italic;")

        load_box = QVBoxLayout()
        for rb in self._load_buttons.values():
            load_box.addWidget(rb)
        load_box.addWidget(self.background_priority)
        load_box.addWidget(self._load_readout)
        self._add_field(
            f4,
            "Hintergrundlast",
            self._row_widget(load_box),
            hint="Wie sehr darf die Transkription den Mac auslasten? Höhere Stufen "
            "nutzen mehr Kerne; der Rechner bleibt responsiv.",
            hint_kind="info",
        )
        self._repaint_load_readout()  # paint without triggering a save

        self.bw = QSpinBox()
        self.bw.setRange(0, 1000)
        self.bw.setValue(self.ctx.settings.bandwidth_limit_mbps)
        self.bw.valueChanged.connect(self._schedule_save)
        self._add_field(
            f4,
            "Bandwidth limit (Mbps, 0=∞)",
            self.bw,
            hint="0 = unlimited. Try 20 Mbps if shared Wi-Fi starts hitching",
            hint_kind="info",
        )

        self.fast_mode = QCheckBox("Fast mode (less accurate, ~2–3× faster)")
        self.fast_mode.setChecked(self.ctx.settings.whisper_fast_mode)
        self.fast_mode.stateChanged.connect(self._schedule_save)
        self._add_field(f4, "Whisper speed", self.fast_mode)

        # Engine/model drift row — compares the fingerprint of the current
        # whisper-cli + pinned model against the one recorded on the most
        # recent successful transcribe.
        self._drift_row_widget = QWidget()
        drift_row = QHBoxLayout(self._drift_row_widget)
        drift_row.setContentsMargins(0, 0, 0, 0)
        self._drift_label = QLabel("")
        self._drift_label.setWordWrap(True)
        drift_row.addWidget(self._drift_label, stretch=1)
        self._drift_button = QPushButton()
        self._drift_button.setVisible(False)
        self._drift_button.clicked.connect(self._on_retranscribe_all_clicked)
        drift_row.addWidget(self._drift_button)
        self._add_field(f4, "Engine/model drift", self._drift_row_widget)
        self._refresh_drift_row()

        root.addLayout(f4)

        # ── Storage & retention ────────────────────────────────
        root.addWidget(_section("Storage & retention"))
        f5 = QFormLayout()
        self.retention = QSpinBox()
        self.retention.setRange(0, 365)
        self.retention.setValue(self.ctx.settings.mp3_retention_days)
        self.retention.valueChanged.connect(self._schedule_save)
        self._add_field(
            f5,
            "MP3 retention (days)",
            self.retention,
            hint="transcripts are kept forever — only the audio is purged",
            hint_kind="info",
        )
        self.del_mp3 = QCheckBox()
        self.del_mp3.setChecked(self.ctx.settings.delete_mp3_after_transcribe)
        self.del_mp3.stateChanged.connect(self._schedule_save)
        self._add_field(
            f5,
            "Delete MP3 after transcribe",
            self.del_mp3,
            hint="turn on to save ~40 GB/yr if you never re-play audio",
            hint_kind="info",
        )
        self.log_retention = QSpinBox()
        self.log_retention.setRange(1, 365)
        self.log_retention.setValue(self.ctx.settings.log_retention_days)
        self.log_retention.valueChanged.connect(self._schedule_save)
        self._add_field(
            f5,
            "Log retention (days)",
            self.log_retention,
            hint="enough to debug any failed run",
            hint_kind="info",
        )
        root.addLayout(f5)

        # ── Save indicator ─────────────────────────────────────
        self._saved_label = QLabel("")
        self._saved_label.setStyleSheet(f"color: {_theme_tokens()['ok']}; font-size: 11px;")
        root.addWidget(self._saved_label)

        # ── Automation & remote control ────────────────────────
        root.addWidget(_section("Automation & remote control"))
        help_text = QLabel(self._terminal_help_html())
        help_text.setTextFormat(Qt.TextFormat.RichText)
        help_text.setWordWrap(True)
        help_text.setStyleSheet("font-family: Menlo, Monaco, monospace; font-size: 11px;")
        root.addWidget(help_text)

        root.addWidget(
            QLabel(
                "<br><b>Example prompt for an AI agent (Claude Code, Gemini CLI, etc.)</b> — "
                "paste after giving the agent shell access to this directory:"
            )
        )
        agent_prompt = QLabel(self._agent_prompt_html())
        agent_prompt.setTextFormat(Qt.TextFormat.RichText)
        agent_prompt.setWordWrap(True)
        _tk = _theme_tokens()
        agent_prompt.setStyleSheet(
            f"background: {_tk['surface_alt']}; color: {_tk['ink']}; "
            f"padding: 10px; border: 1px solid {_tk['line']}; "
            f"border-radius: 4px; font-family: Menlo, Monaco, monospace; "
            f"font-size: 11px; white-space: pre-wrap;"
        )
        agent_prompt.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        root.addWidget(agent_prompt)

        copy_btn = QPushButton("Copy agent prompt to clipboard")
        # Default QPushButton lacks hover/pressed feedback under our themed
        # QSS. Give it explicit press states so the click registers visually.
        copy_btn.setStyleSheet(
            f"QPushButton {{ background: {_tk['surface']}; color: {_tk['ink']}; "
            f"border: 1px solid {_tk['line']}; border-radius: 5px; padding: 6px 14px; }}"
            f"QPushButton:hover {{ background: {_tk['surface_alt']}; }}"
            f"QPushButton:pressed {{ background: {_tk['accent_tint']}; "
            f"border: 1px solid {_tk['accent']}; }}"
        )
        copy_btn.clicked.connect(lambda: self._copy_agent_prompt_with_feedback(copy_btn))
        root.addWidget(copy_btn)

        # ── Setup guide ────────────────────────────────────────
        # Mirrors the Help → Re-run setup guide… menu entry. Two entry
        # points because users go looking in Settings for "change my
        # transcripts folder / Obsidian wiring" before they think of the
        # menu bar.
        root.addWidget(_section("Setup guide"))
        setup_hint = QLabel(
            "Re-open the guided setup to change the transcripts folder or Obsidian wiring."
        )
        setup_hint.setObjectName("setup_guide_hint")
        setup_hint.setStyleSheet("color: palette(placeholder-text); font-size: 11px;")
        setup_hint.setWordWrap(True)
        root.addWidget(setup_hint)
        self.rerun_setup_btn = QPushButton("Re-run setup guide…")
        self.rerun_setup_btn.setObjectName("rerun_setup_btn")
        self.rerun_setup_btn.clicked.connect(self._on_rerun_setup_clicked)
        root.addWidget(self.rerun_setup_btn, alignment=Qt.AlignmentFlag.AlignLeft)

        root.addStretch()

        # Disable scroll-wheel value edits on every numeric / dropdown
        # widget. The default Qt behaviour is to step the value when the
        # mouse-wheel rolls over a focused QSpinBox / QComboBox / QSlider —
        # users mistakenly bumped settings while scrolling the pane. The
        # widgets stay fully editable (type, click arrows, focus + arrow
        # keys); only wheel-stepping is suppressed.
        from PyQt6.QtWidgets import QAbstractSpinBox as _ASpin
        from PyQt6.QtWidgets import QSlider as _Slider

        self._noscroll_filter = _NoScrollFilter(self)
        for cls in (_ASpin, QComboBox, _Slider):
            for w in self.findChildren(cls):
                w.installEventFilter(self._noscroll_filter)
                # Click-to-focus only — without StrongFocus the wheel
                # event handler in some styles still re-arms after the
                # filter consumes the event. ClickFocus disables the
                # auto-focus-on-hover that was the original trigger.
                w.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def _on_rerun_setup_clicked(self) -> None:
        """Re-open the guided setup dialog. Delegates to the same helper
        as the Help menu entry so the two entry points stay in sync."""
        from ui.menu_bar import rerun_setup

        rerun_setup(self.window())

    # ── actions ───────────────────────────────────────────────

    def _default_picker_dir(self, current: str) -> str:
        """When the user's saved path is empty or missing, start the picker
        at ~/Desktop instead of wherever Qt's last-used happens to be —
        fresh-install disorientation."""
        p = Path(current).expanduser() if current else None
        if p is not None and p.exists():
            return str(p)
        return str(Path.home() / "Desktop")

    def _pick_dir(self):
        start = self._default_picker_dir(self.output.text())
        d = QFileDialog.getExistingDirectory(self, "Pick output root", start)
        if d:
            self.output.setText(d)

    def _pick_kb_root(self):
        start = self._default_picker_dir(self.kb_root.text())
        d = QFileDialog.getExistingDirectory(self, "Pick knowledge-hub root", start)
        if d:
            self.kb_root.setText(d)

    def _pick_watch_folder(self):
        start = self._default_picker_dir(self.watch_folder_root.text())
        d = QFileDialog.getExistingDirectory(self, "Pick watch folder", start)
        if d:
            self.watch_folder_root.setText(d)

    def _pick_obsidian(self):
        start = self._default_picker_dir(self.obsidian_path.text())
        d = QFileDialog.getExistingDirectory(self, "Pick Obsidian vault", start)
        if d:
            self.obsidian_path.setText(d)
            self.obsidian_name.setText(Path(d).name)

    def _refresh_obsidian_preview(self) -> None:
        """Update the 'where transcripts land' preview line under the
        Obsidian group box. Keeps the user anchored when they flip
        between paths / vault names."""
        path = self.output.text() or "<no output folder set>"
        self.obsidian_preview.setText(f"Transcripts will be written to: {path}")

    def _pick_export(self):
        start = self._default_picker_dir(self.export_root.text())
        d = QFileDialog.getExistingDirectory(self, "Pick export root", start)
        if d:
            self.export_root.setText(d)

    def _check_now_from_settings(self) -> None:
        """Kick off a check immediately. Bubbles up through MainWindow to
        ShowsTab.start_check which owns the CheckAllThread."""
        w = self.window()
        shows = getattr(w, "shows_tab", None)
        if shows is None:
            return
        try:
            shows.start_check(force=True)
        except Exception:
            pass

    def _open_notification_prefs(self):
        import subprocess

        subprocess.run(["open", "x-apple.systempreferences:com.apple.preference.notifications"])

    def _copy_agent_prompt(self):
        from PyQt6.QtWidgets import QApplication

        QApplication.clipboard().setText(self._agent_prompt_plain())

    def _copy_agent_prompt_with_feedback(self, btn) -> None:
        """Copy + flash the button label so the user sees the click landed."""
        from PyQt6.QtCore import QTimer

        self._copy_agent_prompt()
        original = btn.text()
        btn.setText("✓ Copied")
        QTimer.singleShot(1400, lambda: btn.setText(original))

    # ── engine/model drift ────────────────────────────────────

    def _current_engine_fingerprint(self) -> dict[str, str]:
        from core.engine_version import current_fingerprint

        return current_fingerprint(self.model.currentText())

    def _last_transcribed_fingerprint(self) -> dict[str, str] | None:
        """Read the stored fingerprint from state.meta, or None if never set
        (clean install / no successful transcribes yet)."""
        import json

        blob = self.ctx.state.get_meta("last_transcribed_version")
        if not blob:
            return None
        try:
            data = json.loads(blob)
            return data if isinstance(data, dict) else None
        except (json.JSONDecodeError, TypeError):
            return None

    def _count_done_transcripts(self) -> int:
        """Count episodes currently in the 'done' state — the pool that
        a drift re-transcribe would re-queue."""
        from core.state import EpisodeStatus

        with self.ctx.state._conn() as c:
            row = c.execute(
                "SELECT COUNT(*) AS n FROM episodes WHERE status = ?",
                (EpisodeStatus.DONE.value,),
            ).fetchone()
            return int(row["n"]) if row else 0

    def _refresh_drift_row(self) -> None:
        """Update the drift hint label + button visibility.

        Gracefully no-ops when whisper-cli isn't installed yet (first-run
        wizard unfinished): we treat that as "no signal", show an info
        line, and hide the action button.
        """
        tokens = _theme_tokens()
        current = self._current_engine_fingerprint()
        last = self._last_transcribed_fingerprint()

        # First-run / no-transcripts-yet → no drift signal to show.
        if last is None:
            self._drift_label.setText(
                "ⓘ No transcripts yet — drift check will activate after the first run."
            )
            self._drift_label.setStyleSheet(
                f"color: {tokens['ink_3']}; font-size: 11px; font-style: italic;"
            )
            self._drift_button.setVisible(False)
            return

        # If whisper-cli isn't currently available, we can't compare — say
        # so rather than falsely claiming "all good" or "drift".
        if "whisper_version" not in current and "whisper_version" in last:
            self._drift_label.setText(
                "ⓘ whisper-cli not detected — install it to enable drift checks."
            )
            self._drift_label.setStyleSheet(
                f"color: {tokens['ink_3']}; font-size: 11px; font-style: italic;"
            )
            self._drift_button.setVisible(False)
            return

        # Compare the triple that matters. Missing keys on either side
        # compare equal only if both are missing.
        keys = ("whisper_version", "whisper_model", "model_sha256")
        drifted = any(current.get(k) != last.get(k) for k in keys)

        if not drifted:
            self._drift_label.setText("✓ Engine + model match last transcribe batch")
            self._drift_label.setStyleSheet(f"color: {tokens['ok']}; font-size: 11px;")
            self._drift_button.setVisible(False)
            return

        n = self._count_done_transcripts()
        self._drift_label.setText(
            f"⚠ Engine or model upgraded since last batch "
            f"(was {last.get('whisper_model', '?')}/"
            f"{(last.get('model_sha256') or '?')[:8]})"
        )
        self._drift_label.setStyleSheet(f"color: {tokens['warn']}; font-size: 11px;")
        self._drift_button.setText(f"Re-transcribe all ({n} transcripts)")
        self._drift_button.setEnabled(n > 0)
        self._drift_button.setVisible(True)

    def _on_retranscribe_all_clicked(self) -> None:
        n = self._count_done_transcripts()
        if n == 0:
            return
        ans = QMessageBox.question(
            self,
            "Re-transcribe all?",
            f"This will reset {n} completed transcripts back to 'pending' and "
            f"bump their priority so they re-run on the next check. "
            f"The existing transcripts will be overwritten. Continue?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if ans != QMessageBox.StandardButton.Yes:
            return
        from core.state import EpisodeStatus

        with self.ctx.state._conn() as c:
            c.execute(
                "UPDATE episodes SET status = ?, priority = 3 WHERE status = ?",
                (EpisodeStatus.PENDING.value, EpisodeStatus.DONE.value),
            )
        # Hide the drift warning until the next successful batch updates
        # state.meta — the user has taken action.
        self._drift_label.setText(
            f"✓ Queued {n} transcripts for re-transcription — they'll run on the next check."
        )
        tokens = _theme_tokens()
        self._drift_label.setStyleSheet(f"color: {tokens['ok']}; font-size: 11px;")
        self._drift_button.setVisible(False)

    def _on_model_changed(self, text: str) -> None:
        self._schedule_save()
        self._update_model_status()
        self._refresh_drift_row()
        if not _model_installed(text):
            self._download_model(text)

    def _update_model_status(self) -> None:
        name = self.model.currentText()
        tokens = _theme_tokens()
        if not _model_installed(name):
            self.model_status.setText("○ not installed — will download on next use")
            self.model_status.setStyleSheet(f"color: {tokens['ink_3']}; font-style: italic;")
            return

        path = _model_path(name)
        try:
            size = path.stat().st_size
        except OSError as e:
            self.model_status.setText(f"⚠ cannot stat model: {e}")
            self.model_status.setStyleSheet(f"color: {tokens['danger']};")
            return

        # Look up pinned TOFU hash + pinned size (if recorded).
        pinned_hash: str | None = None
        pinned_size: int | None = None
        try:
            from core.security import get_pinned_hash, get_pinned_size

            pinned_hash = get_pinned_hash(name)
            pinned_size = get_pinned_size(name)
        except Exception:
            # Pin file missing/corrupt — treat as unpinned, still show size.
            pass

        min_bytes = _MODEL_MIN_BYTES.get(name, _MODEL_FLOOR_BYTES)
        partial = size < min_bytes
        size_drift = pinned_size is not None and size != pinned_size

        size_str = _human_size(size)
        if partial:
            expected = _human_size(min_bytes)
            self.model_status.setText(f"⚠ partial download · {size_str} · expected ≥{expected}")
            self.model_status.setStyleSheet(f"color: {tokens['danger']}; font-style: normal;")
            return
        if size_drift:
            expected = _human_size(pinned_size)
            self.model_status.setText(
                f"⚠ size drift · {size_str} · pinned at {expected} — re-verify"
            )
            self.model_status.setStyleSheet(f"color: {tokens['warn']}; font-style: normal;")
            return

        pin_frag = f" · pinned {pinned_hash[:8]}…" if pinned_hash else " · unpinned"
        self.model_status.setText(f"● installed · {size_str}{pin_frag}")
        self.model_status.setStyleSheet(f"color: {tokens['ok']}; font-style: normal;")

    def _download_model(self, name: str) -> None:
        from core.model_download import download_model_async

        tokens = _theme_tokens()
        self.model_status.setText("⏳ downloading…")
        self.model_status.setStyleSheet(f"color: {tokens['accent']};")

        def on_done(ok: bool, err: str):
            if ok:
                self._update_model_status()
            else:
                tk = _theme_tokens()
                self.model_status.setText(f"✖ {err}")
                self.model_status.setStyleSheet(f"color: {tk['danger']};")

        download_model_async(name, on_done)

    def _on_sources_changed(self) -> None:
        """Enforce ≥1 enabled source. If both got unchecked, snap Podcasts
        back on (signals blocked so we don't recurse) before saving.
        Also flips visibility of the YouTube settings section."""
        p = self.podcasts_checkbox.isChecked()
        y = self.youtube_checkbox.isChecked()
        if not (p or y):
            self.podcasts_checkbox.blockSignals(True)
            self.podcasts_checkbox.setChecked(True)
            self.podcasts_checkbox.blockSignals(False)
        self._refresh_yt_section_visibility()
        self._schedule_save()

    def _refresh_yt_section_visibility(self) -> None:
        """Show / hide the YouTube settings section in lockstep with the
        Sources → YouTube channels checkbox."""
        visible = bool(
            getattr(self, "youtube_checkbox", None) and self.youtube_checkbox.isChecked()
        )
        for w in getattr(self, "_yt_widgets", []):
            w.setVisible(visible)

    def _on_show_log_dock_toggled(self, checked: bool) -> None:
        """Apply the log-dock visibility immediately to the running window
        in addition to persisting the setting on the next debounce tick."""
        win = self.window()
        dock = getattr(win, "log_dock", None)
        if dock is not None:
            dock.setVisible(checked)
        self._schedule_save()

    def _schedule_save(self):
        self._saved_label.setText("…")
        self._save_timer.start(250)

    def _do_save(self):
        s = self.ctx.settings
        s.output_root = self.output.text()
        s.daily_check_time = self.time.time().toString("HH:mm")
        s.catch_up_missed = self.catchup.isChecked()
        s.update_check_enabled = self.update_check.isChecked()
        s.auto_start_queue = self.auto_start.isChecked()
        s.auto_start_delay_seconds = int(self.auto_start_delay.value())
        s.notify_on_success = self.notify.isChecked()
        s.mp3_retention_days = self.retention.value()
        s.delete_mp3_after_transcribe = self.del_mp3.isChecked()
        s.bandwidth_limit_mbps = self.bw.value()
        s.load_level = self._current_load_level()
        s.background_priority = self.background_priority.isChecked()
        s.obsidian_vault_path = self.obsidian_path.text()
        s.obsidian_vault_name = self.obsidian_name.text()
        s.knowledge_hub_root = self.kb_root.text()
        s.export_root = self.export_root.text()
        s.whisper_model = self.model.currentText()
        s.whisper_fast_mode = self.fast_mode.isChecked()
        s.notify_mode = self.notify_mode.currentData() or "per_episode"
        s.log_retention_days = self.log_retention.value()
        s.save_srt = self.save_srt_cb.isChecked()
        s.sources_podcasts = self.podcasts_checkbox.isChecked()
        s.sources_youtube = self.youtube_checkbox.isChecked()
        s.show_log_dock = self.show_log_dock_cb.isChecked()
        s.youtube_default_language = self.yt_default_lang_combo.currentData() or "de"
        s.watch_folder_enabled = self.watch_folder_enabled_cb.isChecked()
        s.watch_folder_root = self.watch_folder_root.text()
        s.watch_folder_post = self.watch_folder_post_combo.currentData() or "keep"
        s.local_max_duration_hours = int(self.local_max_duration_hours.value())
        s.save(self.ctx.data_dir / "settings.yaml")
        from datetime import datetime

        self._saved_label.setText(f"✓ saved at {datetime.now().strftime('%H:%M:%S')}")
        self.ctx.reload_library()

    def refresh(self) -> None:
        s = self.ctx.settings
        self.output.blockSignals(True)
        self.output.setText(s.output_root)
        self.output.blockSignals(False)
        self.time.blockSignals(True)
        self.time.setTime(QTime.fromString(s.daily_check_time, "HH:mm"))
        self.time.blockSignals(False)

    # ── field helper ──────────────────────────────────────────

    def _add_field(self, form, label, widget, hint=None, hint_kind="info"):
        """Add a form row with an optional hint line below."""
        # Apply generous vertical + horizontal spacing + growth policy once
        # per form — idempotent, so re-calling from every row is fine.
        form.setHorizontalSpacing(14)
        form.setVerticalSpacing(12)
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        if hint is None:
            form.addRow(label, widget)
            return
        container = _FieldContainer()
        v = QVBoxLayout(container)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        v.addWidget(widget)
        prefix = "✓ " if hint_kind == "good" else "ⓘ "
        h = QLabel(prefix + hint)
        h.setWordWrap(True)
        # Critical for QFormLayout: report height-for-width so wrapped
        # hints don't get clipped by a row height sized for one line.
        sp = QSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Minimum)
        sp.setHeightForWidth(True)
        h.setSizePolicy(sp)
        # Pull colors from the theme token dict — inline hex was invisible /
        # too dim in dark mode because Qt palette roles don't track our
        # ThemeManager.
        tokens = _theme_tokens()
        if hint_kind == "good":
            h.setStyleSheet(f"color: {tokens['ok']}; font-size: 11px;")
        else:
            h.setStyleSheet(f"color: {tokens['ink_3']}; font-size: 11px; font-style: italic;")
        v.addWidget(h)
        form.addRow(label, container)

    def _row_widget(self, layout) -> QWidget:
        """Wrap an HBox layout in a QWidget so it can be added via _add_field."""
        w = QWidget()
        layout.setContentsMargins(0, 0, 0, 0)
        w.setLayout(layout)
        return w

    def _kb_root_hint(self, path: str):
        """Return (hint, kind) for the knowledge-hub root field."""
        p = (path or "").strip()
        if not p:
            return ("optional — leave blank if you don't use a knowledge hub", "info")
        expanded = Path(p).expanduser()
        if expanded.exists():
            return (f"detected at {expanded}", "good")
        return ("path does not exist — transcripts will not be mirrored there", "info")

    # ── load-management level ─────────────────────────────────

    def _current_load_level(self) -> str:
        """The checked radio's level slug (quiet/balanced/full)."""
        btn = self._load_group.checkedButton()
        return btn.property("level") if btn else "balanced"

    def _repaint_load_readout(self) -> None:
        """Paint the 'Diese Stufe: …' read-out from the current selection.
        No save — safe to call during construction."""
        import os

        from core.hw import detect
        from core.load import describe_profile, resolve_load_profile

        _mem, perf = detect()
        profile = resolve_load_profile(
            self._current_load_level(),
            perf_cores=perf or (os.cpu_count() or 4),
            background_priority=self.background_priority.isChecked(),
        )
        self._load_readout.setText(f"Diese Stufe: {describe_profile(profile)}")

    def _on_load_level_changed(self, *_args) -> None:
        """Signal slot: repaint the read-out, then persist."""
        self._repaint_load_readout()
        self._schedule_save()

    def _terminal_help_html(self) -> str:
        return (
            "<b>Terminal commands</b> (headless — full GUI parity for LLM agent "
            "control). Run from <code>~/dev/paragraphos/</code>:<br>"
            "<code>PYTHONPATH=. .venv/bin/python cli.py &lt;cmd&gt;</code><br><br>"
            "Most inspection commands accept <code>--json</code> for machine-"
            "readable output. The CLI shares state with the GUI via "
            "<code>state.sqlite</code> (WAL); SQLite-backed mutations (priority, "
            "status, queue toggles) are picked up live by the running GUI. "
            "Watchlist edits land on disk immediately but the GUI re-reads them "
            "on next refresh.<br><br>"
            "<b>Inspection</b> (read-only, --json supported):<br>"
            "&nbsp;• <b>status</b> — queue depth, in-flight, by-status counts, "
            "queue_paused flag<br>"
            "&nbsp;• <b>shows</b> — full watchlist with per-show counts + feed "
            "health (alias <code>list</code>)<br>"
            "&nbsp;• <b>show &lt;slug&gt;</b> — full detail for one show<br>"
            "&nbsp;• <b>episodes &lt;slug&gt; [--status X] [--limit N]</b><br>"
            "&nbsp;• <b>failed [--show &lt;slug&gt;] [--limit N]</b> — failed eps + "
            "their error_text<br>"
            "&nbsp;• <b>settings</b> — all settings, with <code>(rec=N)</code> when "
            "current value ≠ hardware recommendation<br>"
            "&nbsp;• <b>feed-health [--show &lt;slug&gt;]</b> — per-show feed health + "
            "backoff state<br><br>"
            "<b>Queue control</b>:<br>"
            "&nbsp;• <b>pause</b> / <b>resume</b> / <b>stop</b> (force-kill whisper-cli "
            "+ yt-dlp + recover in-flight)<br>"
            "&nbsp;• <b>clear-queue</b> — mark every pending episode done<br>"
            "&nbsp;• <b>priority &lt;guid&gt; &lt;N&gt;</b> — set explicit priority<br>"
            "&nbsp;• <b>run-next &lt;guid&gt;</b> — bump to priority=100<br>"
            "&nbsp;• <b>retranscribe &lt;guid&gt;</b> — status=pending + priority=100<br>"
            "&nbsp;• <b>retry-failed [--show X] [--all-time] [--window-hours N]</b> — "
            "re-queue failed eps<br><br>"
            "<b>Show management</b>:<br>"
            "&nbsp;• <b>add &lt;name-or-rss-or-youtube-url&gt; --backlog "
            "&lt;all|recent|last:N|since:YYYY-MM-DD&gt; [--yes]</b> — add a show; "
            "<b>--backlog is required</b> (how much history to transcribe). Never edit "
            "watchlist.yaml directly — the running app overwrites raw file edits.<br>"
            "&nbsp;&nbsp;&nbsp;Any YouTube URL form is auto-detected "
            "(<code>source=youtube</code>): <code>/channel/UC…</code>, "
            "<code>/@handle</code>, <code>/c/Name</code>, <code>/user/Name</code>, a "
            "bare <code>@handle</code>, or a video URL (adds its channel). The same "
            "channel can't be added twice. <code>--backlog</code> drives a <b>deep</b> "
            "channel backfill (the whole archive, not just the RSS window); new "
            "uploads are then picked up from the channel feed on every check. Each "
            "video imports the uploader's own subtitle when present (manual only — "
            "auto-generated captions are never used) and falls back to whisper. "
            "YouTube-only flags: <code>--captions</code>/<code>--whisper</code> "
            "(transcript pref) and <code>--skip-shorts</code>/"
            "<code>--include-shorts</code> (Shorts are excluded by default). Shorts "
            "are marked <code>skipped</code>; live/premiere videos <code>deferred</code> "
            "(re-probed on the next daily check); members-only / age-restricted / "
            "region-locked <code>failed</code> with a specific message. In the GUI, "
            "the Shows tab has a dedicated <b>Add YouTube Channel…</b> button, and "
            "double-clicking any show opens the <b>episode browser</b> — every "
            "episode with status pills, multi-select + Queue selected, Queue all "
            "since a date, status filters, and (for YouTube) the full back-catalogue "
            "streamed in as triggerable <b>available</b> rows.<br>"
            "&nbsp;• <b>backlog &lt;slug&gt; --backlog "
            "&lt;all|recent|last:N|since:YYYY-MM-DD&gt;</b> — deepen an existing "
            "YouTube show's history beyond the RSS window and queue the new videos<br>"
            "&nbsp;• <b>enable &lt;slug&gt;</b> / <b>disable &lt;slug&gt;</b><br>"
            "&nbsp;• <b>remove &lt;slug&gt; [-y] [--purge-state]</b> — drop from "
            "watchlist + mark eps done<br>"
            "&nbsp;• <b>set &lt;slug&gt; key=value</b> — per-show field setter "
            "(language, whisper_prompt, output_override, "
            "youtube_transcript_pref, enabled, source, title, rss, artwork_url)<br>"
            "&nbsp;• <b>import-feeds</b> — bulk-import the curated podcast list<br><br>"
            "<b>Local ingest</b> (files, folders, URLs — synthetic shows; "
            "bypasses RSS/YouTube):<br>"
            "&nbsp;• <b>ingest file &lt;path&gt; [--show SLUG]</b> — one file → "
            "<code>sha256:&lt;hex&gt;</code> GUID<br>"
            "&nbsp;• <b>ingest url &lt;url&gt; [--show SLUG]</b> — yt-dlp generic "
            "extractor → <code>&lt;Extractor&gt;:&lt;id&gt;</code> GUID<br>"
            "&nbsp;• <b>ingest folder &lt;path&gt; [--show SLUG] [--no-recursive]</b>"
            " — batch-queue every supported file<br>"
            "&nbsp;• <b>watch add &lt;path&gt;</b> — enable watch-folder + set "
            "root. Top-level subfolders become show slugs<br>"
            "&nbsp;• <b>watch remove</b> / <b>watch list [--json]</b> — disable "
            "/ inspect the watch-folder config<br><br>"
            "<b>Feed retry</b>:<br>"
            "&nbsp;• <b>retry-feed &lt;slug&gt;</b> — clear backoff + immediate fetch<br>"
            "&nbsp;• <b>retry-all-feeds</b> — same for every feed marked fail<br><br>"
            "<b>Settings</b>:<br>"
            "&nbsp;• <b>set-setting &lt;key&gt; &lt;value&gt;</b> — type-coerced from the "
            "Settings model<br>"
            "&nbsp;• <b>check [--show &lt;slug&gt;] [--limit N]</b> — refresh feeds + "
            "drain queue. YouTube tries captions first (requested lang → en → "
            "any) then falls back to whisper. Works offline: feeds + new "
            "downloads fail fast, but already-downloaded MP3s keep "
            "transcribing.<br><br>"
            "<b>Logs:</b> every launch writes a one-line fingerprint to "
            "<code>~/Library/Application Support/Paragraphos/logs/paragraphos.log</code> "
            "covering version, OS, RAM/cores, whisper-cli + yt-dlp + ffmpeg "
            "versions, and every user-tunable setting (with <code>(rec=N)</code> "
            "hints). Grep that line first for support."
        )

    def _agent_prompt_plain(self) -> str:
        return (
            "You have shell access to the Paragraphos codebase at\n"
            "  ~/dev/paragraphos/\n"
            "\n"
            "Paragraphos is a local audio → whisper.cpp transcription pipeline\n"
            "for podcasts (RSS) AND YouTube channels. Both sources run side-by-\n"
            "side. New YouTube uploads are discovered from the channel feed,\n"
            "then each video is handled individually: an uploader-provided\n"
            "(manual) subtitle in the chosen language is imported straight into\n"
            "the library — auto-generated captions are never used — and any\n"
            "video without one falls back to whisper-cli. yt-dlp is lazy-\n"
            "installed to\n"
            "  ~/Library/Application Support/Paragraphos/bin/yt-dlp\n"
            "on first YouTube use, and self-updates weekly.\n"
            "\n"
            "State (CLI and GUI share the same files; SQLite uses WAL so reads\n"
            "and writes from both work concurrently):\n"
            "  ~/Library/Application Support/Paragraphos/state.sqlite\n"
            "  ~/Library/Application Support/Paragraphos/watchlist.yaml\n"
            "  ~/Library/Application Support/Paragraphos/settings.yaml\n"
            "  ~/Library/Application Support/Paragraphos/logs/paragraphos.log\n"
            "\n"
            "Headless CLI (run from ~/dev/paragraphos):\n"
            "  cd ~/dev/paragraphos && \\\n"
            "    PYTHONPATH=. .venv/bin/python cli.py <command> [args]\n"
            "\n"
            "Most inspection commands accept --json. Always pass --json when\n"
            "you want to parse output. The CLI has full GUI parity — never edit\n"
            "watchlist.yaml or run raw sqlite for things that have a command.\n"
            "\n"
            "Inspection (start here):\n"
            "  status [--json]                      Snapshot: queue depth, in-\n"
            "                                       flight, by-status counts,\n"
            "                                       queue_paused flag\n"
            "  shows [--json]                       Watchlist + per-show counts\n"
            "                                       + feed health\n"
            "  show <slug> [--json]                 Full detail for one show\n"
            "  episodes <slug> [--status X]         List episodes; status one of\n"
            "    [--limit N] [--json]               pending/downloading/...\n"
            "                                       /done/failed/stale\n"
            "  failed [--show X] [--limit N]        Failed eps + error_text\n"
            "    [--json]\n"
            "  settings [--json]                    All settings; (rec=N) shows\n"
            "                                       hardware-aware mismatch\n"
            "  feed-health [--show X] [--json]      Per-show feed health +\n"
            "                                       backoff state\n"
            "\n"
            "Queue control (live; running GUI picks up changes immediately):\n"
            "  pause                                Pause queue (worker stops\n"
            "                                       claiming new work)\n"
            "  resume                               Unpause\n"
            "  stop                                 Force-stop: pkill -9\n"
            "                                       whisper-cli + yt-dlp,\n"
            "                                       recover in-flight → pending\n"
            "  clear-queue                          Mark every pending/in-flight\n"
            "                                       episode as done\n"
            "  priority <guid> <N>                  Set priority (DB-claim sorts\n"
            "                                       priority DESC, pub_date ASC)\n"
            "  run-next <guid>                      Shortcut: priority=100\n"
            "  retranscribe <guid>                  status=pending + priority=100\n"
            "  retry-failed [--show X]              Re-queue failed eps from\n"
            "    [--all-time] [--window-hours N]    last N hours (default 24)\n"
            "\n"
            "Show management:\n"
            "  add <name-or-url>                    Add a show (podcast name /\n"
            "    --backlog <all|recent|             RSS / YouTube URL). --backlog\n"
            "      last:N|since:YYYY-MM-DD>          is REQUIRED: how much history\n"
            "    [--yes]                            to transcribe. NEVER edit\n"
            "    [--captions | --whisper]           watchlist.yaml directly — the\n"
            "    [--skip-shorts |                   running app overwrites raw edits.\n"
            "      --include-shorts]                Any YouTube URL form is auto-\n"
            "                                       detected → source=youtube (a video\n"
            "                                       URL adds its channel; the same\n"
            "                                       channel can't be added twice).\n"
            "                                       --backlog does a DEEP backfill\n"
            "                                       (whole archive, not just the RSS\n"
            "                                       window). YouTube flags: --captions/\n"
            "                                       --whisper (transcript pref),\n"
            "                                       --skip-shorts/--include-shorts\n"
            "                                       (Shorts excluded by default).\n"
            "                                       GUI: 'Add YouTube Channel…' button\n"
            "                                       + double-click a show for the\n"
            "                                       episode browser (multi-select,\n"
            "                                       Queue selected / Queue all since,\n"
            "                                       status filters, full back-catalogue).\n"
            "  backlog <slug>                       Deepen an existing YouTube show's\n"
            "    --backlog <all|recent|             history beyond the RSS window and\n"
            "      last:N|since:YYYY-MM-DD>          queue the new videos.\n"
            "  enable <slug> / disable <slug>       Toggle a show\n"
            "  remove <slug> [-y] [--purge-state]   Drop show; mark eps done\n"
            "                                       (or delete eps with --purge-state)\n"
            "  set <slug> key=value                 Per-show field setter.\n"
            "                                       Allowed keys: enabled,\n"
            "                                       language, whisper_prompt,\n"
            "                                       output_override,\n"
            "                                       youtube_transcript_pref,\n"
            "                                       source, title, rss,\n"
            "                                       artwork_url\n"
            "  import-feeds                         Bulk-import the curated\n"
            "                                       podcast list\n"
            "\n"
            "Local ingest (v1.3.0 — files, folders, URLs; synthetic shows,\n"
            "no RSS feed. Good for one-off recordings, pasted clips, or\n"
            "backfilling a pile of existing audio):\n"
            "  ingest file <path> [--show SLUG]     One local media file;\n"
            "                                       prints sha256:<hex> GUID\n"
            "  ingest url <url> [--show SLUG]       yt-dlp generic extractor\n"
            "                                       (SoundCloud, Vimeo, any\n"
            "                                       site yt-dlp recognises);\n"
            "                                       prints <Extractor>:<id>\n"
            "  ingest folder <path>                 Batch-queue every\n"
            "    [--show SLUG]                      supported file in a\n"
            "    [--no-recursive]                   directory tree\n"
            "  watch add <path>                     Enable the watch-folder\n"
            "                                       source + set its root.\n"
            "                                       New files landing in\n"
            "                                       top-level subfolders\n"
            "                                       auto-queue against a\n"
            "                                       show derived from the\n"
            "                                       subfolder name.\n"
            "  watch remove                         Disable the watcher\n"
            "  watch list [--json]                  Inspect current config\n"
            "\n"
            "Feed retry (after fixing connectivity, DNS, or a moved feed URL):\n"
            "  retry-feed <slug>                    Clear backoff + immediate\n"
            "                                       fetch for one show\n"
            "  retry-all-feeds                      Same for every feed marked\n"
            "                                       fail\n"
            "\n"
            "Top-level settings:\n"
            "  set-setting <key> <value>            Type-coerced from the\n"
            "                                       Settings model. Examples:\n"
            "                                         set-setting load_level full\n"
            "                                         set-setting save_srt false\n"
            "                                         set-setting youtube_default_transcript_source whisper\n"
            "\n"
            "Pipeline trigger (long-running; foregrounded):\n"
            "  check [--show <slug>] [--limit N]    Refresh feeds + drain queue.\n"
            "                                       YouTube tries captions first.\n"
            "                                       Works offline: downloaded\n"
            "                                       MP3s keep transcribing.\n"
            "\n"
            "Settings of interest (settings.yaml — read with `settings --json`):\n"
            "  sources_podcasts / sources_youtube              source toggles\n"
            "  youtube_default_transcript_source               captions | whisper\n"
            "  youtube_default_language                        de | en | auto | …\n"
            "  youtube_skip_shorts_default                     exclude Shorts (default true)\n"
            "  load_level / background_priority               quiet | balanced | full\n"
            "  whisper_fast_mode                               beam=1/best=1, ~2-3× faster\n"
            "  save_srt / mp3_retention_days                   output / cleanup\n"
            "  auto_start_queue / auto_start_delay_seconds     launch behaviour\n"
            "  connectivity_monitor_enabled                    offline banner +\n"
            "                                                  auto-resume\n"
            "  auto_resume_failed_window_hours                 default 24\n"
            "  daily_check_time / catch_up_missed              daily cron HH:MM; a\n"
            "                                                  missed check is now\n"
            "                                                  caught up on the next\n"
            "                                                  app foreground (v1.4.0)\n"
            "  update_check_enabled                            GitHub release check\n"
            "                                                  on launch + on app\n"
            "                                                  activation, ≤1×/24h;\n"
            "                                                  off = no network (v1.4.0)\n"
            "\n"
            "Per-show overrides (read with `show <slug> --json`, write with\n"
            "`set <slug> key=value`):\n"
            "  enabled                  bool — skip in checks when false\n"
            "  language                 whisper lang code; 'auto' = detect\n"
            "  youtube_transcript_pref  '' (inherit Settings default) | captions\n"
            "                           (import manual uploader subs per video,\n"
            "                           whisper fallback) | whisper (always\n"
            "                           transcribe)\n"
            "  whisper_prompt           bias domain vocabulary\n"
            "  output_override          custom transcript dir\n"
            "\n"
            "Example agent tasks (chain CLI calls):\n"
            "  · 'Run `status --json` and tell me if the queue is healthy.'\n"
            "  · 'Find every show with feed_health=fail, then run\n"
            "     retry-all-feeds, then run status again.'\n"
            "  · 'List failed episodes from the last 24 h with --json, group\n"
            "     them by error class, and propose a retry strategy.'\n"
            "  · 'Add the YouTube channel <URL> with --backlog last:3 and\n"
            "     language=en, then run-next on the newest episode.'\n"
            "  · 'For show <slug>, switch to always-whisper mode, then\n"
            "     retranscribe the 5 newest episodes.'\n"
            "  · 'Set the background load to quiet while I work, then\n"
            "     set-setting load_level full to run flat-out overnight.'\n"
            "  · 'Batch-ingest every .wav under ~/Recordings/Zoom/2026-04\n"
            "     via `ingest folder --show zoom`, then tail `status\n"
            "     --json` until the queue drains.'\n"
            "  · 'Ingest the Vimeo URL <url> and run-next once it lands.'\n"
            "\n"
            "Task: <describe what you want the agent to do>\n"
        )

    def _agent_prompt_html(self) -> str:
        import html

        return html.escape(self._agent_prompt_plain())
