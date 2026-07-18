import Foundation

// MARK: - PipelineResult

/// The outcome of processing one episode through the pipeline.
public struct PipelineResult: Sendable, Equatable {
    /// The episode's GUID.
    public let guid: String
    /// The terminal status after processing.
    public let finalStatus: EpisodeStatus
    /// Path to the produced transcript file, or `nil` when unavailable.
    public let transcriptPath: String?

    public init(guid: String, finalStatus: EpisodeStatus, transcriptPath: String? = nil) {
        self.guid = guid
        self.finalStatus = finalStatus
        self.transcriptPath = transcriptPath
    }
}

// MARK: - Pipeline

/// The episode processing pipeline with injected engine protocols.
///
/// `Pipeline` drives a single episode from `pending` through download →
/// transcribe/OCR → library write → `done`, emitting status transitions at
/// each step. All I/O is delegated to the injected protocols so there is no
/// real network, Whisper, or file I/O in this struct — making it fully
/// testable with fakes.
///
/// ## Status-transition graph
///
/// **Podcast / YouTube audio-backed episode:**
/// ```
/// pending → downloading → downloaded → transcribing → done
/// ```
///
/// **Instagram image post/story (mediaType == "image" or igKind == "post"/"story"):**
/// ```
/// pending → downloading → downloaded → (OCR, no transcribing) → done
/// ```
///
/// **Transient failure** at any step:
/// - If `attempts < maxAttempts`: `recordFailure(retry:true)` → back to `pending`.
/// - If `attempts >= maxAttempts`: `recordFailure(retry:false)` → `failed`.
///
/// **Permanent failure**: immediately → `failed`.
///
/// **Skip**: immediately → `skipped`.
///
/// ## Max attempts
///
/// Default is **3**, mirroring Python `core/errors.py`:
/// ```python
/// def should_retry(category, attempts, max_attempts=3): ...
/// ```
/// This means the episode is tried at most 3 times total before being marked
/// `failed` (attempts is post-increment, so `attempts < 3` allows tries 1 and 2,
/// `attempts == 3` is the final try).
///
/// ## Retry-within-run vs re-queue design decision
///
/// Unlike Python's pipeline (which does in-loop retry with `_PIPELINE_RETRY_DELAYS`
/// for download failures), the Swift `Pipeline.process` does **not** retry within
/// a single call. On a transient failure it calls `recordFailure(retry:true)` which
/// sets the episode back to `pending`, and the `QueueWorker` will re-claim it in a
/// subsequent pass. This keeps `Pipeline` simple, avoids sleeping inside a
/// `TaskGroup` child task, and lets the worker's claim loop naturally schedule
/// retries. The attempt count prevents infinite loops.
public struct Pipeline: Sendable {

    /// Maximum number of total attempts before a transient failure becomes permanent.
    /// Mirrors Python `core/errors.py::should_retry` default `max_attempts=3`.
    public static let maxAttempts = 3

    /// This process's PID, used to stamp job-ownership rows (H7). Read once.
    static let currentPID: Int32 = ProcessInfo.processInfo.processIdentifier

    // MARK: - Progress phase mapping
    //
    // Overall 0..1 progress per episode is split across pipeline phases:
    //   Download:    0.00 – 0.12
    //   Transcribe:  0.12 – 1.00
    //   (OCR path:   0.12 – 1.00, treated the same as transcribe for simplicity)
    //
    // The split is deliberately NOT 50/50: transcription dominates wall-clock
    // time (minutes-to-tens-of-minutes) while a podcast/audio download is
    // usually seconds-to-a-few-minutes. A 50/50 bar jumped to 50% the instant
    // the (fast) download finished and then crawled through the (slow)
    // transcription — so "50%" read as "half done" when it meant "download
    // done, transcription just starting", and the elapsed÷fraction ETA
    // extrapolated the fast download rate into nonsense. Giving transcription
    // ~88% of the bar makes the fraction roughly time-proportional, so both the
    // bar and the ETA (QueueRunner.estimatedSecondsPerEpisode) are honest.
    //
    // Each phase emits `episode.progress` events via the injected EventBus
    // so QueueRunner can reflect live progress without polling.

    private static let downloadFractionStart  = 0.0
    private static let downloadFractionEnd    = 0.12
    private static let transcribeFractionStart = 0.12
    private static let transcribeFractionEnd   = 1.0
    // ASR (Whisper/Parakeet) reports up to `asrFractionEnd`; the remainder of the
    // transcribe band is RESERVED for the post-ASR finalize work — speaker
    // diarization (the slow tail) + the library write. Without this reservation
    // the ASR callback drove the bar to 100% while diarization (which can run for
    // tens of seconds on a long episode) still executed with no further progress
    // events, so the bar sat pinned at "Transcribing 100%" — the reported bug.
    private static let asrFractionEnd          = 0.90
    // Diarization maps its own 0…1 progress into `asrFractionEnd`…`diarizeFractionEnd`;
    // the final jump to `transcribeFractionEnd` (1.0) happens at the Done emit.
    private static let diarizeFractionEnd      = 0.98

    /// Splits an overall pipeline fraction (0…1) back into the current phase's
    /// own 0…1 fraction and its step index, for a two-step UI:
    ///   step 1 = download   (overall 0 … `downloadFractionEnd`)
    ///   step 2 = transcribe / OCR (overall `transcribeFractionStart` … 1)
    /// This is the inverse of the band mapping used by `emitProgress`, kept here
    /// as the single source of truth so the UI never hard-codes the boundary.
    /// - Parameter isDownloading: pass `true` while the episode is in the
    ///   download phase (status `downloading`), `false` for transcribe/OCR.
    public static func phaseStep(overall: Double, isDownloading: Bool) -> (step: Int, total: Int, fraction: Double) {
        let clamp = { (x: Double) in min(max(x, 0), 1) }
        if isDownloading {
            let span = downloadFractionEnd - downloadFractionStart
            return (1, 2, span > 0 ? clamp((overall - downloadFractionStart) / span) : 0)
        } else {
            let span = transcribeFractionEnd - transcribeFractionStart
            return (2, 2, span > 0 ? clamp((overall - transcribeFractionStart) / span) : 0)
        }
    }

    // MARK: - Injected engines

    private let store: StateStore
    private let downloader: any EpisodeDownloader
    private let transcriber: any Transcriber
    private let ocrProcessor: any ImageOCRProcessor
    private let libraryWriter: any LibraryWriter
    /// Serialises all event emission so progress/lifecycle events reach the bus in
    /// the exact order they were produced (L3). `nil` when no `bus` was supplied at
    /// init (tests that pass `bus: nil` emit nothing — unchanged behaviour). This
    /// replaces the former stored `bus`: every emission goes through the emitter,
    /// so the bus itself no longer needs to be held.
    private let emitter: PipelineEventEmitter?
    /// One-shot per-episode override of the no-speech skip ("Transcribe anyway").
    private let forceStore: ForceTranscribeStore
    /// Optional speaker-diarization engine (Package D). `nil` in tests/preview and
    /// whenever the real app/CLI hasn't injected one; the diarization stage is then
    /// skipped entirely and transcripts are written speaker-free (today's
    /// behaviour). Injected as an abstraction so Core stays free of FluidAudio —
    /// the concrete `FluidAudioDiarizer` lives in `VocatecaParakeet`.
    private let diarizer: (any Diarizer)?

    // MARK: - Initialisation

    /// Creates a pipeline with all injected engines and an optional `EventBus`
    /// for progress events.
    ///
    /// - Parameters:
    ///   - bus: An `EventBus` to receive `episode.progress` events. Pass `nil`
    ///          (the default) to suppress progress events entirely — no behaviour
    ///          change for callers that don't need progress.
    public init(
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber,
        ocrProcessor: any ImageOCRProcessor,
        libraryWriter: any LibraryWriter,
        bus: EventBus? = nil,
        forceStore: ForceTranscribeStore = ForceTranscribeStore(),
        diarizer: (any Diarizer)? = nil
    ) {
        self.store = store
        self.downloader = downloader
        self.transcriber = transcriber
        self.ocrProcessor = ocrProcessor
        self.libraryWriter = libraryWriter
        // One ordered emitter per pipeline; only when a bus is present (tests that
        // pass bus: nil emit nothing, unchanged). Serialises every event so a
        // subscriber never sees progress fractions out of order (L3).
        self.emitter = bus.map { PipelineEventEmitter(bus: $0) }
        self.forceStore = forceStore
        self.diarizer = diarizer
    }

    // MARK: - Private helpers

    /// Emits an `episode.progress` event if a bus is configured.
    /// Safe to call from any task — `EventBus.emit` is an actor method so this
    /// is an async hop; we fire-and-forget via a `Task` to avoid making the
    /// entire download/transcribe path async on the bus actor.
    /// Persists a status transition and, when it produced a lifecycle event, also
    /// emits that event on the bus — so subscribers (webhooks, reactors) see
    /// lifecycle events, not just the DB event log. `.skipped` is intentionally
    /// NOT routed here (Pipeline emits `episode.skipped` explicitly to avoid a
    /// double emit).
    private func setStatusEmitting(_ guid: String, _ status: EpisodeStatus, errorText: String? = nil, transcriptPath: String? = nil, transcriptOrigin: String? = nil) throws {
        let event = try store.setStatus(guid: guid, status, errorText: errorText, transcriptPath: transcriptPath, transcriptOrigin: transcriptOrigin)
        if let event {
            // Ordered emission (L3): lifecycle events must not overtake the progress
            // events around them, or the UI phase/bar can flicker.
            emitter?.emit(event)
        }
    }

    /// Resolves the YouTube caption source chain (``CaptionFallback``) and returns
    /// a transcript built from the first available caption track, or nil to fall
    /// back to Whisper. Best-effort throughout — never throws.
    static func youTubeCaptionResult(
        videoURL: String,
        pref: String,
        langHint: String?
    ) async -> TranscriptionResult? {
        let fallbackMode = (try? SettingsStore.load(
            from: Paths.settingsURL, persistDefaultOnMissing: false))?.captionFallbackMode
            ?? "manual_whisper"
        for source in CaptionFallback.sourceChain(pref: pref, fallbackMode: fallbackMode) {
            switch source {
            case "manual", "auto":
                if let vtt = await YtDlpCaptionFetcher.fetch(
                        videoURL: videoURL, auto: source == "auto", langHint: langHint),
                   let result = TranscriptFormat.captionResult(fromVTT: vtt, language: langHint, isAuto: source == "auto") {
                    // Tag provenance: platform auto-captions vs author-provided.
                    let kind: TranscriptOrigin.CaptionKind = (source == "auto") ? .auto : .manual
                    return result.withOrigin(.captions(kind))
                }
            case "whisper":
                return nil  // chain says: stop trying captions, use Whisper
            default:
                break
            }
        }
        return nil
    }

    /// Loads the watchlist and returns the `Show` for `showSlug`, or `nil`.
    ///
    /// **L9:** the three per-episode watchlist reads in `process` (length gate,
    /// language hint, music-detection opt-out) previously used a bare `try?` and
    /// fell silently to defaults on a corrupt/unreadable `watchlist.yaml` — so a
    /// broken watchlist would quietly ignore every show's length filter / language /
    /// opt-out with zero signal. This wraps the load in a logged catch: a genuine
    /// load error is surfaced (once per episode, at `.error`) while a legitimate
    /// "show not in watchlist" (e.g. a one-off import) stays quiet. Callers keep
    /// their existing default-fallback behaviour; only the invisibility is fixed.
    private func showConfig(for showSlug: String) -> Show? {
        do {
            return try Watchlist.load(from: Paths.watchlistURL)
                .shows.first(where: { $0.slug == showSlug })
        } catch {
            Log.error("Pipeline: watchlist load failed — proceeding with defaults for this show",
                      component: "Pipeline",
                      context: [("show", showSlug), ("error", "\(error)")])
            return nil
        }
    }

    private func emitProgress(guid: String, showSlug: String, phase: String, fraction: Double) {
        guard let emitter else { return }
        let event = Event(
            type: EventType.episodeProgress,
            showSlug: showSlug,
            guid: guid,
            payload: [
                "phase":    .string(phase),
                "fraction": .number(fraction)
            ]
        )
        // Ordered emission (L3): consecutive progress fractions must arrive in
        // order so the bar advances monotonically instead of jumping.
        emitter.emit(event)
    }

    /// The `phase` value for the visible model-load step. Reuses the existing
    /// `episode.progress` event (see `emitProgress`) rather than a new
    /// `EventType`, so `QueueRunner`'s existing progress subscription needs no
    /// new plumbing — only its `phase` handling is extended. `public` so the
    /// UI layer (`QueueController.syncItems()`) can match on it without
    /// duplicating the string literal.
    public static let modelLoadingPhase = "modelLoading"

    /// The `phase` value for the speaker-diarization step that runs AFTER ASR
    /// but before `.done`. Lets the UI show a distinct "Identifying speakers…"
    /// label + a moving bar (0.90→0.98) instead of a frozen "Transcribing 100%".
    public static let diarizingPhase = "diarizing"

    /// Emits a `modelLoading` progress event immediately before a cold engine's
    /// first `transcribe` call (see the `isWarm` check in `process`). The
    /// `fraction` is a sentinel `0.0`, not a real percent — engines don't
    /// expose byte-accurate model-download progress today (see `Transcriber`
    /// conformers' `isWarm`/load docs), so the UI renders this phase with an
    /// INDETERMINATE bar rather than reading `fraction` as a percentage.
    private func emitModelLoading(guid: String, showSlug: String) {
        emitProgress(guid: guid, showSlug: showSlug, phase: Self.modelLoadingPhase, fraction: 0.0)
    }

    // MARK: - Process

    /// Processes `episode` through the full pipeline, driving status transitions
    /// and returning the terminal `PipelineResult`.
    ///
    /// This method never throws — all errors are caught internally and translated
    /// into `failed` or `skipped` results with DB state recorded.
    ///
    /// ## Progress events
    /// When a non-nil `bus` was supplied at init, `episode.progress` events are
    /// emitted throughout the run. The fraction maps to a two-phase 0..1 range:
    /// - Download:   0.00 – 0.12 (byte-accurate if the downloader supports it)
    /// - Transcribe: 0.12 – 1.00 (per-window signal; transcription dominates
    ///   wall-clock time, so it owns most of the bar — see the phase-mapping note)
    public func process(_ episode: Episode) async -> PipelineResult {
        let guid = episode.guid
        let showSlug = episode.showSlug
        let isImageRoute = Self.isImagePost(episode)

        Log.debug("Pipeline starting",
                  component: "Pipeline",
                  context: [("guid", guid), ("show", showSlug),
                             ("route", isImageRoute ? "ocr" : "transcribe"),
                             ("attempts", "\(episode.attempts)")])

        // ── Deleted-show guard ──────────────────────────────────────────────
        // The claim loop reads from the DB, so a deleted show's episodes can't
        // be claimed — but a show can be deleted (`ShowDeletion.deleteShow`
        // DELETEs its episode rows) in the tiny window AFTER this episode was
        // claimed and BEFORE processing starts. Re-check the row still exists so
        // a running queue doesn't download + transcribe an episode the user just
        // deleted, then write a transcript file for a show that no longer exists.
        // Only skip on a definitive "row is gone"; a DB read error is
        // inconclusive and must NOT drop a valid episode (fail-open).
        let episodeStillExists: Bool
        do { episodeStillExists = try store.episode(guid: guid) != nil }
        catch { episodeStillExists = true }
        if !episodeStillExists {
            Log.info("Pipeline: episode row missing (show deleted after claim) — skipping",
                     component: "Pipeline", context: [("guid", guid), ("show", showSlug)])
            return PipelineResult(guid: guid, finalStatus: .skipped)
        }

        // ── H7: open a job-ownership row (heartbeat) ─────────────────────────
        // Assert THIS process owns `guid` for the duration of processing, so a
        // concurrent launch-reclaim (app ↔ CLI) leaves it alone instead of
        // double-transcribing it. Closed in the `defer` below at EVERY terminal
        // return (done / failed / skipped / cancelled-requeue). Best-effort — a
        // ledger write failure must never fail an otherwise-fine episode; it only
        // widens the reclaim window, so we log and proceed.
        let pid = Self.currentPID
        do { try store.beginJob(guid: guid, pid: pid) }
        catch {
            Log.error("Pipeline: beginJob failed (reclaim guard weakened for this episode)",
                      component: "Pipeline",
                      context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
        }
        defer {
            do { try store.endJob(guid: guid, pid: pid) }
            catch {
                Log.error("Pipeline: endJob failed (stale job row may linger until it goes stale)",
                          component: "Pipeline",
                          context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
            }
        }

        // ── Episode-length gate ─────────────────────────────────────────────
        // Runs BEFORE the download phase so an out-of-range episode never hits
        // the network. Only filters when the duration is actually known
        // (non-nil AND > 0) — an unknown duration (common before the feed
        // reports it, or for sources that never do) always proceeds normally
        // rather than being silently dropped. 0 on either bound means "no
        // limit" on that side, matching `Show`'s stored defaults.
        if let durationSec = episode.durationSec, durationSec > 0 {
            let show = showConfig(for: showSlug)
            let minSec = show?.minDurationSec ?? 0
            let maxSec = show?.maxDurationSec ?? 0
            let tooShort = minSec > 0 && durationSec < minSec
            let tooLong  = maxSec > 0 && durationSec > maxSec
            if tooShort || tooLong {
                let reason = "skipped: length \(durationSec)s outside [\(minSec),\(maxSec)]"
                Log.info("Episode outside show's length filter — skipping",
                         component: "Pipeline",
                         context: [("guid", guid), ("show", showSlug),
                                    ("durationSec", "\(durationSec)"),
                                    ("minSec", "\(minSec)"), ("maxSec", "\(maxSec)")])
                do { try store.setStatus(guid: guid, .skipped, errorText: reason) }
                catch {
                    Log.error("Pipeline: skip-status write failed (episode may re-process)",
                              component: "Pipeline",
                              context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
                }
                emitSkippedEvent(guid: guid, showSlug: showSlug, reason: reason)
                return PipelineResult(guid: guid, finalStatus: .skipped)
            }
        }

        // ── Download phase ─────────────────────────────────────────────────
        let mediaURL: URL
        do {
            try setStatusEmitting(guid, .downloading)

            Log.info("Download starting",
                     component: "Pipeline",
                     context: [("guid", guid), ("show", showSlug),
                                ("source", episode.mp3Url.isEmpty ? "(none)" : episode.mp3Url)])
            let downloadStart = Date()

            // Build a download-progress closure that maps [0,1] bytes → [0.0, 0.12] overall.
            let downloadProgress: ProgressReporter = { [self] byteFraction in
                let overall = Self.downloadFractionStart +
                    byteFraction * (Self.downloadFractionEnd - Self.downloadFractionStart)
                self.emitProgress(guid: guid, showSlug: showSlug,
                                  phase: "downloading", fraction: overall)
            }
            mediaURL = try await downloader.download(episode, progress: downloadProgress)
            // Emit the download-complete boundary fraction (may be the only signal
            // if the downloader doesn't call the progress closure at all).
            emitProgress(guid: guid, showSlug: showSlug,
                         phase: "downloading", fraction: Self.downloadFractionEnd)

            // Log bytes + duration + throughput so a stalled or slow download is
            // visible in the diagnostic log (the phase was previously silent).
            let dlElapsed = Date().timeIntervalSince(downloadStart)
            let dlBytes = (try? FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? Int64) ?? nil
            let mb = dlBytes.map { Double($0) / 1_048_576.0 }
            // Persist the on-disk media path BEFORE recording `.downloaded`.
            // This is what makes media retention real: the retention/cap passes
            // select rows `WHERE mp3_path IS NOT NULL`, so without this write the
            // 7-day age-out, per-show overrides, 10-GB cap and "storage almost
            // full" warning never fire and the media dir grows unbounded. Ordered
            // before the status write so a downloaded file is retention-eligible
            // the instant it lands (a subsequent status-write failure still leaves
            // a valid, reclaimable path pointing at a real file).
            //
            // EXCEPT for locally imported media. `URLSessionDownloader` returns the
            // user's own file in place (their `~/Downloads/…`, not a copy we made),
            // so registering it here would hand it to the retention/cap sweeps —
            // and the 7-day age-out would delete a file we never created and have
            // no right to remove. We only reclaim media we downloaded ourselves.
            let isImported = LocalIngestService.isOneOffGuid(guid)
            do {
                if isImported {
                    Log.info("Imported media — not retention-eligible (user's own file)",
                             component: "Pipeline",
                             context: [("guid", guid), ("show", showSlug), ("path", mediaURL.path)])
                } else {
                    try store.setMp3Path(guid: guid, path: mediaURL.path)
                    Log.info("Download path persisted (retention-eligible)",
                             component: "Pipeline",
                             context: [("guid", guid), ("show", showSlug), ("path", mediaURL.path)])
                }
            } catch {
                // Non-fatal: the file is on disk and the episode still proceeds to
                // transcription; only retention bookkeeping is affected. Log so a
                // DB-busy failure here is never invisible.
                Log.error("Pipeline: failed to persist mp3_path (retention may miss this file)",
                          component: "Pipeline",
                          context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
            }
            Log.info("Download complete",
                     component: "Pipeline",
                     context: [("guid", guid), ("show", showSlug),
                                ("MB", mb.map { String(format: "%.1f", $0) } ?? "?"),
                                ("seconds", String(format: "%.1f", dlElapsed)),
                                ("MBps", (mb != nil && dlElapsed > 0) ? String(format: "%.2f", mb! / dlElapsed) : "?")])
            try setStatusEmitting(guid, .downloaded)
        } catch let err as PipelineError {
            return await handlePipelineError(err, guid: guid, phase: "download")
        } catch {
            return await handlePipelineError(.permanent(error.localizedDescription),
                                              guid: guid, phase: "download")
        }

        // ── Transcribe / OCR phase ─────────────────────────────────────────
        if isImageRoute {
            // Instagram image post/story: OCR instead of audio transcription.
            // Emit a coarse "started" signal at the beginning of the OCR phase.
            emitProgress(guid: guid, showSlug: showSlug,
                         phase: "transcribing", fraction: Self.transcribeFractionStart)
            let ocrText: String
            do {
                // Re-fetch the episode to get the latest row (e.g. after status update).
                let refreshed = (try? store.episode(guid: guid)) ?? episode
                ocrText = try await ocrProcessor.process(refreshed, mediaPath: mediaURL)
            } catch let err as PipelineError {
                return await handlePipelineError(err, guid: guid, phase: "ocr")
            } catch {
                return await handlePipelineError(.permanent(error.localizedDescription),
                                                  guid: guid, phase: "ocr")
            }

            // ── Library write (OCR path) ─────────────────────────────────
            let transcriptURL: URL
            do {
                let refreshed = (try? store.episode(guid: guid)) ?? episode
                transcriptURL = try await libraryWriter.write(
                    episode: refreshed,
                    transcript: nil,
                    ocrText: ocrText,
                    mediaPath: mediaURL
                )
            } catch let err as PipelineError {
                return await handlePipelineError(err, guid: guid, phase: "library")
            } catch {
                return await handlePipelineError(.permanent(error.localizedDescription),
                                                  guid: guid, phase: "library")
            }

            // ── Done ─────────────────────────────────────────────────────
            emitProgress(guid: guid, showSlug: showSlug,
                         phase: "transcribing", fraction: Self.transcribeFractionEnd)
            do {
                try setStatusEmitting(guid, .done, transcriptPath: transcriptURL.path,
                                      transcriptOrigin: TranscriptOrigin.ocr.storageString)
            } catch {
                // The transcript file is on disk but persisting `.done` failed
                // (e.g. a transient DB lock). Do NOT report success — that would
                // strand the row in `transcribing` forever (never re-claimed,
                // file orphaned). Route to a retryable transient failure instead.
                return await handlePipelineError(
                    .transient("finalize: \(error.localizedDescription)"),
                    guid: guid, phase: "finalize")
            }
            Log.info("Episode done (OCR path)",
                     component: "Pipeline",
                     context: [("guid", guid), ("show", showSlug)])

            // ── Full-text search index (write hook, OCR path) ─────────────
            // Index the caption + OCR text so Instagram posts are searchable too.
            let refreshedForIndex = (try? store.episode(guid: guid)) ?? episode
            let ocrPlain = [refreshedForIndex.description, ocrText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            indexTranscriptForSearch(guid: guid, showSlug: showSlug,
                                     title: refreshedForIndex.title, content: ocrPlain)

            return PipelineResult(guid: guid, finalStatus: .done,
                                  transcriptPath: transcriptURL.path)

        } else {
            // Podcast / YouTube: audio transcription path.
            let refreshedForCorrection = (try? store.episode(guid: guid)) ?? episode
            let show = showConfig(for: showSlug)
            // Language hint for the transcriber:
            //   1. a previously-detected language (sticky across re-transcribes), else
            //   2. the show's configured language (per-show picker) unless Auto, else
            //   3. nil → the model auto-detects.
            let lang: String? = {
                if let d = refreshedForCorrection.detectedLanguage, !d.isEmpty { return d }
                return show?.languageHint
            }()

            // ── Proper-noun correction setup (built once per episode) ─────────
            // Glossary of metadata-known proper nouns + the prompt-biasing context
            // threaded into `transcribe`. The same glossary is reused after ASR to
            // rewrite mishearings before the writer, so `.md`/`.srt` inherit the
            // fix on every engine. Correction level comes from Settings (Free
            // feature), defaulting to `.conservative` on an unknown value.
            // Resolved BEFORE `buildCorrection` so the auto-glossary can be gated
            // by it — `.off` must not bias the decoder's prompt either.
            let correctionLevel = TranscriptGlossaryCorrector.Level(
                rawValue: (try? SettingsStore.load(
                    from: Paths.settingsURL, persistDefaultOnMissing: false))?
                    .properNounCorrection ?? "conservative") ?? .conservative
            let (correctionGlossary, transcriptionContext) = Self.buildCorrection(
                episode: refreshedForCorrection, show: show, language: lang,
                level: correctionLevel)

            var transcriptResult: TranscriptionResult
            do {
                try setStatusEmitting(guid, .transcribing)
                let refreshed = refreshedForCorrection

                // Build a transcription-progress closure that maps [0,1] → [0.12, 1.0] overall.
                // Also refreshes the H7 job heartbeat so a long transcription (tens
                // of minutes) keeps its ownership row fresh and a concurrent reclaim
                // never mistakes it for an orphan.
                //
                // Both are throttled. WhisperKit calls this back once per decoded
                // TOKEN — O(10^4–10^5) times on a long episode — and emitting an
                // event plus writing a SQLite heartbeat on every one of those put
                // unbounded pressure on the event queue and real I/O on the decode's
                // hot path (see `ProgressThrottle`; OOM incident 2026-07-16).
                let progressThrottle = ProgressThrottle()
                let heartbeatThrottle = HeartbeatThrottle()
                let transcribeProgress: ProgressReporter = { [self] segFraction in
                    // Map ASR 0…1 into [start, asrEnd] (NOT …1.0): the top of the
                    // band is reserved for diarization + write so the bar keeps
                    // moving past ASR instead of freezing at 100%.
                    let overall = Self.transcribeFractionStart +
                        segFraction * (Self.asrFractionEnd - Self.transcribeFractionStart)
                    if progressThrottle.shouldEmit(overall) {
                        self.emitProgress(guid: guid, showSlug: showSlug,
                                          phase: "transcribing", fraction: overall)
                    }
                    if heartbeatThrottle.shouldBeat() {
                        try? self.store.heartbeatJob(guid: guid, pid: Self.currentPID)
                    }
                }

                // YouTube caption path (1a): if this is a YouTube video (a
                // subscribed show OR a one-off whose URL is YouTube) and its
                // caption chain yields a transcript, use it and skip Whisper.
                // Everything is best-effort — any failure returns nil and we fall
                // through to the audio→Whisper path below (the safety net).
                let isYouTube = show?.source == "youtube"
                    || refreshed.mp3Url.contains("youtube.com")
                    || refreshed.mp3Url.contains("youtu.be")
                var captionResult: TranscriptionResult? = nil
                if isYouTube {
                    // Nudge progress off the exact download-done value while the
                    // caption fetch (network) runs, so the bar isn't frozen at 50%.
                    self.emitProgress(guid: guid, showSlug: showSlug,
                                      phase: "transcribing", fraction: 0.6)
                    captionResult = await Self.youTubeCaptionResult(
                        videoURL: refreshed.mp3Url,
                        pref: show?.youtubeTranscriptPref ?? "",
                        langHint: lang)
                }
                if let captionResult {
                    Log.info("Transcript from YouTube captions (skipped Whisper)",
                             component: "Pipeline",
                             context: [("guid", guid), ("show", showSlug),
                                        ("segments", "\(captionResult.segments.count)")])
                    // Cap at the ASR end (not 1.0), same as the Whisper path, so
                    // the shared diarize→write→done finalize band below doesn't
                    // jump the bar backwards from 100%.
                    self.emitProgress(guid: guid, showSlug: showSlug,
                                      phase: "transcribing", fraction: Self.asrFractionEnd)
                    transcriptResult = captionResult
                } else {
                    // Visible model-load step (kills the "hängt es?" moment).
                    // A cold engine's first `transcribe` call silently downloads
                    // ~0.6–1.7 GB before any real progress exists — with no
                    // signal that looks identical to a hang. `isWarm` is a cheap
                    // synchronous check of the engine's cached-instance state
                    // (no I/O), so this costs nothing on the warm path (every
                    // call after the first).
                    if await !transcriber.isWarm {
                        Log.info("Model not yet loaded — emitting modelLoading stage before transcribe",
                                 component: "Pipeline",
                                 context: [("guid", guid), ("show", showSlug)])
                        emitModelLoading(guid: guid, showSlug: showSlug)
                    }
                    transcriptResult = try await transcriber.transcribe(
                        audioURL: mediaURL, language: lang,
                        context: transcriptionContext, progress: transcribeProgress
                    )
                    // Cancellation guard — CRITICAL. On a Stop / hard-pause the
                    // worker's task group is cancelled; WhisperKit's per-window
                    // callback then returns `false` and the engine RETURNS the
                    // partially-decoded windows as a normal result (no throw). Without
                    // this check the half transcript would be written as `.done` and
                    // pushed downstream (webhooks/Notion). `checkCancellation()`
                    // throws `CancellationError` for the catch below, which requeues
                    // the episode to `pending` (no attempts bump) so it transcribes in
                    // full on the next run.
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                return await handlePipelineError(
                    .cancelled("transcription cancelled"), guid: guid, phase: "transcribe")
            } catch let timeout as TimeoutError {
                // H6: a cold engine's model load/download exceeded its deadline
                // (~10 min) — every candidate engine, including the universal
                // Whisper fallback, was still wedged. This is a machine/network
                // condition, NOT a per-episode fault: a stalled download can
                // succeed on the next attempt. Route it as `.transient` so the
                // episode requeues across the FULL attempt budget
                // (`maxAttempts`, 3), rather than the 2-attempt engine-error cap
                // (`transcribeRetryOnceOrFail`) which would fail it fast. The
                // engine load sites already logged the wedge; log the pipeline
                // decision too.
                Log.error("Pipeline: model load timed out — requeue (transient)",
                          component: "Pipeline",
                          context: [("guid", guid), ("show", showSlug),
                                     ("timeoutSec", String(format: "%.0f", timeout.seconds))])
                return await handlePipelineError(
                    .transient("model load timed out after \(String(format: "%.0f", timeout.seconds))s"),
                    guid: guid, phase: "transcribe")
            } catch let err as PipelineError {
                return await handlePipelineError(err, guid: guid, phase: "transcribe")
            } catch {
                // Engine failure (model load, decode, …). These are frequently
                // recoverable (a model-download blip, transient GPU/memory
                // pressure), so retry once rather than failing outright — that is
                // why a manual re-run used to "fix" it. Surface the UNDERLYING
                // error too (the wrapped WhisperKit error is otherwise lost as a
                // bare "error 0").
                let reason: String
                if case let WhisperKitTranscriberError.modelLoadFailed(model, underlying) = error {
                    reason = "model load failed (\(model)): \(underlying.localizedDescription)"
                } else {
                    reason = error.localizedDescription
                }
                return transcribeRetryOnceOrFail(guid: guid, showSlug: showSlug, reason: reason)
            }

            // ── Empty-transcript guard ────────────────────────────────────
            // A completely empty transcript (no text AND no segments) means the
            // engine delivered nothing — a transcription failure, not genuine
            // silence (music/instrumental produces low-WPM text or no-speech
            // probabilities and is handled by the no-speech step below). Retry
            // once; if the second attempt is still empty, fail the episode rather
            // than silently marking it done/skipped with no transcript.
            if transcriptResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && transcriptResult.segments.isEmpty {
                return transcribeRetryOnceOrFail(guid: guid, showSlug: showSlug,
                                                 reason: "transcription produced no transcript")
            }

            // ── Proper-noun correction (engine-agnostic, before the writer) ───
            // Rewrite metadata-known proper nouns the engine (or YouTube captions)
            // misheard — "Gokumo"→"gocomo", "Fertina"→"Firtina" — so every
            // downstream artefact (`.md`/`.srt`/`.txt`, the FTS index, webhooks)
            // inherits the fix. No-op when the level is `off` or nothing matches.
            // Runs after the empty guard (never on an empty result) and before
            // no-speech detection; it preserves segment count + probabilities, so
            // the no-speech verdict is unaffected. Rebuilds `text` from the
            // corrected segments so the concatenated transcript matches the SRT.
            if correctionLevel != .off, !transcriptResult.segments.isEmpty {
                let fixedSegments = correctedSegments(
                    transcriptResult.segments, glossary: correctionGlossary,
                    level: correctionLevel, guid: guid, showSlug: showSlug)
                if fixedSegments != transcriptResult.segments {
                    let fixedText = fixedSegments.map(\.text).joined(separator: " ")
                    transcriptResult = TranscriptionResult(
                        text: fixedText,
                        segments: fixedSegments,
                        language: transcriptResult.language,
                        origin: transcriptResult.origin)
                }
            }

            // ── No-speech detection ───────────────────────────────────────
            // Run AFTER transcription, BEFORE library write.
            // Conservative heuristic: only skips when confident.
            // User override ("Transcribe anyway"): if this episode is flagged in
            // ForceTranscribeStore, bypass the skip entirely and keep the
            // transcript. One-shot — clear the flag after consuming it.
            let refreshedForDuration = (try? store.episode(guid: guid)) ?? episode
            let durationSec = refreshedForDuration.durationSec.map(Double.init)
            let forced = forceStore.isForced(guid: guid)
            if forced {
                forceStore.clear(guid: guid)
                Log.info("Force-transcribe override — bypassing no-speech skip",
                         component: "Pipeline", context: [("guid", guid), ("show", showSlug)])
            }
            // Per-show music-detection opt-out. When the show is set to
            // "Always spoken word" (`assumeSpeech == true`, the default), the
            // no-speech / music-detection skip is bypassed entirely — the
            // episode is transcribed and kept even if the detector flagged it
            // as music (a jingle may just be a false positive), and NO
            // "skipped — no speech" notification is produced. When `false`
            // ("Auto-detect / skip music"), the detector runs as before.
            let assumeSpeech = showConfig(for: showSlug)?
                .assumeSpeech ?? Show.defaultAssumeSpeech
            let noSpeechVerdict: NoSpeechVerdict
            if forced {
                // "Transcribe anyway" override (already logged above).
                noSpeechVerdict = NoSpeechVerdict(isNoSpeech: false, reason: nil)
            } else if assumeSpeech {
                // Show is "Always spoken word": run the detector only to LOG when
                // it WOULD have skipped (so the bypass is visible in the log), but
                // never act on it — the episode is always transcribed.
                let wouldSkip = NoSpeechDetector.classify(transcriptResult, durationSec: durationSec)
                if wouldSkip.isNoSpeech {
                    Log.info("assumeSpeech — no-speech skip bypassed (show is 'Always spoken word')",
                             component: "Pipeline",
                             context: [("guid", guid), ("show", showSlug),
                                        ("wouldHaveSkipped", wouldSkip.reason ?? "music/instrumental")])
                }
                noSpeechVerdict = NoSpeechVerdict(isNoSpeech: false, reason: nil)
            } else {
                noSpeechVerdict = NoSpeechDetector.classify(transcriptResult, durationSec: durationSec)
            }
            if noSpeechVerdict.isNoSpeech {
                let reason = noSpeechVerdict.reason ?? "No speech detected — likely music/instrumental"
                Log.info("Episode no-speech detected — skipping",
                         component: "Pipeline",
                         context: [("guid", guid), ("show", showSlug), ("reason", reason)])
                do { try store.setStatus(guid: guid, .skipped, errorText: reason) }
                catch {
                    Log.error("Pipeline: skip-status write failed (episode may re-process)",
                              component: "Pipeline",
                              context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
                }
                emitSkippedEvent(guid: guid, showSlug: showSlug, reason: reason)
                return PipelineResult(guid: guid, finalStatus: .skipped)
            }

            // ── Speaker diarization (Package D, gated) ───────────────────
            // Runs AFTER proper-noun correction and the no-speech skip, and just
            // BEFORE the writer, so the tagged segments flow straight into the
            // `.md`/`.srt`/sidecar. Two gates: the user's `diarizationEnabled`
            // setting (Free feature, default on) AND an injected `diarizer` (nil in
            // tests/preview). The diarizer needs the AUDIO FILE that was just
            // transcribed — `mediaURL` is still on disk here (retention/cleanup runs
            // outside `process`, and the very next line hands the same `mediaURL` to
            // the writer), so it is safe to diarize now.
            //
            // Failure policy: diarization must NEVER fail an otherwise-good
            // transcription. Any error is logged and swallowed; the segments are
            // written speaker-free (today's behaviour). Only a SUCCESSFUL diarize
            // rewrites `transcriptResult` with speaker-tagged segments.
            let diarizationEnabled = (try? SettingsStore.load(
                from: Paths.settingsURL, persistDefaultOnMissing: false))?
                .diarizationEnabled ?? Settings.defaultDiarizationEnabled
            if diarizationEnabled, let diarizer, !transcriptResult.segments.isEmpty {
                let diarizeStart = Date()
                Log.info("Diarization stage starting",
                         component: "Diarize",
                         context: [("guid", guid), ("show", showSlug),
                                    ("file", mediaURL.lastPathComponent),
                                    ("asrSegments", "\(transcriptResult.segments.count)")])
                // Switch the UI to the "diarizing" phase immediately (before the
                // first diarizer callback), so the label + bar move off
                // "Transcribing 100%" the instant ASR ends.
                emitProgress(guid: guid, showSlug: showSlug,
                             phase: Self.diarizingPhase, fraction: Self.asrFractionEnd)
                do {
                    // Real progress this time (was `nil`): map the diarizer's 0…1
                    // into [asrEnd, diarizeEnd] so the bar advances through the
                    // formerly-silent diarization tail.
                    let speakers = try await diarizer.diarize(audioURL: mediaURL, progress: { [self] frac in
                        let overall = Self.asrFractionEnd
                            + max(0, min(1, frac)) * (Self.diarizeFractionEnd - Self.asrFractionEnd)
                        self.emitProgress(guid: guid, showSlug: showSlug,
                                          phase: Self.diarizingPhase, fraction: overall)
                    })
                    let tagged = SpeakerAssignment.assign(transcriptResult.segments, speakers: speakers)
                    transcriptResult = TranscriptionResult(
                        text: transcriptResult.text,
                        segments: tagged,
                        language: transcriptResult.language,
                        origin: transcriptResult.origin)
                    let distinct = Set(tagged.compactMap(\.speaker)).count
                    Log.info("Diarization applied",
                             component: "Diarize",
                             context: [("guid", guid), ("show", showSlug),
                                        ("speakerSpans", "\(speakers.count)"),
                                        ("distinctSpeakers", "\(distinct)"),
                                        ("seconds", String(format: "%.1f", Date().timeIntervalSince(diarizeStart)))])
                } catch {
                    // Graceful fallback — log and keep the speaker-free segments.
                    Log.error("Pipeline: diarization failed — writing speaker-free transcript",
                              component: "Diarize",
                              context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
                }
            }

            // ── Library write (transcription path) ───────────────────────
            let transcriptURL: URL
            do {
                let refreshed = (try? store.episode(guid: guid)) ?? episode
                transcriptURL = try await libraryWriter.write(
                    episode: refreshed,
                    transcript: transcriptResult,
                    ocrText: nil,
                    mediaPath: mediaURL
                )
            } catch let err as PipelineError {
                return await handlePipelineError(err, guid: guid, phase: "library")
            } catch {
                return await handlePipelineError(.permanent(error.localizedDescription),
                                                  guid: guid, phase: "library")
            }

            // ── Done ─────────────────────────────────────────────────────
            emitProgress(guid: guid, showSlug: showSlug,
                         phase: "transcribing", fraction: Self.transcribeFractionEnd)
            do {
                try setStatusEmitting(guid, .done, transcriptPath: transcriptURL.path,
                                      transcriptOrigin: transcriptResult.origin?.storageString)
            } catch {
                // The transcript file is on disk but persisting `.done` failed
                // (e.g. a transient DB lock). Do NOT report success — that would
                // strand the row in `transcribing` forever (never re-claimed,
                // file orphaned). Route to a retryable transient failure instead.
                return await handlePipelineError(
                    .transient("finalize: \(error.localizedDescription)"),
                    guid: guid, phase: "finalize")
            }
            Log.info("Episode done (transcribe path)",
                     component: "Pipeline",
                     context: [("guid", guid), ("show", showSlug),
                                ("origin", transcriptResult.origin?.storageString ?? "unknown")])

            // ── Full-text search index (write hook) ──────────────────────
            // Index the finished transcript so it's searchable in the Library.
            // Uses the in-memory plain text we already have (no re-read of the
            // file just written). The SRT-derived plain text matches what the
            // markdown body shows; fall back to the raw engine text if no
            // segments produced SRT. Best-effort — never fail a done episode.
            let refreshedForIndex = (try? store.episode(guid: guid)) ?? episode
            let srtForIndex = transcriptResult.segments.isEmpty
                ? ""
                : WhisperKitTranscriptionEngine.buildSRT(segments: transcriptResult.segments)
            let plainForIndex = srtForIndex.isEmpty
                ? transcriptResult.text
                : TranscriptFormat.srtToPlainText(srtForIndex)
            indexTranscriptForSearch(guid: guid, showSlug: showSlug,
                                     title: refreshedForIndex.title, content: plainForIndex)

            return PipelineResult(guid: guid, finalStatus: .done,
                                  transcriptPath: transcriptURL.path)
        }
    }

    // MARK: - Full-text search indexing (write hook)

    /// Upserts a finished transcript into the `transcripts_fts` index. Best-effort:
    /// a failure is logged (repo log-completeness rule: index upsert failures) and
    /// swallowed so it never fails an otherwise-complete episode — the one-time
    /// backfill sweep re-indexes anything a transient failure here skipped.
    private func indexTranscriptForSearch(guid: String, showSlug: String, title: String, content: String) {
        do {
            try store.indexTranscript(guid: guid, showSlug: showSlug, title: title, content: content)
            Log.debug("Pipeline: indexed transcript for search",
                      component: "Pipeline",
                      context: [("guid", guid), ("show", showSlug), ("chars", "\(content.count)")])
        } catch {
            Log.error("Pipeline: transcript FTS index upsert failed (search may miss this episode)",
                      component: "Pipeline",
                      context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
        }
    }

    // MARK: - Proper-noun correction glue

    /// Builds the per-episode ``EpisodeGlossary`` from the episode + show
    /// metadata, and the matching ``TranscriptionContext`` (prompt-biasing seam)
    /// to thread into `transcribe(...)`. Kept as one place so the transcribe call
    /// and the post-ASR corrector are built from the exact same glossary.
    ///
    /// `level` gates the AUTO-glossary's prompt bias: when `.off`,
    /// `context.glossary` is empty and the auto-terms are excluded from
    /// `context.prompt` — WhisperKit's decoder gets no glossary bias at all,
    /// matching the post-ASR corrector (already gated by `.off` at the call
    /// site). The show's MANUAL `whisperPrompt` is an independent, always-on
    /// feature (Settings has no toggle for it) and is merged into
    /// `context.prompt` regardless of `level`.
    ///
    /// NB: the returned `EpisodeGlossary` (used for the post-ASR corrector) is
    /// always the full glossary — the corrector's own `.off` gate (at the call
    /// site) is what no-ops it; this function only decides what the ASR
    /// PROMPT sees.
    static func buildCorrection(
        episode: Episode,
        show: Show?,
        language: String?,
        level: TranscriptGlossaryCorrector.Level
    ) -> (glossary: EpisodeGlossary, context: TranscriptionContext) {
        let whisperPrompt = show?.whisperPrompt ?? ""
        let glossary = EpisodeGlossary.build(
            title: episode.title,
            description: episode.description,
            showName: show?.displayName ?? episode.showSlug,
            author: show?.author,
            whisperPrompt: whisperPrompt
        )
        // Auto-glossary terms are excluded entirely when correction is `.off` —
        // no glossary in the context, and none of its terms leak into the
        // prompt string either.
        let terms = level == .off ? [] : glossary.terms.map(\.text)
        // Merge the free-text Whisper prompt (always) with the auto-glossary
        // terms (only when not `.off`) for the decoder bias. Compacted so an
        // empty prompt/empty glossary yields nil.
        let promptParts = [whisperPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                           terms.joined(separator: ", ")]
            .filter { !$0.isEmpty }
        let prompt = promptParts.isEmpty ? nil : promptParts.joined(separator: ". ")
        let context = TranscriptionContext(prompt: prompt, glossary: terms, language: language)
        return (glossary, context)
    }

    /// Runs the glossary corrector over `segments` when `level != .off`, logging
    /// each replacement (log-completeness rule). Returns the (possibly) rewritten
    /// segments; a no-op passthrough when correction is off or the glossary/segs
    /// are empty. `level` is resolved from `Settings.properNounCorrection`,
    /// defaulting to `.conservative` on an unknown value.
    private func correctedSegments(
        _ segments: [TranscriptionSegment],
        glossary: EpisodeGlossary,
        level: TranscriptGlossaryCorrector.Level,
        guid: String,
        showSlug: String
    ) -> [TranscriptionSegment] {
        guard level != .off, !segments.isEmpty, !glossary.terms.isEmpty else { return segments }
        var count = 0
        let corrected = TranscriptGlossaryCorrector(level: level).correct(
            segments, glossary: glossary
        ) { from, to in
            count += 1
            Log.info("'\(from)' → '\(to)'",
                     component: "Correct",
                     context: [("guid", guid), ("show", showSlug),
                               ("from", from), ("to", to)])
        }
        if count > 0 {
            Log.info("Proper-noun correction applied",
                     component: "Correct",
                     context: [("guid", guid), ("show", showSlug),
                               ("replacements", "\(count)"), ("level", level.rawValue)])
        }
        return corrected
    }

    // MARK: - Helpers

    /// Emits an `episode.skipped` event via the bus with a reason payload.
    /// Routed through the ordered emitter (L3) so it can't overtake the progress
    /// events emitted for the same episode just before it.
    private func emitSkippedEvent(guid: String, showSlug: String, reason: String) {
        guard let emitter else { return }
        let event = Event(
            type: EventType.episodeSkipped,
            showSlug: showSlug,
            guid: guid,
            payload: ["reason": .string(reason)]
        )
        emitter.emit(event)
    }

    // MARK: - Error handling

    /// Translates a `PipelineError` into a terminal `PipelineResult`, recording
    /// the failure in the DB.
    private func handlePipelineError(
        _ err: PipelineError,
        guid: String,
        phase: String
    ) async -> PipelineResult {
        switch err {
        case .skipped(let reason):
            Log.info("Episode skipped",
                     component: "Pipeline",
                     context: [("guid", guid), ("phase", phase), ("reason", reason)])
            do { try store.setStatus(guid: guid, .skipped) } catch {
                Log.error("Pipeline: skipped-status write failed",
                          component: "Pipeline",
                          context: [("guid", guid), ("phase", phase), ("error", "\(error)")])
            }
            return PipelineResult(guid: guid, finalStatus: .skipped)

        case .cancelled(let reason):
            // Stop / hard-pause / worker teardown during download or transcribe.
            // This is neither a failure nor a success: reset the row to `pending`
            // (its pre-step state — the download `.part`/model cache is preserved
            // for resume) WITHOUT bumping `attempts` and WITHOUT recording a
            // failure. The episode is simply re-queued for the next drain.
            Log.info("Pipeline: step cancelled — episode requeued",
                     component: "Pipeline",
                     context: [("guid", guid), ("phase", phase), ("reason", reason)])
            do {
                try store.setStatus(guid: guid, .pending)
                // Cancellation is NOT a failure, so it must not incur the M1 retry
                // backoff — a user Stop→Start (or a mode switch) should re-claim
                // this episode immediately. Clear the recent `attempted_at` the
                // claim/`.transcribing` transition stamped so it is instantly
                // eligible again (a genuine transient FAILURE keeps its
                // `attempted_at` and is correctly held back).
                try store.clearAttemptedAt(guid: guid)
            } catch {
                Log.error("Pipeline: cancel requeue write failed",
                          component: "Pipeline",
                          context: [("guid", guid), ("phase", phase), ("error", "\(error)")])
            }
            return PipelineResult(guid: guid, finalStatus: .pending)

        case .diskFull(let msg):
            // M12: the disk filled mid-download. This is NOT a per-episode fault —
            // requeue the episode exactly like a cancellation (reset to `pending`,
            // clear the recent `attempted_at` so it's instantly re-claimable once
            // space is freed, do NOT burn an attempt, do NOT record a failure). The
            // preserved `.part` + `.meta` let the next attempt resume. Then emit a
            // `queueDiskFull` event so the UI pauses the whole queue + raises the
            // low-disk banner (draining a big backlog would only fill the disk
            // further). A permanent `failed` here (the old behaviour) was wrong and
            // unrecoverable.
            Log.warn("Pipeline: disk full — episode requeued, pausing queue",
                     component: "Pipeline",
                     context: [("guid", guid), ("phase", phase), ("msg", msg)])
            do {
                try store.setStatus(guid: guid, .pending)
                try store.clearAttemptedAt(guid: guid)
            } catch {
                Log.error("Pipeline: disk-full requeue write failed",
                          component: "Pipeline",
                          context: [("guid", guid), ("phase", phase), ("error", "\(error)")])
            }
            emitter?.emit(Event(type: EventType.queueDiskFull, guid: guid))
            return PipelineResult(guid: guid, finalStatus: .pending)

        case .permanent(let msg):
            let errorText = "[\(phase)] permanent: \(msg)"
            Log.error("Episode permanent failure",
                      component: "Pipeline",
                      context: [("guid", guid), ("phase", phase), ("msg", msg)])
            do {
                try store.recordFailure(
                    guid: guid,
                    errorText: errorText,
                    errorCategory: ErrorCategory.classify(phase: phase, message: msg),
                    retry: false
                )
            } catch {
                // The failure bookkeeping itself failed (DB busy). Log it — an
                // invisible swallow here means the episode stays in its in-flight
                // status with no record of why, and the UI shows a phantom.
                Log.error("Pipeline: recordFailure(permanent) write failed",
                          component: "Pipeline",
                          context: [("guid", guid), ("phase", phase), ("error", "\(error)")])
            }
            return PipelineResult(guid: guid, finalStatus: .failed)

        case .transient(let msg):
            let errorText = "[\(phase)] transient: \(msg)"
            let currentAttempts = (try? store.episode(guid: guid))?.attempts ?? 0
            // Post-increment: after bumping, the new attempts count will be currentAttempts + 1.
            // Should retry when newAttempts < maxAttempts (i.e. still under the cap).
            let attemptsAfterBump = currentAttempts + 1
            let shouldRetry = attemptsAfterBump < Self.maxAttempts
            Log.warn("Episode transient failure",
                     component: "Pipeline",
                     context: [("guid", guid), ("phase", phase), ("msg", msg),
                                ("attempt", "\(attemptsAfterBump)/\(Self.maxAttempts)"),
                                ("retry", "\(shouldRetry)")])
            do {
                try store.recordFailure(
                    guid: guid,
                    errorText: errorText,
                    errorCategory: ErrorCategory.network,
                    retry: shouldRetry
                )
            } catch {
                Log.error("Pipeline: recordFailure(transient) write failed",
                          component: "Pipeline",
                          context: [("guid", guid), ("phase", phase), ("error", "\(error)")])
            }
            let finalStatus: EpisodeStatus = shouldRetry ? .pending : .failed
            return PipelineResult(guid: guid, finalStatus: finalStatus)
        }
    }

    /// Records a transcribe-phase failure with a **one-retry cap**: the first
    /// failure retries (→ `pending`), the second fails the episode (→ `failed`).
    /// Used for both engine errors (model load, decode) and empty transcripts, so
    /// a transient glitch auto-retries once instead of needing a manual re-run,
    /// but a persistent problem still fails rather than looping.
    private func transcribeRetryOnceOrFail(guid: String, showSlug: String, reason: String) -> PipelineResult {
        let attempts = (try? store.episode(guid: guid))?.attempts ?? 0
        let willRetry = (attempts + 1) < 2   // original attempt + one retry
        Log.warn("Transcription failure — \(willRetry ? "will retry" : "failing")",
                 component: "Pipeline",
                 context: [("guid", guid), ("show", showSlug),
                            ("attempt", "\(attempts + 1)/2"), ("reason", reason)])
        do {
            try store.recordFailure(
                guid: guid,
                errorText: "[transcribe] \(reason)",
                errorCategory: ErrorCategory.classify(phase: "transcribe", message: reason),
                retry: willRetry
            )
        } catch {
            Log.error("Pipeline: recordFailure(transcribe) write failed",
                      component: "Pipeline",
                      context: [("guid", guid), ("show", showSlug), ("error", "\(error)")])
        }
        return PipelineResult(guid: guid, finalStatus: willRetry ? .pending : .failed)
    }

    // MARK: - Route detection

    /// Returns `true` when the episode should take the OCR path instead of
    /// the audio-transcription path.
    ///
    /// OCR route triggers when:
    /// - `mediaType == "image"`, OR
    /// - `igKind == "post"` (Instagram image post), OR
    /// - `igKind == "story"` without explicit video media type
    ///
    /// Everything else (podcast, YouTube, IG reels/videos) takes the audio path.
    /// Whether `episode` takes the image/OCR route (vs the audio/transcribe route).
    ///
    /// Per the Instagram spec: reels + video-stories → whisper; image-posts +
    /// image-stories → OCR. Decision order:
    /// - explicit `mediaType == "video"` → transcribe (false)
    /// - explicit `mediaType == "image"` → OCR (true)
    /// - otherwise, an Instagram `post` or `story` defaults to the OCR route
    ///   (posts/carousels are images; a story with no explicit video marker is
    ///   treated as an image story). A `reel` (or anything else) → transcribe.
    public static func isImagePost(_ episode: Episode) -> Bool {
        if episode.mediaType == "video" { return false }
        if episode.mediaType == "image" { return true }
        if let kind = episode.igKind, kind == "post" || kind == "story" { return true }
        return false
    }
}
