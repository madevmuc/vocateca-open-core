"""whisper.cpp wrapper — transcribes a single episode into Obsidian-ready .md + .srt."""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Mapping, Sequence


def _locate_whisper_bin() -> str:
    """Find whisper-cli via PATH, falling back to common Homebrew prefixes.

    Apple Silicon Homebrew: /opt/homebrew/bin
    Intel Homebrew        : /usr/local/bin
    Returns the Apple-Silicon path as a last resort so a missing binary
    surfaces through the existing WHISPER_BIN exists-check rather than
    an unhelpful None.
    """
    found = shutil.which("whisper-cli")
    if found:
        return found
    for p in ("/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"):
        if Path(p).exists():
            return p
    return "/opt/homebrew/bin/whisper-cli"


def _locate_ffmpeg_dir() -> str | None:
    """Return the directory containing ``ffmpeg``, or None.

    Whisper-cli shells out to ffmpeg internally for non-WAV inputs
    (mp3, m4a, mp4 podcasts). When Paragraphos.app is launched from
    /Applications its PATH is ``/usr/bin:/bin`` only — Homebrew binaries
    are invisible. With ffmpeg missing, whisper-cli silently exits 0
    with no transcript output for any non-WAV file, manifesting as a
    "expected outputs missing" TranscriptionError ~700 ms after launch.
    Surfacing the discovered directory via the subprocess env's PATH
    fixes that without forcing the user to re-shim their shell.
    """
    found = shutil.which("ffmpeg")
    if found:
        return str(Path(found).parent)
    for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if Path(p).exists():
            return str(Path(p).parent)
    return None


WHISPER_BIN = _locate_whisper_bin()
_FFMPEG_DIR = _locate_ffmpeg_dir()


def _is_whisper_native(src: Path) -> bool:
    """Sniff first 16 bytes for a magic that whisper.cpp's bundled
    dr_libs decoder actually handles (WAV / MP3 / FLAC).

    Trusting the extension is unsafe — a user-reported failure had
    podcasts whose enclosure was iTunes ALAC inside an M4A box but the
    feed advertised `.mp3`. Whisper-cli then exited 0 with no output
    in ~700 ms (no ftyp, dr_libs gives up silently). Magic-byte sniff
    catches that:

      * ``RIFF…WAVE``                       — WAV
      * ``ID3``                              — MP3 with ID3 tag
      * ``\\xFF\\xFB`` / ``\\xFF\\xF3`` / ``\\xFF\\xF2`` — bare MPEG audio frame sync
      * ``fLaC``                             — FLAC

    Anything else (incl. ``ftyp`` MP4 boxes) returns False so the
    caller pre-converts via ffmpeg.
    """
    try:
        with src.open("rb") as f:
            head = f.read(16)
    except OSError:
        return False
    if len(head) < 4:
        return False
    if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
        return True
    if head[:3] == b"ID3":
        return True
    if head[0] == 0xFF and head[1] in (0xFB, 0xF3, 0xF2):
        return True
    if head[:4] == b"fLaC":
        return True
    return False


def _maybe_convert_to_wav(src: Path, tmpdir: str) -> Path:
    """Return a path whisper-cli can read.

    Pass-through when magic-byte sniff says the file is WAV / MP3 /
    FLAC. For anything else (M4A, MP4, OGG, WebM, AAC, ALAC inside
    MP4, …) shell out to ffmpeg, write a 16 kHz mono PCM WAV into
    ``tmpdir``, and return that path.

    On ffmpeg failure (binary missing, codec error, etc.) returns
    ``src`` unchanged so the caller still sees whisper's own diagnostic
    rather than a confusing pre-pass error.
    """
    import shutil as _shutil
    import subprocess as _subprocess

    if _is_whisper_native(src):
        return src
    ffmpeg = _shutil.which("ffmpeg")
    if ffmpeg is None and _FFMPEG_DIR is not None:
        candidate = Path(_FFMPEG_DIR) / "ffmpeg"
        if candidate.exists():
            ffmpeg = str(candidate)
    if ffmpeg is None:
        return src
    out = Path(tmpdir) / f"{src.stem}.wav"
    try:
        _subprocess.run(
            [
                ffmpeg,
                "-y",
                "-loglevel",
                "error",
                "-i",
                str(src),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_s16le",
                str(out),
            ],
            check=True,
            capture_output=True,
            timeout=600,
        )
    except Exception:  # noqa: BLE001
        return src
    if not out.exists() or out.stat().st_size == 0:
        return src
    return out


def _whisper_subprocess_env() -> dict[str, str] | None:
    """Build the ``env=`` dict for whisper-cli subprocess calls.

    Returns ``None`` (= inherit os.environ) when no augmentation is
    needed — keeps the existing test suite stable, since most tests
    mock subprocess.run and don't care about env. Returns a dict with
    the ffmpeg directory prepended to PATH whenever we know where
    ffmpeg lives but it isn't already on the inherited PATH.
    """
    import os

    if _FFMPEG_DIR is None:
        return None
    inherited_path = os.environ.get("PATH", "")
    if _FFMPEG_DIR in inherited_path.split(":"):
        return None
    env = os.environ.copy()
    env["PATH"] = f"{_FFMPEG_DIR}:{inherited_path}" if inherited_path else _FFMPEG_DIR
    return env


MODEL_PATH = Path.home() / ".config" / "open-wispr" / "models" / "ggml-large-v3-turbo.bin"
LANGUAGE = "de"
THREADS = "6"
# Hard floor for the dynamic timeout — guarantees at least 30 min for any
# MP3 even when the file-size heuristic would yield less (small files
# never need it; this is just defensive).
WHISPER_TIMEOUT_FLOOR_SEC = 1800


def _whisper_timeout(mp3_path: Path) -> int:
    """Compute a per-episode whisper-cli timeout from the MP3 file size.

    History: a hardcoded 600 s timed out hour-long podcasts on slow
    macs (Intel + multiproc=1 + beam=5/best=5 default). For ~64 kbps
    podcast MP3s 1 MB ≈ 2 min audio; allow 90 s wall-time per MB plus
    120 s base. So:

      40 MB (≈80 min audio)  → ~62 min timeout
      80 MB (≈160 min audio) → ~122 min timeout
      150 MB (≈300 min audio)→ ~227 min timeout

    Floored at 30 min so tiny MP3s still have headroom on slow CPUs.
    Falls back to the floor when the file isn't yet on disk (test code
    paths, mostly).
    """
    try:
        mb = mp3_path.stat().st_size / (1024 * 1024)
    except OSError:
        return WHISPER_TIMEOUT_FLOOR_SEC
    return max(WHISPER_TIMEOUT_FLOOR_SEC, int(mb * 90) + 120)


# Natural German podcast speech runs ~140-180 wpm. Below 30 → silence or hallucination.
MIN_WPM_GUARD = 30

STALE_YEARS = 1


def _model_name_from_path(model_path: Path) -> str:
    """Reverse ``ggml-<name>.bin`` → ``<name>``.

    Kept tolerant: if the caller passed a weirdly-named model file we just
    return the stem so the fingerprint helper has *something* to key on.
    """
    stem = model_path.stem  # drops .bin
    return stem[5:] if stem.startswith("ggml-") else stem


class TranscriptionError(RuntimeError):
    pass


def _explain_exit(rc: int) -> str:
    """Map a subprocess exit code to a one-line human explanation. Used
    in TranscriptionError messages so a user reading the log can tell
    "you clicked Stop" from "the kernel killed it for OOM" from "whisper
    crashed". Negative codes follow Python's subprocess convention
    (the process died from signal -rc); positive codes are the binary's
    own exit status."""
    if rc == -9 or rc == 137:
        return "killed (SIGKILL — usually the Stop button's force-kill, or macOS OOM)"
    if rc == -15 or rc == 143:
        return "terminated (SIGTERM — graceful stop request)"
    if rc == -2 or rc == 130:
        return "interrupted (SIGINT — Ctrl-C)"
    if rc == -6 or rc == 134:
        return "aborted (SIGABRT — whisper-cli internal assertion)"
    if rc == -11 or rc == 139:
        return "segfault (SIGSEGV — whisper-cli crash; report with stderr)"
    if rc == 2:
        return "no input file (the audio path handed to whisper-cli did not exist)"
    if rc == 124:
        return "timeout (per-MP3 deadline exceeded)"
    if rc == 127:
        return "command not found (whisper-cli or its loader missing)"
    if rc == 0:
        return "ok"
    if rc < 0:
        return f"killed by signal {-rc}"
    return f"exited with non-zero status {rc}"


@dataclass(frozen=True)
class TranscribeResult:
    md_path: Path
    srt_path: Path
    word_count: int
    # ISO 639 code whisper auto-detected when language="auto" (e.g. "de").
    # None when a fixed language was supplied or detection couldn't be parsed.
    detected_language: str | None = None
    # Mean whisper token confidence (0..1) when confidence marking ran; else None.
    mean_confidence: float | None = None


# whisper-cli logs e.g. "whisper_full_with_state: auto-detected language: de (p = 0.98)"
_DETECTED_LANG_RE = re.compile(r"auto-detected language:\s*([a-z]{2,3})")


def parse_detected_language(text: str) -> str | None:
    """Extract the ISO language code from whisper-cli's auto-detect log line."""
    if not text:
        return None
    m = _DETECTED_LANG_RE.search(text)
    return m.group(1) if m else None


def _build_whisper_cmd(
    *,
    whisper_bin: str,
    model_path,
    whisper_input,
    language: str,
    threads: int,
    stem,
    fast_mode: bool,
    processors: int,
    whisper_prompt: str,
    confidence_json: bool = False,
    launch_prefix: Sequence[str] = (),
) -> list[str]:
    """Assemble the whisper-cli argv. Split out so the flag set is unit-testable.

    ``confidence_json`` adds ``-oj`` / ``--output-json-full`` (token-level JSON)
    only when confidence marking is enabled — it changes the output set and
    costs runtime, so it stays off by default.
    """
    cmd = [
        *launch_prefix,
        whisper_bin,
        "-m",
        str(model_path),
        "-f",
        str(whisper_input),
        "-l",
        language,
        "-t",
        str(threads),
        "-of",
        str(stem),
        "-otxt",
        "-osrt",
    ]
    if confidence_json:
        cmd += ["-oj", "--output-json-full"]
    if fast_mode:
        cmd += ["-bs", "1", "-bo", "1", "-ac", "0", "--no-fallback"]
    if processors > 1:
        cmd += ["-p", str(processors)]
    if whisper_prompt:
        cmd += ["--prompt", whisper_prompt]
    return cmd


def _fmt_frontmatter(
    meta: Mapping[str, str],
    engine: Mapping[str, str] | None = None,
    detected_language: str | None = None,
) -> str:
    lines = ["---"]
    for key in ("guid", "show_slug", "title", "pub_date", "mp3_url"):
        v = meta.get(key, "")
        lines.append(f'{key}: "{v}"')
    lines.append(f'transcribed_at: "{datetime.now(timezone.utc).isoformat()}"')
    if detected_language:
        lines.append(f'detected_language: "{detected_language}"')
    # Engine fingerprint — lets the UI detect whisper/model upgrades and
    # offer a bulk re-transcribe. Missing fields are skipped so we never
    # write a `null`-valued line.
    if engine:
        for key in ("whisper_version", "whisper_model", "model_sha256"):
            v = engine.get(key)
            if v:
                lines.append(f'{key}: "{v}"')
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def _banner(pub_date_str: str) -> str:
    try:
        d = date.fromisoformat(pub_date_str[:10])
    except (ValueError, TypeError):
        return ""
    age_days = (date.today() - d).days
    banner = f"> [!info] Episode vom {d.isoformat()} (vor {age_days} Tagen)\n"
    if age_days > 365 * STALE_YEARS:
        banner += (
            f"> [!warning] ⚠ Stale: Folge ist älter als "
            f"{STALE_YEARS} Jahr(e) — zeitkritische Aussagen prüfen.\n"
        )
    return banner + "\n"


_WHISPER_TS = __import__("re").compile(r"\[\s*(\d+):(\d+):(\d+)\.\d+\s*-->\s*\d+:\d+:\d+\.\d+\s*\]")


def transcribe_episode(
    *,
    mp3_path: Path,
    output_dir: Path,
    slug: str,
    metadata: Mapping[str, str],
    whisper_prompt: str = "",
    language: str = LANGUAGE,
    whisper_bin: str = WHISPER_BIN,
    model_path: Path = MODEL_PATH,
    fast_mode: bool = False,
    processors: int = 1,
    threads: int = int(THREADS),
    launch_prefix: Sequence[str] = (),
    save_srt: bool = True,
    confidence_marking: bool = False,
    confidence_threshold: float = 0.5,
    progress_cb=None,
) -> TranscribeResult:
    """Run whisper-cli once and produce <output_dir>/<slug>.md and .srt.

    `fast_mode` toggles the 2-3× speedup decoder flags (beam=1, best-of=1,
    -ac 0, --no-fallback) at slight quality cost. `processors` enables
    whisper-cli's `-p N` audio-split parallelism for long episodes.
    """
    # Pre-flight: a missing input file is the ONE condition whisper-cli
    # signals only as `exit 2` + a full usage dump — the actual
    # "error: input file not found '<path>'" line scrolls off the top of
    # stderr, so the `stderr[-400:]` snippet below would keep just the
    # VAD-options tail. Catch it here with a precise message instead.
    # A vanished mp3 at this point almost always means another episode
    # collapsed to the same slug and its retention sweep unlinked the
    # shared file first — see core.state.reserve_slug for the fix that
    # keeps slugs unique per guid.
    try:
        input_missing = not mp3_path.exists()
    except OSError:
        input_missing = True
    if input_missing:
        raise TranscriptionError(
            f"audio file no longer on disk: {mp3_path}\n"
            f"  slug={slug!r}\n"
            f"  (likely deleted by mp3 retention while a duplicate-slug "
            f"episode shared this path)"
        )

    output_dir.mkdir(parents=True, exist_ok=True)

    # Capture engine fingerprint BEFORE spawning whisper — (1) so tests that
    # mock subprocess.run to inspect the transcribe argv see the real
    # transcribe call as the LAST captured invocation, not the version
    # probe, and (2) because the version probe is cached per-process so
    # we pay the cost at most once anyway.
    try:
        from core.engine_version import current_fingerprint

        engine = current_fingerprint(_model_name_from_path(model_path), whisper_bin=whisper_bin)
    except Exception:
        engine = {}

    with tempfile.TemporaryDirectory() as td:
        stem = Path(td) / slug
        # Whisper.cpp's built-in audio loader covers WAV / MP3 / FLAC.
        # Anything else (M4A / MP4 / AAC / OGG / WebM / Matroska — common
        # for podcasts whose enclosure is `audio/mp4` or whose feed lies
        # about the Content-Type) makes whisper-cli exit 0 in ~700 ms
        # with no output. Pre-convert via ffmpeg into the same tempdir
        # and feed whisper the WAV. The output stem stays slug-based so
        # downstream .txt / .srt paths don't change.
        whisper_input = _maybe_convert_to_wav(mp3_path, td)
        cmd = _build_whisper_cmd(
            whisper_bin=whisper_bin,
            model_path=model_path,
            whisper_input=whisper_input,
            language=language,
            threads=threads,
            stem=stem,
            fast_mode=fast_mode,
            processors=processors,
            whisper_prompt=whisper_prompt,
            confidence_json=confidence_marking,
            launch_prefix=launch_prefix,
        )
        # Per-episode timeout scaled to MP3 size — see _whisper_timeout
        # docstring. Keeps slow Intel macs from hard-failing on hour-long
        # podcasts while still detecting genuine hangs.
        timeout_sec = _whisper_timeout(mp3_path)
        if progress_cb is None:
            # Classic blocking path — keeps `subprocess.run` so existing
            # tests that mock it stay valid. Used by the CLI, tests,
            # and any caller that doesn't want streaming overhead.
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=timeout_sec,
                    env=_whisper_subprocess_env(),
                )
            except subprocess.TimeoutExpired as te:
                raise TranscriptionError(
                    f"whisper-cli timed out after {timeout_sec}s  "
                    f"mp3={mp3_path.name}  slug={slug!r}\n"
                    f"  partial stderr: {(te.stderr or b'')[-300:]!r}"
                ) from te
        else:
            # Streaming path — redirects whisper's stdout (where the
            # `[HH:MM:SS.xxx --> ...]` segment lines land) to a temp
            # file, polls that file once per second from a daemon
            # thread, and invokes progress_cb with the last parsed
            # end-timestamp. Still uses subprocess.run so test mocks
            # that patch it continue to work — the mock receives the
            # open file handle via the `stdout=` kwarg and can write
            # simulated segment lines to it.
            import threading

            stdout_log = stem.parent / f"{slug}.stdout.log"
            stop_event = threading.Event()
            poller_state = {"last_size": 0, "max_sec": 0}

            def _drain_once() -> None:
                """Read anything new from stdout_log, fire progress_cb for the
                last timestamp. Safe to call from either thread."""
                try:
                    with open(stdout_log, encoding="utf-8", errors="replace") as f:
                        f.seek(poller_state["last_size"])
                        chunk = f.read()
                        poller_state["last_size"] = f.tell()
                except (FileNotFoundError, OSError):
                    return
                best = poller_state["max_sec"]
                for m in _WHISPER_TS.finditer(chunk):
                    h, mi, s = (int(x) for x in m.groups())
                    sec = h * 3600 + mi * 60 + s
                    if sec > best:
                        best = sec
                if best > poller_state["max_sec"]:
                    poller_state["max_sec"] = best
                    try:
                        progress_cb(best)
                    except Exception:
                        pass

            def _poller() -> None:
                while not stop_event.wait(1.0):
                    _drain_once()

            thread = threading.Thread(target=_poller, name="whisper-poll", daemon=True)
            thread.start()
            try:
                with open(stdout_log, "w", encoding="utf-8") as stdout_f:
                    try:
                        result = subprocess.run(
                            cmd,
                            stdout=stdout_f,
                            stderr=subprocess.PIPE,
                            text=True,
                            timeout=timeout_sec,
                            env=_whisper_subprocess_env(),
                        )
                    except subprocess.TimeoutExpired as te:
                        raise TranscriptionError(
                            f"whisper-cli timed out after {timeout_sec}s  "
                            f"mp3={mp3_path.name}  slug={slug!r}\n"
                            f"  partial stderr: {(te.stderr or b'')[-300:]!r}"
                        ) from te
            finally:
                stop_event.set()
                thread.join(timeout=2.0)
            # Final sync drain — catches anything written since the last
            # 1-s tick, and also catches fully-mocked (instant) runs
            # that never gave the poller a chance to tick.
            _drain_once()
            # Surface whisper's stdout via `result.stdout` so the error
            # paths below that inspect it still have useful context.
            try:
                result.stdout = stdout_log.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass
        if result.returncode != 0:
            stderr_text = result.stderr or ""
            # whisper-cli prints its real diagnostic ('error: input file
            # not found', 'error: unknown argument', …) at the TOP of
            # stderr, then a ~6 KB usage screen. The `stderr[-400:]`
            # snippet alone keeps only the usage tail (the VAD block),
            # hiding the cause — so lift the leading `error:` lines out.
            err_lines = [ln for ln in stderr_text.splitlines() if ln.lower().startswith("error:")]
            diagnostic = ("\n  whisper said: " + " | ".join(err_lines[:4])) if err_lines else ""
            raise TranscriptionError(
                f"whisper-cli exit {result.returncode} ({_explain_exit(result.returncode)})  "
                f"mp3={mp3_path.name}  model={model_path.name}  "
                f"slug={slug!r}{diagnostic}\n"
                f"  stderr (last 400): {stderr_text[-400:]!r}\n"
                f"  stdout (last 200): {(result.stdout or '')[-200:]!r}"
            )

        # whisper-cli APPENDS '.txt'/'.srt' to the -of prefix — it does NOT
        # replace a suffix. Path.with_suffix() would truncate at the last
        # dot in the slug (e.g. 'Nachhaltigkeit & Co. müssen' → 'Co.txt'),
        # so we'd read the wrong filename. Construct paths by string append.
        txt_path = stem.parent / (stem.name + ".txt")
        srt_src = stem.parent / (stem.name + ".srt")
        if not txt_path.exists() or not srt_src.exists():
            # Give future debugging a head start: list everything whisper
            # DID write so the user (or another agent) can diff expected
            # vs actual path immediately.
            actually_written = (
                sorted(p.name for p in stem.parent.iterdir()) if stem.parent.exists() else []
            )
            raise TranscriptionError(
                f"whisper-cli exited 0 but expected outputs missing.\n"
                f"  expected:\n"
                f"    {txt_path}\n"
                f"    {srt_src}\n"
                f"  temp dir contents: {actually_written}\n"
                f"  stdout (last 300): {(result.stdout or '')[-300:]!r}\n"
                f"  stderr (last 300): {(result.stderr or '')[-300:]!r}\n"
                f"  mp3={mp3_path.name}  slug={slug!r}"
            )

        # When language="auto", whisper logs the detected code on stderr.
        detected_language = None
        if language == "auto":
            detected_language = parse_detected_language(result.stderr or "")

        text = txt_path.read_text(encoding="utf-8").strip()
        words = len(text.split())

        # Confidence marking (1.3): parse the token-level JSON, compute the
        # mean confidence, and rewrite the body wrapping sub-threshold tokens
        # in ==highlight== spans. Defensive — a missing/garbled JSON leaves the
        # plain text untouched.
        mean_conf = None
        if confidence_marking:
            from core import confidence as _conf

            json_path = stem.parent / (stem.name + ".json")
            tokens = _conf.parse_json_full(json_path)
            if tokens:
                mean_conf = _conf.mean_confidence(tokens)
                marked = _conf.mark_low_confidence(tokens, confidence_threshold)
                if marked:
                    text = marked
        if words < MIN_WPM_GUARD:
            raise TranscriptionError(
                f"suspected whisper hallucination / silence: only {words} "
                f"words in transcript (guard threshold = {MIN_WPM_GUARD}).\n"
                f"  mp3={mp3_path.name}  slug={slug!r}\n"
                f"  first 200 chars: {text[:200]!r}"
            )

        md_path = output_dir / f"{slug}.md"
        srt_dest = output_dir / f"{slug}.srt"
        md_path.write_text(
            _fmt_frontmatter(metadata, engine, detected_language)
            + _banner(metadata.get("pub_date", ""))
            + text
            + "\n",
            encoding="utf-8",
        )
        # SRT is opt-in. Markdown is always saved; SRT carries per-segment
        # timestamps and is only useful if the user wants to quote passages
        # with an "at 12:34" reference. When disabled we leave srt_dest
        # un-written — downstream consumers (e.g. core.stats._duration_from_srt)
        # already handle a non-existent SRT path gracefully.
        if save_srt:
            srt_dest.write_bytes(srt_src.read_bytes())
        return TranscribeResult(
            md_path=md_path,
            srt_path=srt_dest,
            word_count=words,
            detected_language=detected_language,
            mean_confidence=mean_conf,
        )
