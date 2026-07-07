import Foundation
import VocatecaCore
import VocatecaQwen
import VocatecaParakeet

// MARK: - Shared engine wiring + in-process drain

/// Builds the live pipeline engines and drives a `QueueRunner` to completion,
/// headlessly. This replicates `QueueController.init`'s engine wiring exactly
/// (downloader + yt-dlp audio hook, OCR, markdown writer with export roots +
/// srt/txt/html gates, and the transcriber resolved via `EngineSelector`) so
/// `queue run` / `transcribe --start` use the same engines as the app.
@MainActor
enum QueueDrive {

    struct Engines {
        let downloader: URLSessionDownloader
        let transcriber: any Transcriber
        let ocrProcessor: InstagramImageOCRProcessor
        let libraryWriter: MarkdownLibraryWriter
        let queueOrder: String
        /// Speaker-diarization engine (Package D), forwarded to `QueueRunner.start`
        /// → `Pipeline` so `queue run` / `transcribe --start` diarize like the app
        /// (gated at run time by `settings.diarizationEnabled`).
        let diarizer: any VocatecaCore.Diarizer
    }

    /// Construct the live engines from the current settings. When `enginePref`
    /// is supplied it overrides `settings.transcriptionEngine` (used by
    /// `transcribe --engine …`).
    static func buildEngines(enginePref override: TranscriptionEngine? = nil) -> Engines {
        let loaded = try? SettingsStore.load(from: Paths.settingsURL, persistDefaultOnMissing: false)
        let mediaDir = Paths.userDataDir().appendingPathComponent("media", isDirectory: true)

        let saveSrt  = loaded?.saveSrt ?? true
        let saveTxt  = loaded?.saveTxt ?? false
        let saveHtml = loaded?.saveHtml ?? false
        let exportRoots = loaded.map {
            KnowledgeHub.exportRoots(
                exportRoot: $0.exportRoot,
                obsidianVaultPath: $0.obsidianVaultPath,
                obsidianVaultName: $0.obsidianVaultName,
                knowledgeHubRoot: $0.knowledgeHubRoot)
        } ?? []

        let whisper = WhisperKitTranscriber(
            model: WhisperKitTranscriber.whisperKitModelID(from: loaded?.whisperModel ?? ""))
        let enginePref = override ?? (TranscriptionEngine(rawValue: loaded?.transcriptionEngine ?? "auto") ?? .auto)
        let resolvedEngine = EngineSelector.resolveLive(preference: enginePref)

        // Package C: the backup engine is user-configurable (`fallback_engine`)
        // instead of hardcoded Whisper. `resolveFallbackLive` returns `nil` when the
        // configured backup resolves to the same concrete engine as the primary —
        // "no distinct fallback" — in which case we keep Whisper as the universal
        // safety net (it covers every language and never needs Apple Silicon).
        let fallbackPref = TranscriptionEngine(rawValue: loaded?.fallbackEngine ?? "whisper") ?? .whisper
        let resolvedFallback = EngineSelector.resolveFallbackLive(
            primaryPreference: enginePref, fallbackPreference: fallbackPref)
        let fallback = Self.makeFallbackTranscriber(
            resolvedFallback ?? .whisper, whisper: whisper, settings: loaded)

        let transcriber: any Transcriber
        switch resolvedEngine {
        case .qwen:
            let qwen = QwenTranscriber(
                modelId: QwenTranscriber.modelId(forVariant: loaded?.qwenModel ?? "1.7B-8bit"),
                forcedAlign: loaded?.qwenForcedAlign ?? true)
            transcriber = FallbackTranscriber(primary: qwen, fallback: fallback)
        case .whisper:
            transcriber = whisper
        case .parakeet:
            let parakeet = ParakeetTranscriber()
            transcriber = LanguageRoutingTranscriber(
                parakeet: parakeet,
                whisper: fallback,
                confidenceProvider: { await parakeet.lastConfidence })
        }

        return Engines(
            downloader: URLSessionDownloader(
                mediaDir: mediaDir,
                youtubeAudioHook: YtDlpAudioHook.make(mediaDir: mediaDir)),
            transcriber: transcriber,
            ocrProcessor: InstagramImageOCRProcessor(),
            libraryWriter: MarkdownLibraryWriter(
                outputRoot: Paths.userDataDir(), writeSRT: saveSrt,
                writeTXT: saveTxt, writeHTML: saveHtml, exportRoots: exportRoots),
            queueOrder: loaded?.queueOrder ?? "oldest_first",
            // Package D: the CLI diarizes like the app (I/O-free to construct;
            // models download lazily on first use; gated by diarizationEnabled).
            diarizer: FluidAudioDiarizer())
    }

    /// Builds the concrete **backup** transcriber for a resolved engine (Package C).
    /// `whisper` is passed in (already constructed once) so the common
    /// backup-is-Whisper case reuses it; Qwen/Parakeet are built on demand from
    /// `settings`. Never wraps the result in a fallback wrapper — this IS the
    /// fallback, so it must be a bare engine.
    private static func makeFallbackTranscriber(
        _ engine: ResolvedEngine, whisper: WhisperKitTranscriber, settings: Settings?
    ) -> any Transcriber {
        switch engine {
        case .whisper:
            return whisper
        case .qwen:
            return QwenTranscriber(
                modelId: QwenTranscriber.modelId(forVariant: settings?.qwenModel ?? "1.7B-8bit"),
                forcedAlign: settings?.qwenForcedAlign ?? true)
        case .parakeet:
            return ParakeetTranscriber()
        }
    }

    /// Result summary of a drain.
    struct DrainSummary { var processed: Int; var done: Int; var failed: Int }

    /// Drive a headless drain to completion.
    ///
    /// - Parameters:
    ///   - store: The read-write state store.
    ///   - restrictToSlugs: Optional slug allowlist (nil = any pending episode).
    ///   - stopWhenGuidDone: If set, stop as soon as this guid leaves the active
    ///     set (used by `transcribe --start` to block on one episode).
    ///   - maxEpisodes: Stop after this many episodes reach a terminal status (0 = no cap).
    ///   - streamProgress: When true, prints per-episode status transitions to stdout.
    static func drain(
        store: StateStore,
        restrictToSlugs: [String]?,
        stopWhenGuidDone: String? = nil,
        maxEpisodes: Int = 0,
        enginePref: TranscriptionEngine? = nil,
        streamProgress: Bool
    ) async -> DrainSummary {
        let runner = QueueRunner()
        let engines = buildEngines(enginePref: enginePref)
        runner.load(from: store)

        // Snapshot the terminal counts before the run so we can compute deltas.
        let terminalStatuses: Set<String> = ["done", "failed", "skipped", "deferred", "deleted"]
        func terminalCounts() -> (done: Int, failed: Int, terminalGuids: Set<String>) {
            let all = (try? store.allEpisodes()) ?? []
            let done = all.filter { $0.status == "done" }.count
            let failed = all.filter { $0.status == "failed" }.count
            let tg = Set(all.filter { terminalStatuses.contains($0.status) }.map { $0.guid })
            return (done, failed, tg)
        }
        let before = terminalCounts()

        // Track live status for streaming + stop conditions.
        var lastStatusByGuid: [String: String] = [:]
        var newlyTerminal = Set<String>()

        await withCheckedContinuation { @MainActor (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            let finishOnce: @MainActor () -> Void = {
                guard !finished else { return }
                finished = true
                runner.stop()
                cont.resume()
            }

            runner.onItemsChanged = {
                for item in runner.items {
                    let prev = lastStatusByGuid[item.id]
                    if prev != item.statusRaw {
                        lastStatusByGuid[item.id] = item.statusRaw
                        if streamProgress {
                            print("[\(item.statusRaw)] \(item.showSlug) — \(item.title)")
                        }
                    }
                }
                // Detect episodes that left the active set (went terminal).
                let now = terminalCounts()
                let fresh = now.terminalGuids.subtracting(before.terminalGuids)
                newlyTerminal = fresh
                if let target = stopWhenGuidDone, fresh.contains(target) {
                    finishOnce()
                    return
                }
                if maxEpisodes > 0 && fresh.count >= maxEpisodes {
                    finishOnce()
                    return
                }
            }
            runner.onRunStateChanged = {
                // Natural drain: the runner transitions back to .stopped when the
                // queue empties (run.finished).
                if runner.runState == .stopped {
                    finishOnce()
                }
            }

            // M12: unattended CLI drains get the same pre-claim disk guard as the
            // app — stop claiming before free space drops below the floor rather
            // than filling the disk and failing episodes. Re-reads settings each
            // call so a mid-run change is honoured; fail-open on a stat/load error.
            let mediaPath = Paths.userDataDir()
                .appendingPathComponent("media", isDirectory: true).path
            let diskGuard: @Sendable () -> Bool = {
                let loaded = try? SettingsStore.load(from: Paths.settingsURL, persistDefaultOnMissing: false)
                let enabled = loaded?.diskGuardEnabled ?? Settings.defaultDiskGuardEnabled
                let minGb = loaded?.diskGuardMinFreeGb ?? Settings.defaultDiskGuardMinFreeGb
                return DiskGuard.shouldPause(pathToCheck: mediaPath, minFreeGb: minGb, enabled: enabled)
            }

            runner.start(
                store: store,
                downloader: engines.downloader,
                transcriber: engines.transcriber,
                ocrProcessor: engines.ocrProcessor,
                libraryWriter: engines.libraryWriter,
                queueOrder: engines.queueOrder,
                restrictToSlugs: restrictToSlugs,
                diskSpaceFull: diskGuard,
                diarizer: engines.diarizer)
        }

        let after = terminalCounts()
        return DrainSummary(
            processed: newlyTerminal.count,
            done: max(0, after.done - before.done),
            failed: max(0, after.failed - before.failed))
    }
}
