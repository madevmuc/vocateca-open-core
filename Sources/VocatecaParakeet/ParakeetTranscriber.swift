// Model: parakeet-tdt-0.6b-v3 — © NVIDIA, licensed CC-BY-4.0.
// Runtime: FluidAudio (CoreML ASR runtime) — licensed Apache-2.0.
// Attribution surfaced to users in AboutSheet's acknowledgements list.

import Foundation
@preconcurrency import AVFoundation
import VocatecaCore
import FluidAudio

// MARK: - ParakeetTranscriber

/// A ``Transcriber`` backed by parakeet-tdt-0.6b-v3 via FluidAudio (CoreML/ANE).
///
/// Isolated in its own module (`VocatecaParakeet`) so the CoreML model graph
/// stays out of `VocatecaCore` and its fast unit-test suite. Runs on the Apple
/// Neural Engine — orthogonal to WhisperKit (ANE) and Qwen (GPU).
///
/// ## Notes / limits
/// - `AsrManager` is itself a `public actor` and `Sendable`, so — unlike
///   Qwen's non-Sendable model — it can be stored directly and awaited across
///   isolation. We still coalesce the first load so concurrent callers don't
///   trigger a second multi-hundred-MB download.
/// - The base `transcribe` returns text + FluidAudio's per-utterance
///   `confidence`. Per-token timings (`result.tokenTimings`) are reassembled
///   into words (`ParakeetWordAssembly`) and grouped into subtitle-sized cues
///   (`ParakeetCueGrouping`); a single whole-file segment is used as a
///   fallback when timings are absent or too sparse. The caller's language
///   hint is carried through to the result's `language` field for downstream
///   display.
/// - The caller's BCP-47 `language` hint is mapped to FluidAudio's `Language`
///   enum and passed through for v3's script-aware token filtering; an
///   unmapped/unknown hint passes `nil` (auto-detect).
public actor ParakeetTranscriber: Transcriber {

    /// FluidAudio's native model sample rate.
    private static let modelSampleRate = 16000.0

    /// Short model tag recorded in ``TranscriptOrigin`` (e.g. "tdt-0.6b-v3").
    private let modelTag: String

    // Lazy, coalesced model load. `AsrManager` is Sendable, so — unlike
    // Qwen's non-Sendable model — it may safely cross isolation, but we still
    // coalesce concurrent first-use loads to avoid a second parallel download.
    private var asr: AsrManager?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

    public init(modelTag: String = "tdt-0.6b-v3") {
        self.modelTag = modelTag
    }

    /// FluidAudio's per-utterance confidence for the last transcription, exposed
    /// so the routing layer can gate on it. Set on each `transcribe`.
    public private(set) var lastConfidence: Double?

    // MARK: - Transcriber

    /// `true` once `loadedManager(progress:)` has cached an `AsrManager` — i.e.
    /// the model has already been downloaded (if needed) and loaded. A cheap
    /// actor-state read; never triggers I/O.
    public var isWarm: Bool { asr != nil }

    public func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, progress: { _ in })
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        progress: @escaping ProgressReporter
    ) async throws -> TranscriptionResult {
        // 1. Decode audio → 16 kHz mono Float PCM.
        let samples = try Self.decodeMonoSamples(url: audioURL, sampleRate: Self.modelSampleRate)
        progress(0.05)
        try Task.checkCancellation()

        // Empty / zero-length audio (corrupt or silent file): nothing to
        // transcribe. Return an empty result rather than feeding an empty
        // buffer to the model or downloading it for nothing.
        guard !samples.isEmpty else {
            progress(1.0)
            lastConfidence = nil
            return TranscriptionResult(
                text: "",
                segments: [],
                language: language,
                origin: .asr(engine: "parakeet", model: modelTag)
            )
        }

        // 2. Lazy-load the model (downloads on first use), mapping its 0–1
        //    download/load progress into our 0.05–0.55 band.
        let manager = try await loadedManager { frac in
            progress(0.05 + max(0, min(1, frac)) * 0.50)
        }
        try Task.checkCancellation()
        progress(0.6)

        // 3. Transcribe. A fresh decoder state per call is fine — whole-file
        //    batch transcription has no cross-chunk continuity to preserve.
        var state = try TdtDecoderState()
        let fluidLang = Self.fluidLanguage(from: language)
        let result = try await manager.transcribe(samples, decoderState: &state, language: fluidLang)
        lastConfidence = Double(result.confidence)
        progress(0.98)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationSec = Double(samples.count) / Self.modelSampleRate
        // Reconstruct words from per-token timings (SentencePiece `▁`
        // boundaries; FluidAudio's own word-builder is unreachable across
        // the module boundary — see ParakeetWordAssembly), then group into
        // subtitle-sized cues. Falls back to one whole-file segment when
        // token timings are absent or too sparse to produce usable cues.
        var segments: [TranscriptionSegment] = []
        if !text.isEmpty {
            let words = ParakeetWordAssembly.words(from: result.tokenTimings ?? [])
            segments = ParakeetCueGrouping.segments(fromWords: words)
                ?? [TranscriptionSegment(start: 0, end: durationSec, text: text)]
        }

        progress(1.0)
        return TranscriptionResult(
            text: text,
            segments: segments,
            language: language,
            origin: .asr(engine: "parakeet", model: modelTag)
        )
    }

    // MARK: - Language mapping

    /// Maps a caller's BCP-47 hint (e.g. `"de-DE"`, `"EN"`) to FluidAudio's
    /// `Language` enum for v3's script-aware token filtering. Returns `nil`
    /// (auto-detect) when the hint is absent or not one of FluidAudio's
    /// currently-mapped cases — the joint decoder still works, it just skips
    /// the language-conditioned top-K filtering.
    static func fluidLanguage(from bcp47: String?) -> Language? {
        guard let raw = bcp47?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let base = raw.split(separator: "-").first.map { $0.lowercased() } ?? raw.lowercased()
        return Language(rawValue: base)
    }

    // MARK: - Model loading

    /// Lazily loads (and coalesces concurrent first-use loads of) the FluidAudio
    /// ASR manager. `AsrManager` is `Sendable`, so — unlike Qwen's non-Sendable
    /// model — the manager itself may safely be returned across isolation;
    /// only the coalescing continuations need the same care as `QwenTranscriber`.
    private func loadedManager(progress: @escaping @Sendable (Double) -> Void) async throws -> AsrManager {
        if let asr { return asr }

        if isLoading {
            try await withCheckedThrowingContinuation { loadWaiters.append($0) }
            if let asr { return asr }
            throw ParakeetTranscriberError.modelLoad("load finished without a manager")
        }

        isLoading = true
        let loadStart = Date()
        do {
            progress(0.0)
            // M-3 groundwork: FluidAudio's `downloadAndLoad(version:)` resolves
            // a hardcoded `resolve/main/` path with no revision override and
            // returns no resolved-commit field — see the upstream-blocked TODO
            // in `ModelPins.swift`. Logging the version tag is the closest
            // honest provenance signal available today.
            //
            // H6: bound the multi-hundred-MB download+load. Neither
            // `downloadAndLoad` nor `loadModels` has a timeout; a stalled first
            // download would otherwise hang the episode in `transcribing`
            // forever. `AsrManager` is Sendable, so it returns cleanly out of the
            // `withTimeout` race. On timeout a bare `TimeoutError` propagates so
            // the pipeline classifies it as TRANSIENT (retryable).
            let manager = try await withTimeout(seconds: modelLoadTimeoutSeconds) {
                let models = try await AsrModels.downloadAndLoad(version: .v3) { downloadProgress in
                    progress(downloadProgress.fractionCompleted)
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            self.asr = manager
            isLoading = false
            let waiters = loadWaiters; loadWaiters.removeAll()
            for w in waiters { w.resume() }
            Log.info("ParakeetTranscriber: model loaded", component: "ParakeetTranscriber",
                     context: [("version", "v3"), ("revisionPin", "none (M-3 upstream-blocked)"),
                               ("seconds", String(format: "%.1f", Date().timeIntervalSince(loadStart)))])
            progress(1.0)
            return manager
        } catch let timeout as TimeoutError {
            // H6: transient — surface a bare TimeoutError so the pipeline requeues
            // (LanguageRoutingTranscriber also falls back to Whisper on this run).
            Log.error("ParakeetTranscriber: model load TIMED OUT — requeue (transient)",
                      component: "ParakeetTranscriber",
                      context: [("version", "v3"),
                                ("elapsedSec", String(format: "%.0f", Date().timeIntervalSince(loadStart))),
                                ("timeoutSec", String(format: "%.0f", timeout.seconds))])
            isLoading = false
            let waiters = loadWaiters; loadWaiters.removeAll()
            for w in waiters { w.resume(throwing: timeout) }
            throw timeout
        } catch {
            isLoading = false
            let waiters = loadWaiters; loadWaiters.removeAll()
            for w in waiters { w.resume(throwing: error) }
            throw error
        }
    }

    // MARK: - Audio decoding

    /// Decodes any AVFoundation-readable audio file into mono Float PCM at
    /// `sampleRate`, resampling/downmixing as needed. Returns `[]` for a
    /// zero-length file rather than throwing.
    static func decodeMonoSamples(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ParakeetTranscriberError.audioFormat("cannot build 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw ParakeetTranscriberError.audioFormat("cannot build audio converter")
        }

        let srcFrames = AVAudioFrameCount(file.length)
        guard srcFrames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcFrames) else {
            return []
        }
        try file.read(into: inBuf)

        // Output capacity scaled by the resample ratio (+ headroom).
        let ratio = sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(srcFrames) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw ParakeetTranscriberError.audioFormat("cannot allocate output buffer")
        }

        // One-shot: the whole file is already in `inBuf`, so feed it once then
        // report end-of-stream. A reference flag avoids a captured-var mutation
        // in the (nominally @Sendable) input block.
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if once.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if let convErr { throw convErr }
        guard status != .error, let ch = outBuf.floatChannelData else {
            throw ParakeetTranscriberError.audioFormat("audio conversion failed")
        }
        let n = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}

// MARK: - Errors

public enum ParakeetTranscriberError: Error, CustomStringConvertible {
    case audioFormat(String)
    case modelLoad(String)
    public var description: String {
        switch self {
        case .audioFormat(let m): return "ParakeetTranscriber audio error: \(m)"
        case .modelLoad(let m): return "ParakeetTranscriber model error: \(m)"
        }
    }
}
