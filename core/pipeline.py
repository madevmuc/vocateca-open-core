"""End-to-end episode pipeline: dedup → download → transcribe → retention."""

from __future__ import annotations

import logging
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from core.downloader import download_mp3
from core.library import LibraryIndex
from core.sanitize import sanitize_filename
from core.state import EpisodeStatus, StateStore
from core.transcriber import TranscriptionError, transcribe_episode

logger = logging.getLogger(__name__)

_DISK_GUARD_BYTES = 2 * 1024 * 1024 * 1024  # 2 GB


class DiskSpaceError(RuntimeError):
    pass


@dataclass
class PipelineContext:
    state: StateStore
    library: LibraryIndex
    output_root: Path
    whisper_prompt: str
    retention_days: int
    delete_mp3_after: bool
    language: str = "de"
    model_name: str = "large-v3-turbo"
    fast_mode: bool = False
    processors: int = 1
    threads: int = 6
    launch_prefix: tuple[str, ...] = ()
    save_srt: bool = True
    # Confidence marking (1.3): when on, request token-level JSON and wrap
    # sub-threshold words in ==highlight== in the transcript body.
    confidence_marking: bool = False
    confidence_threshold: float = 0.5
    # Duration filters (3.3): effective bounds in seconds (0 = no limit).
    # Resolved per show (show value over settings default) in the worker.
    min_duration_sec: int = 0
    max_duration_sec: int = 0
    # YouTube-source dispatch (Theme A). When ``source == "youtube"`` the
    # pipeline routes the episode through the captions-first / whisper-
    # fallback branch instead of the standard MP3-download path. The
    # remaining YouTube fields are populated per-show by
    # ui.worker_thread._pctx_for(show); they are ignored for podcast shows.
    source: str = "podcast"
    youtube_transcript_pref: str = ""  # "" → fall back to default below
    youtube_default_transcript_source: str = "captions"
    # Caption fallback chain (3.4): manual_whisper | manual_auto_whisper.
    caption_fallback_mode: str = "manual_whisper"
    youtube_channel_id: str = ""
    # When True (the per-show default), a cheap probe runs before download
    # and a YouTube Short is marked SKIPPED instead of transcribed. When
    # False the probe is skipped entirely and Shorts transcribe normally.
    skip_shorts: bool = True


@dataclass(frozen=True)
class PipelineResult:
    action: Literal["transcribed", "skipped", "failed", "deferred"]
    guid: str
    detail: str = ""


def _record_failure(ctx, guid: str, exc: BaseException, err: str) -> str:
    """Categorize a pipeline exception (6.1), record it with an attempt bump,
    and decide retry vs. terminal failure. Returns the PipelineResult action
    ("deferred" when re-queued for a transient retry, else "failed")."""
    from core import errors

    category = errors.categorize(exc)
    # Peek current attempts to decide before the bump.
    ep = ctx.state.get_episode(guid)
    attempts = int((ep or {}).get("attempts") or 0)
    retry = errors.should_retry(category, attempts)
    ctx.state.record_failure(guid, category, err, retry=retry)
    return "deferred" if retry else "failed"


def caption_source_chain(pref: str, fallback_mode: str) -> list[str]:
    """Ordered transcript sources for a YouTube episode (3.4).

    A per-show ``pref`` of ``"whisper"`` forces audio (skips captions). Otherwise
    the settings ``caption_fallback_mode`` decides the caption chain:
    ``manual_whisper`` → manual captions then whisper; ``manual_auto_whisper`` →
    manual then auto captions then whisper. Unknown modes fall back to
    ``manual_whisper``.
    """
    if pref == "whisper":
        return ["whisper"]
    if fallback_mode == "manual_auto_whisper":
        return ["manual", "auto", "whisper"]
    return ["manual", "whisper"]


def build_slug(pub_date: str, title: str, episode_number: str = "0000") -> str:
    """YYYY-MM-DD_<ep-num>_<sanitized-title>."""
    pd = pub_date[:10] if pub_date else "1970-01-01"
    title_part = sanitize_filename(title, max_bytes=120)
    ep = episode_number or "0000"
    return f"{pd}_{ep}_{title_part}"


def _guard_disk(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(path).free
    if free < _DISK_GUARD_BYTES:
        raise DiskSpaceError(f"only {free // 1024**2} MB free at {path}")


def _find_existing_audio(audio_dir: Path, pub_date: str, title: str) -> Path | None:
    """Return an already-on-disk audio file matching ``<pub_date>_*_<title>``,
    or None.

    Used as the slug-drift escape hatch in download_phase. The slug is
    rebuilt every call from (pub_date, title, episode_number) but the
    episode_number is only known when ep_num_map carries it for the
    current run. An earlier run with the real number could have written
    `<date>_0102_<title>.mp3`; this run rebuilds with `0000` and would
    miss it. Globbing for the same date prefix + title fragment
    catches it.

    Match is conservative: same `YYYY-MM-DD` prefix AND the file's
    stem must contain the FULL sanitised title (matching build_slug's
    120-byte cap). An earlier 20-char prefix match was too loose — it
    crossed '(1/2)' and '(2/2)' parts (identical first 20 chars), handing
    part 2 part 1's audio. The full title still tolerates episode_number
    drift (only the number between date and title differs) while keeping
    distinct episodes apart. Falls back to ``None`` if 0 or 2+ candidates
    remain after the title check.
    """
    if not audio_dir.is_dir():
        return None
    date_prefix = (pub_date or "")[:10]
    if not date_prefix:
        return None
    title_part = sanitize_filename(title or "", max_bytes=120)
    candidates = sorted(audio_dir.glob(f"{date_prefix}_*"))
    candidates = [
        p
        for p in candidates
        if p.is_file()
        and p.suffix.lower() in (".mp3", ".m4a", ".mp4", ".wav", ".ogg", ".webm", ".flac", ".aac")
    ]
    if title_part:
        scoped = [p for p in candidates if title_part in p.name]
        if len(scoped) == 1:
            return scoped[0]
        # If title-scoped match is ambiguous, prefer the largest file
        # (most likely the real audio rather than a partial / leftover).
        if len(scoped) > 1:
            return max(scoped, key=lambda p: p.stat().st_size)
        # Title-scoped found zero — refuse to fall through to date-only
        # matches, which would happily return the wrong episode when
        # two episodes share a publish date but have unrelated titles.
        return None
    # No title to scope by (caller passed a blank title). Only match
    # when exactly one candidate exists for that date.
    if len(candidates) == 1:
        return candidates[0]
    return None


@dataclass(frozen=True)
class DownloadOutcome:
    """Result of the download phase.

    If ``result`` is set, the episode is done (dedup skip) or failed before
    transcription could start. Otherwise ``mp3_path`` / ``show_dir`` / ``slug``
    carry the artefacts the transcribe phase needs.
    """

    guid: str
    result: PipelineResult | None = None  # terminal (skipped/failed)
    mp3_path: Path | None = None
    show_dir: Path | None = None
    slug: str | None = None
    ep: dict | None = None


def download_phase(
    guid: str, ctx: PipelineContext, *, episode_number: str = "0000"
) -> DownloadOutcome:
    """Dedup + download. Terminal results are folded into DownloadOutcome.result."""
    ep = ctx.state.get_episode(guid)
    if ep is None:
        raise ValueError(f"unknown guid {guid}")

    # Duration filter (3.3): skip episodes whose KNOWN length is out of the
    # configured range. Unknown duration passes through to normal processing.
    from core.filters import duration_filter_reason

    _reason = duration_filter_reason(
        ep.get("duration_sec"), ctx.min_duration_sec, ctx.max_duration_sec
    )
    if _reason:
        ctx.state.set_status(guid, EpisodeStatus.SKIPPED, error_text=_reason)
        return DownloadOutcome(guid=guid, result=PipelineResult("skipped", guid, _reason))

    base_slug = build_slug(ep["pub_date"], ep["title"], episode_number)
    # Reserve a unique-per-guid slug up front. build_slug is NOT unique —
    # feed re-uploads and '(1/2)'/'(2/2)' parts collapse to the same slug,
    # so without this two episodes share one <slug>.mp3 + <slug>.md (→ a
    # retention unlink races into `whisper-cli exit 2`, or silent transcript
    # overwrite). See StateStore.reserve_slug.
    slug = ctx.state.reserve_slug(guid, base_slug)

    # 1) Dedup — key on the reserved slug so a re-run finds its OWN
    # transcript, never a same-titled sibling's.
    dup = ctx.library.check_dedup(guid=guid, filename_key=slug)
    if dup.matched:
        ctx.state.set_status(guid, EpisodeStatus.DONE)
        return DownloadOutcome(
            guid=guid,
            result=PipelineResult("skipped", guid, f"dedup/{dup.reason} → {dup.path}"),
        )

    # 2) Download
    from core.security import safe_path_within

    show_dir = ctx.output_root / ep["show_slug"]
    audio_dir = show_dir / "audio"
    mp3_path = audio_dir / f"{slug}.mp3"
    safe_path_within(ctx.output_root, mp3_path)
    safe_path_within(ctx.output_root, show_dir / f"{slug}.md")

    # 2a) Already-on-disk shortcut. Two cases hit this:
    #   * Local-source ingest (mp3_url starts with 'file://') — the
    #     audio is already where it lives; just point at it.
    #   * Slug drift across runs. download_phase rebuilds slug from
    #     (pub_date, title, episode_number) every time, but
    #     ep_num_map is only populated for THIS run's feed-fetch. An
    #     earlier run with the real episode_number wrote
    #     `<date>_<real-num>_<title>.mp3`; this run rebuilds with
    #     `_0000_` and would re-download (or, after the v1.3
    #     persist-mp3_path patch, fail because mp3_path is stale).
    #     Glob for any `<YYYY-MM-DD>_*.mp3` in the audio dir whose
    #     stem ends in the same sanitized title; if found, skip the
    #     network round-trip and use it.
    # Only the guid that owns the *clean* slug may adopt a drift-recovered
    # file by globbing date+title. A disambiguated claimant (slug !=
    # base_slug) must use its own reserved path — otherwise it would
    # re-adopt the very sibling file reservation just steered it away from.
    existing = (
        _find_existing_audio(audio_dir, ep["pub_date"], ep["title"]) if slug == base_slug else None
    )
    if existing is not None:
        # Persist + return so transcribe_phase reads from the real file,
        # not the slug-rebuilt guess.
        ctx.state.set_mp3_path(guid, str(existing))
        ctx.state.set_status(guid, EpisodeStatus.DOWNLOADED)
        return DownloadOutcome(
            guid=guid,
            mp3_path=existing,
            show_dir=show_dir,
            slug=existing.stem,
            ep=ep,
        )
    if (ep.get("mp3_url") or "").startswith("file://"):
        # Local-file ingest with no on-disk hit above means the source
        # file moved or never existed — surface a clear download error
        # rather than letting safe_url raise an opaque
        # "refused scheme 'file'" message.
        local_origin = ctx.state.get_meta(f"local_path:{guid}") or ""
        if local_origin and Path(local_origin).exists():
            # Source is still readable; just stage / point at it.
            ctx.state.set_mp3_path(guid, local_origin)
            ctx.state.set_status(guid, EpisodeStatus.DOWNLOADED)
            return DownloadOutcome(
                guid=guid,
                mp3_path=Path(local_origin),
                show_dir=show_dir,
                slug=slug,
                ep=ep,
            )
        err = (
            f"download failed [LocalFileMissing]: source file no longer at "
            f"{local_origin or ep['mp3_url']!r}; restore the file or "
            f"remove the episode."
        )
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
        return DownloadOutcome(
            guid=guid,
            result=PipelineResult("failed", guid, err),
        )
    try:
        _guard_disk(audio_dir)
        ctx.state.set_status(guid, EpisodeStatus.DOWNLOADING)
        download_mp3(ep["mp3_url"], mp3_path)
    except DiskSpaceError as e:
        ctx.state.set_status(guid, EpisodeStatus.PENDING)
        return DownloadOutcome(
            guid=guid,
            result=PipelineResult("failed", guid, f"disk: {e}"),
        )
    except Exception as e:
        err = (
            f"download failed [{type(e).__name__}]: {e}\n"
            f"  show={ep['show_slug']}  guid={guid}\n"
            f"  url={ep['mp3_url']}\n"
            f"  dest={mp3_path}"
        )
        logger.error("download failed: %s (guid=%s)", ep["show_slug"], guid, exc_info=True)
        action = _record_failure(ctx, guid, e, err)
        return DownloadOutcome(guid=guid, result=PipelineResult(action, guid, err))
    # Persist the actual on-disk path BEFORE flipping status — orphan
    # recovery on next launch reads mp3_path back and avoids the
    # slug-rebuild guesswork that defaulted to episode_number='0000'
    # and missed files saved with the real episode number.
    ctx.state.set_mp3_path(guid, str(mp3_path))
    ctx.state.set_status(guid, EpisodeStatus.DOWNLOADED)
    return DownloadOutcome(
        guid=guid,
        mp3_path=mp3_path,
        show_dir=show_dir,
        slug=slug,
        ep=ep,
    )


def transcribe_phase(outcome: DownloadOutcome, ctx: PipelineContext) -> PipelineResult:
    """Transcribe an already-downloaded episode + run retention."""
    assert outcome.result is None and outcome.ep is not None
    assert outcome.mp3_path is not None and outcome.show_dir is not None
    assert outcome.slug is not None

    guid = outcome.guid
    ep = outcome.ep
    mp3_path = outcome.mp3_path
    show_dir = outcome.show_dir
    slug = outcome.slug

    ctx.state.set_status(guid, EpisodeStatus.TRANSCRIBING)
    from pathlib import Path as _P

    model_path = _P.home() / ".config/open-wispr/models" / f"ggml-{ctx.model_name}.bin"

    # Pre-transcribe integrity checks (6.5): a truncated audio file or a model
    # whose hash drifted from its TOFU pin fails fast with a clear reason rather
    # than a cryptic whisper error much later.
    from core import integrity

    _ireason = integrity.check_audio_integrity(mp3_path) or integrity.check_model_integrity(
        model_path, ctx.model_name
    )
    if _ireason:
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=f"integrity: {_ireason}")
        return PipelineResult("failed", guid, f"integrity: {_ireason}")

    # Write % progress into state.meta so the Queue tab can render
    # "transcribing · X%" on the active row. The transcriber uses a
    # subprocess.run + stdout→file + background poller chain that
    # preserves test-mock compatibility.
    audio_sec = int(ep.get("duration_sec") or 0) or 1

    def _write_progress(elapsed_audio_sec: int) -> None:
        pct = max(0, min(99, int(100 * elapsed_audio_sec / audio_sec)))
        try:
            ctx.state.set_meta(f"transcribe_pct:{guid}", str(pct))
        except Exception:
            pass

    try:
        result = transcribe_episode(
            mp3_path=mp3_path,
            output_dir=show_dir,
            slug=slug,
            metadata=ep,
            whisper_prompt=ctx.whisper_prompt,
            language=ctx.language,
            model_path=model_path,
            fast_mode=ctx.fast_mode,
            processors=ctx.processors,
            threads=ctx.threads,
            launch_prefix=ctx.launch_prefix,
            save_srt=ctx.save_srt,
            confidence_marking=ctx.confidence_marking,
            confidence_threshold=ctx.confidence_threshold,
            progress_cb=_write_progress,
        )
    except TranscriptionError as e:
        err = f"transcribe failed: {e}\n  show={ep['show_slug']}  guid={guid}\n  mp3={mp3_path}"
        logger.error("transcribe failed: %s (guid=%s)", ep["show_slug"], guid, exc_info=True)
        action = _record_failure(ctx, guid, e, err)
        return PipelineResult(action, guid, err)
    ctx.library.add(result.md_path)
    from core.stats import _duration_from_srt

    ctx.state.record_completion(guid, result.word_count, _duration_from_srt(result.srt_path))
    _detected = getattr(result, "detected_language", None)
    if _detected:
        ctx.state.set_detected_language(guid, _detected)
    _meanconf = getattr(result, "mean_confidence", None)
    if _meanconf is not None:
        ctx.state.set_mean_confidence(guid, _meanconf)
    ctx.state.set_status(guid, EpisodeStatus.DONE)
    # Clean up stale % so a later re-transcribe of the same guid starts
    # from blank instead of inheriting the previous 99%.
    try:
        ctx.state.set_meta(f"transcribe_pct:{guid}", "")
    except Exception:
        pass

    # Record the engine+model fingerprint of this successful transcribe so
    # Settings can flag drift when whisper-cli or the model is upgraded.
    try:
        import json

        from core.engine_version import current_fingerprint

        ctx.state.set_meta(
            "last_transcribed_version",
            json.dumps(current_fingerprint(ctx.model_name)),
        )
    except Exception:
        # Never let fingerprint bookkeeping break a successful transcribe.
        pass

    # Retention — but never unlink a file another episode still needs.
    # Unique slugs make sharing impossible going forward; this also
    # protects legacy rows written before reservation existed.
    if ctx.delete_mp3_after and not ctx.state.other_active_uses_mp3_path(guid, str(mp3_path)):
        try:
            mp3_path.unlink()
        except OSError:
            pass

    return PipelineResult("transcribed", guid, str(result.md_path))


def process_episode(
    guid: str, ctx: PipelineContext, *, episode_number: str = "0000"
) -> PipelineResult:
    """Serial dedup → download → transcribe → retention (kept for CLI/tests)."""
    if ctx.source == "youtube":
        return _process_youtube_episode(guid, ctx, episode_number=episode_number)
    if ctx.source == "local":
        return _process_local_episode(guid, ctx, episode_number=episode_number)
    outcome = download_phase(guid, ctx, episode_number=episode_number)
    if outcome.result is not None:
        return outcome.result
    return transcribe_phase(outcome, ctx)


def _process_local_episode(
    guid: str, ctx: PipelineContext, *, episode_number: str = "0000"
) -> PipelineResult:
    """Local-source branch: dedup → copy/symlink → whisper → retention.

    The source file's absolute path was persisted at ingest time under
    ``state.meta["local_path:<guid>"]``. We materialise it into the
    show's staging ``audio/`` directory (copy for robustness — symlink
    would break on external-drive unmounts later) and then reuse the
    existing :func:`transcribe_phase` machinery by forging a
    ``DownloadOutcome``.
    """
    import shutil as _shutil

    from core.security import safe_path_within

    ep = ctx.state.get_episode(guid)
    if ep is None:
        raise ValueError(f"unknown guid {guid}")

    slug = ctx.state.reserve_slug(guid, build_slug(ep["pub_date"], ep["title"], episode_number))

    dup = ctx.library.check_dedup(guid=guid, filename_key=slug)
    if dup.matched:
        ctx.state.set_status(guid, EpisodeStatus.DONE)
        return PipelineResult("skipped", guid, f"dedup/{dup.reason} → {dup.path}")

    src_path_str = ctx.state.get_meta(f"local_path:{guid}") or ""
    if not src_path_str:
        err = "local ingest: missing local_path meta"
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
        return PipelineResult("failed", guid, err)
    src = Path(src_path_str)
    if not src.exists():
        err = f"local ingest: source file missing on disk: {src}"
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
        return PipelineResult("failed", guid, err)

    show_dir = ctx.output_root / ep["show_slug"]
    audio_dir = show_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    # Preserve the user's extension so whisper-cli routes the right
    # ffmpeg demuxer. build_slug's .mp3 suffix in the podcast path was
    # an accident of history; for local we keep the real extension.
    staged = audio_dir / f"{slug}{src.suffix}"
    safe_path_within(ctx.output_root, staged)
    safe_path_within(ctx.output_root, show_dir / f"{slug}.md")
    try:
        _guard_disk(audio_dir)
        ctx.state.set_status(guid, EpisodeStatus.DOWNLOADING)
        _shutil.copy2(src, staged)
    except DiskSpaceError as e:
        ctx.state.set_status(guid, EpisodeStatus.PENDING)
        return PipelineResult("failed", guid, f"disk: {e}")
    except OSError as e:
        err = f"local ingest: copy failed [{type(e).__name__}]: {e}"
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
        return PipelineResult("failed", guid, err)
    # Persist staged path before status flip so orphan-recovery on the
    # next launch can locate the file via state.mp3_path regardless of
    # extension (podcast path uses .mp3 glob; local stages .wav/.m4a/.mp4).
    ctx.state.set_mp3_path(guid, str(staged))
    ctx.state.set_status(guid, EpisodeStatus.DOWNLOADED)

    # Hand off to the existing transcribe machinery via a forged outcome.
    outcome = DownloadOutcome(
        guid=guid,
        mp3_path=staged,
        show_dir=show_dir,
        slug=slug,
        ep=ep,
    )
    return transcribe_phase(outcome, ctx)


def _process_youtube_episode(
    guid: str, ctx: PipelineContext, *, episode_number: str = "0000"
) -> PipelineResult:
    """YouTube dispatch: captions-first, whisper-fallback.

    For ``Show.source == "youtube"`` episodes the dedup check still runs,
    but the download/transcribe sequence is replaced with:

      1. If pref is ``captions`` or ``auto-captions``, try
         :func:`core.youtube_captions.fetch_manual_captions`. On success,
         render `.md` via :func:`core.export.render_episode_markdown` and
         skip whisper entirely.
      2. Otherwise (or on caption failure) download MP3 audio via
         :func:`core.youtube_audio.download_audio` and reuse the existing
         :func:`core.transcriber.transcribe_episode` path. Then overwrite
         the `.md` with the YouTube-aware renderer so frontmatter carries
         ``source: youtube`` + ``youtube_id`` + ``transcript_source``.
    """
    from core import youtube as yt_url
    from core import youtube_audio, youtube_captions
    from core.export import render_episode_markdown
    from core.security import safe_path_within
    from core.youtube_captions import NoCaptionsAvailable

    ep = ctx.state.get_episode(guid)
    if ep is None:
        raise ValueError(f"unknown guid {guid}")

    slug = ctx.state.reserve_slug(guid, build_slug(ep["pub_date"], ep["title"], episode_number))

    # Dedup — same key as podcast path.
    dup = ctx.library.check_dedup(guid=guid, filename_key=slug)
    if dup.matched:
        ctx.state.set_status(guid, EpisodeStatus.DONE)
        return PipelineResult("skipped", guid, f"dedup/{dup.reason} → {dup.path}")

    try:
        parsed = yt_url.parse_youtube_url(ep["mp3_url"])
    except yt_url.YoutubeUrlError as e:
        err = f"bad youtube url: {e}"
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
        return PipelineResult("failed", guid, err)
    if parsed.kind != "video":
        err = f"YouTube episode without video URL: {ep['mp3_url']!r}"
        ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
        return PipelineResult("failed", guid, err)
    vid = parsed.value

    # Proactive Shorts skip: only when the show excludes Shorts. A cheap
    # metadata probe classifies the video; a Short is terminal-SKIPPED and
    # never downloaded. Any other category is handled reactively below.
    if ctx.skip_shorts:
        from core.youtube_classify import classify_video

        try:
            meta = youtube_audio.probe_video_meta(vid)
        except Exception:
            meta = {}
        category, message = classify_video(meta)
        if category == "short":
            ctx.state.set_status(guid, EpisodeStatus.SKIPPED)
            return PipelineResult("skipped", guid, message or "YouTube Short")
        # The probe already knows the duration — persist it (cheap) so the
        # Queue's Audio/Whisper/Finish columns + the live % work for this video.
        _dur = int(meta.get("duration") or 0)
        if _dur > 0 and not int(ep.get("duration_sec") or 0):
            ctx.state.set_duration_sec(guid, _dur)
            ep["duration_sec"] = _dur

    pref = ctx.youtube_transcript_pref or ctx.youtube_default_transcript_source or "captions"
    # Build the ordered source chain from the per-show pref + the settings
    # caption-fallback mode (3.4). A legacy "auto-captions" pref keeps meaning
    # "manual then auto then whisper".
    if pref == "auto-captions":
        chain = ["manual", "auto", "whisper"]
    else:
        chain = caption_source_chain(pref, ctx.caption_fallback_mode)
    want_auto = "auto" in chain

    show_dir = ctx.output_root / ep["show_slug"]
    show_dir.mkdir(parents=True, exist_ok=True)
    work_dir = show_dir / "_yt" / slug
    work_dir.mkdir(parents=True, exist_ok=True)
    safe_path_within(ctx.output_root, work_dir)
    safe_path_within(ctx.output_root, show_dir / f"{slug}.md")

    transcript_source: str | None = None
    srt_path: Path | None = None

    if "manual" in chain:
        ctx.state.set_status(guid, EpisodeStatus.DOWNLOADING)
        try:
            srt_path = youtube_captions.fetch_manual_captions(
                vid,
                work_dir / "video",
                lang=ctx.language or "en",
                auto_ok=want_auto,
            )
            transcript_source = "auto-captions" if want_auto else "captions"
        except NoCaptionsAvailable:
            srt_path = None

    if srt_path is None:
        # Whisper fallback (or pref == "whisper").
        audio_dir = show_dir / "audio"
        audio_dir.mkdir(parents=True, exist_ok=True)
        mp3_path = audio_dir / f"{slug}.mp3"
        safe_path_within(ctx.output_root, mp3_path)
        try:
            _guard_disk(audio_dir)
            ctx.state.set_status(guid, EpisodeStatus.DOWNLOADING)
            youtube_audio.download_audio(vid, mp3_path)
        except DiskSpaceError as e:
            ctx.state.set_status(guid, EpisodeStatus.PENDING)
            return PipelineResult("failed", guid, f"disk: {e}")
        except Exception as e:
            from core.youtube_classify import classify_video

            category, message = classify_video(str(e))
            # Live/premiere/upcoming → DEFERRED (re-probed later, not a failure).
            if category == "live":
                ctx.state.set_status(guid, EpisodeStatus.DEFERRED)
                return PipelineResult("deferred", guid, message)
            # Members-only / age-restricted / region-locked → FAILED with the
            # friendly classification message rather than the raw exception.
            if category in ("members_only", "age_restricted", "region_locked"):
                ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=message)
                return PipelineResult("failed", guid, message)
            # Unrecognised error → generic FAILED (never deferred: avoids a
            # livelock on a persistent error such as a bot-gate challenge).
            err = f"youtube audio download failed [{type(e).__name__}]: {e}"
            logger.error("yt audio failed: %s (guid=%s)", ep["show_slug"], guid, exc_info=True)
            ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
            return PipelineResult("failed", guid, err)
        ctx.state.set_status(guid, EpisodeStatus.DOWNLOADED)

        # Hand off to the existing whisper path; reuse its progress
        # bookkeeping and SRT/MD writing. We then overwrite the MD with
        # the YouTube-aware frontmatter.
        ctx.state.set_status(guid, EpisodeStatus.TRANSCRIBING)
        from pathlib import Path as _P

        model_path = _P.home() / ".config/open-wispr/models" / f"ggml-{ctx.model_name}.bin"

        # Live transcription % for the Queue (mirrors transcribe_phase). Make
        # sure we know the audio length first — probe once if the backfill
        # didn't record it — so the % and the Queue Audio/Whisper/Finish
        # columns have a real length to work from.
        audio_sec = int(ep.get("duration_sec") or 0)
        if not audio_sec:
            try:
                _m = youtube_audio.probe_video_meta(vid)
                audio_sec = int(_m.get("duration") or 0)
            except Exception:
                audio_sec = 0
            if audio_sec > 0:
                ctx.state.set_duration_sec(guid, audio_sec)
                ep["duration_sec"] = audio_sec

        def _write_progress(elapsed_audio_sec: int) -> None:
            pct = max(0, min(99, int(100 * elapsed_audio_sec / (audio_sec or 1))))
            try:
                ctx.state.set_meta(f"transcribe_pct:{guid}", str(pct))
            except Exception:
                pass

        try:
            wresult = transcribe_episode(
                mp3_path=mp3_path,
                output_dir=show_dir,
                slug=slug,
                metadata=ep,
                whisper_prompt=ctx.whisper_prompt,
                language=ctx.language,
                model_path=model_path,
                fast_mode=ctx.fast_mode,
                processors=ctx.processors,
                threads=ctx.threads,
                launch_prefix=ctx.launch_prefix,
                save_srt=True,  # always need SRT for YouTube re-render
                progress_cb=_write_progress,
            )
        except TranscriptionError as e:
            err = f"transcribe failed: {e}"
            ctx.state.set_status(guid, EpisodeStatus.FAILED, error_text=err)
            return PipelineResult("failed", guid, err)
        srt_path = wresult.srt_path
        transcript_source = "whisper"

        if ctx.delete_mp3_after and not ctx.state.other_active_uses_mp3_path(guid, str(mp3_path)):
            try:
                mp3_path.unlink()
            except OSError:
                pass

    # Render YouTube-aware markdown + write SRT next to it.
    md_text = render_episode_markdown(
        show_slug=ep["show_slug"],
        title=ep["title"],
        srt_text=srt_path.read_text(encoding="utf-8"),
        source="youtube",
        youtube_id=vid,
        channel_id=ctx.youtube_channel_id or None,
        transcript_source=transcript_source,
        pub_date=ep.get("pub_date") or "",
    )
    md_out = show_dir / f"{slug}.md"
    srt_out = show_dir / f"{slug}.srt"
    md_out.write_text(md_text, encoding="utf-8")
    if ctx.save_srt:
        srt_out.write_text(srt_path.read_text(encoding="utf-8"), encoding="utf-8")

    ctx.library.add(md_out)
    try:
        from core.stats import _duration_from_srt

        ctx.state.record_completion(guid, len(md_text.split()), _duration_from_srt(srt_path))
    except Exception:
        ctx.state.record_completion(guid, len(md_text.split()))
    ctx.state.set_status(guid, EpisodeStatus.DONE)
    try:
        ctx.state.set_meta(f"transcribe_pct:{guid}", "")
    except Exception:
        pass

    return PipelineResult("transcribed", guid, str(md_out))
