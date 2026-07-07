import Foundation
@preconcurrency import AVFoundation
import VocatecaCore
import Qwen3ASR
import AudioCommon   // AlignedWord

// MARK: - Sendable model box (H6)

/// `Qwen3ASRModel` is non-Sendable, so it cannot cross the task-group boundary
/// that `withTimeout` (Core) uses to bound the load. This wrapper lets the
/// loaded model be handed back out of the timeout race. It is `@unchecked
/// Sendable` by construction: the boxed model is created inside the load closure
/// and immediately assigned to the owning actor's isolated `model` state — it is
/// never touched concurrently, mirroring `WhisperKitBox`.
private final class QwenModelBox: @unchecked Sendable {
    let model: Qwen3ASRModel
    init(_ model: Qwen3ASRModel) { self.model = model }
}

// MARK: - QwenTranscriber

/// A ``Transcriber`` backed by the Qwen3-ASR MLX model (soniqo/speech-swift).
///
/// Isolated in its own module (`VocatecaQwen`) so the heavy MLX / speech-swift
/// dependency stays out of `VocatecaCore` and its fast unit-test suite. Only the
/// app target links this; `QueueController` constructs it when
/// ``EngineSelector`` resolves to ``ResolvedEngine/qwen`` and falls back to
/// WhisperKit if the model fails to load.
///
/// ## Notes / limits
/// - The model loads lazily on the first `transcribe` (downloads
///   `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` on first use; the bf16 `mlx-community`
///   bundle is a different, incompatible quantization).
/// - The base `transcribe` API returns **text only** — no per-segment timestamps
///   and no detected-language. We emit a single whole-file segment and carry the
///   caller's language hint. (Word timestamps would need `Qwen3ForcedAligner`.)
/// - `noSpeechProb` / `avgLogprob` are Whisper-specific → left `nil`;
///   `NoSpeechDetector` already degrades to its text/WPM heuristics.
public actor QwenTranscriber: Transcriber {

    /// WhisperKit-style sample rate the model consumes.
    private static let modelSampleRate = 16000.0

    private let modelId: String
    /// Short model tag recorded in ``TranscriptOrigin`` (e.g. "1.7B-8bit").
    private let modelTag: String
    private var model: Qwen3ASRModel?
    /// True while the one-time model load/download is in flight. Concurrent
    /// callers that arrive during the load park on `loadWaiters` instead of
    /// starting a second multi-GB download (actor isolation is released at the
    /// `await` inside the load, so without this a second caller would pass the
    /// `model == nil` check and download again). `Qwen3ASRModel` is non-Sendable,
    /// so the model itself is loaded by a direct `await` in the actor and never
    /// crosses an isolation boundary; only `Void` continuations do.
    private var isLoadingModel = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

    /// When true, run the Qwen3 forced aligner after transcription to produce
    /// real per-word timestamps (grouped into subtitle cues → proper .srt). When
    /// false — or on any aligner load/run failure — keep the single whole-file
    /// segment. Downloads a separate ~0.6B model on first aligned run.
    private let forcedAlign: Bool
    private let alignerModelId: String
    /// Lazily-loaded forced aligner (non-Sendable; loaded and used entirely
    /// inside the actor, mirroring `model`).
    private var aligner: Qwen3ForcedAligner?
    private var isLoadingAligner = false
    private var alignerLoadWaiters: [CheckedContinuation<Void, Error>] = []

    /// - Parameters:
    ///   - modelId: HuggingFace id of a speech-swift-compatible Qwen3-ASR bundle.
    ///     Defaults to the 1.7B 8-bit tier (the design's quality tier).
    ///   - forcedAlign: When true, add per-segment timestamps via the Qwen3 forced
    ///     aligner (downloads an extra ~0.6B model on first aligned run).
    ///   - alignerModelId: HuggingFace id of the forced-aligner bundle.
    public init(
        modelId: String = Qwen3ASRModel.largeModelId,
        forcedAlign: Bool = false,
        alignerModelId: String = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
    ) {
        self.modelId = modelId
        self.modelTag = Self.shortTag(for: modelId)
        self.forcedAlign = forcedAlign
        self.alignerModelId = alignerModelId
    }

    /// Maps a Settings variant key ("1.7B-8bit" | "1.7B-4bit" | "0.6B-8bit") to a
    /// speech-swift HuggingFace model id. Unknown → the 1.7B 8-bit default.
    public static func modelId(forVariant variant: String) -> String {
        switch variant {
        case "1.7B-4bit": return "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
        case "0.6B-8bit": return "aufklarer/Qwen3-ASR-0.6B-MLX-8bit"
        case "1.7B-8bit": return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        default:          return Qwen3ASRModel.largeModelId
        }
    }

    // MARK: - Transcriber

    /// `true` once `loadedModel(progress:)` has cached a `Qwen3ASRModel` — i.e.
    /// the model has already been downloaded (if needed) and loaded. A cheap
    /// actor-state read; never triggers I/O. (Deliberately ignores the
    /// separate forced-aligner model: the aligner is a smaller, secondary
    /// download that runs AFTER transcription starts, so it doesn't gate the
    /// "is the FIRST call about to hang" signal this property answers.)
    public var isWarm: Bool { model != nil }

    public func transcribe(audioURL: URL, language: String?) async throws -> VocatecaCore.TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, progress: { _ in })
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VocatecaCore.TranscriptionResult {
        // 1. Decode audio → 16 kHz mono Float PCM.
        let samples = try Self.loadMonoSamples(url: audioURL, sampleRate: Self.modelSampleRate)
        progress(0.05)
        try Task.checkCancellation()

        // Empty / zero-length audio (corrupt or silent file): nothing to
        // transcribe. Return an empty result rather than feeding an empty buffer
        // to the MLX model (undefined behaviour) or downloading the model for it.
        guard !samples.isEmpty else {
            progress(1.0)
            return VocatecaCore.TranscriptionResult(
                text: "",
                segments: [],
                language: language,
                origin: .asr(engine: "qwen3-asr", model: modelTag)
            )
        }

        // 2. Lazy-load the model (downloads on first use), mapping its 0–1
        //    download/load progress into our 0.05–0.55 band.
        let m = try await loadedModel { frac in
            progress(0.05 + max(0, min(1, frac)) * 0.50)
        }
        try Task.checkCancellation()
        progress(0.6)

        // 3. Transcribe (synchronous MLX GPU compute). The base API returns text
        //    only — no timestamps / detected language.
        let raw = m.transcribe(audio: samples, sampleRate: Int(Self.modelSampleRate), language: language)
        progress(0.98)

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationSec = Double(samples.count) / Self.modelSampleRate

        var segments: [VocatecaCore.TranscriptionSegment] = []
        if !text.isEmpty {
            // Prefer real per-word timestamps via the forced aligner (grouped into
            // subtitle cues). Any failure falls back to one whole-file segment so
            // .srt still has a single valid cue.
            if forcedAlign {
                // `try?` flattens the `[Segment]?` return into a single optional.
                if let aligned = try? await alignedSegments(samples: samples, text: text, language: language),
                   !aligned.isEmpty {
                    segments = aligned
                }
            }
            if segments.isEmpty {
                segments = [VocatecaCore.TranscriptionSegment(start: 0, end: durationSec, text: text)]
            }
        }

        progress(1.0)
        return VocatecaCore.TranscriptionResult(
            text: text,
            segments: segments,
            language: language,
            origin: .asr(engine: "qwen3-asr", model: modelTag)
        )
    }

    // MARK: - Forced alignment

    /// Runs the forced aligner on `samples` + `text` and groups the resulting
    /// word timestamps into subtitle cues. Returns `nil` if alignment produced
    /// nothing usable; throws only on an unrecoverable aligner load error.
    private func alignedSegments(
        samples: [Float],
        text: String,
        language: String?
    ) async throws -> [VocatecaCore.TranscriptionSegment]? {
        let a = try await loadedAligner()
        try Task.checkCancellation()
        // Synchronous MLX compute on the actor (like `transcribe`); the
        // non-Sendable aligner never leaves the actor, only the Sendable
        // `[AlignedWord]` result.
        let words = a.alignLong(
            audio: samples,
            text: text,
            sampleRate: Int(Self.modelSampleRate),
            language: Self.alignerLanguageName(from: language)
        )
        return WordCueGrouping.segments(from: words)
    }

    /// Maps a BCP-47 hint (or nil) to the full language name the aligner's word
    /// splitter expects. Defaults to English.
    static func alignerLanguageName(from bcp47: String?) -> String {
        guard let code = bcp47?.split(separator: "-").first.map({ String($0).lowercased() }) else {
            return "English"
        }
        switch code {
        case "en": return "English"
        case "de": return "German"
        case "es": return "Spanish"
        case "fr": return "French"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "nl": return "Dutch"
        case "ru": return "Russian"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "zh": return "Chinese"
        default:   return "English"
        }
    }

    /// Lazy-loads the forced aligner, coalescing concurrent first-use loads
    /// exactly like `loadedModel`.
    private func loadedAligner() async throws -> Qwen3ForcedAligner {
        if let aligner { return aligner }
        if isLoadingAligner {
            try await withCheckedThrowingContinuation { alignerLoadWaiters.append($0) }
            if let aligner { return aligner }
            throw QwenTranscriberError.modelLoad("aligner load finished without a model")
        }
        isLoadingAligner = true
        do {
            let a = try await Qwen3ForcedAligner.fromPretrained(modelId: alignerModelId)
            self.aligner = a
            isLoadingAligner = false
            let waiters = alignerLoadWaiters; alignerLoadWaiters.removeAll()
            for w in waiters { w.resume() }
            return a
        } catch {
            isLoadingAligner = false
            let waiters = alignerLoadWaiters; alignerLoadWaiters.removeAll()
            for w in waiters { w.resume(throwing: error) }
            throw error
        }
    }

    // MARK: - Model loading

    private func loadedModel(progress: @escaping @Sendable (Double) -> Void) async throws -> Qwen3ASRModel {
        if let model { return model }

        // Coalesce concurrent first-use loads. If a download is already in flight,
        // park until it completes rather than starting a second parallel download
        // of the multi-GB bundle, then use the now-loaded model. Only `Void`
        // continuations cross suspension points here — the non-Sendable model is
        // loaded by the direct `await` below and never leaves the actor.
        if isLoadingModel {
            try await withCheckedThrowingContinuation { loadWaiters.append($0) }
            if let model { return model }
            throw QwenTranscriberError.modelLoad("model load finished without a model")
        }

        isLoadingModel = true
        let loadStart = Date()
        // M11: purge a partial/corrupt cache BEFORE loading so an aborted first
        // download self-heals on the next attempt instead of failing forever with
        // a cryptic MLX load error (the truncated `model.safetensors` "exists", so
        // nothing would otherwise re-download it).
        QwenProvisioning.purgeIfCorrupt(modelId: modelId)
        do {
            // M-3 groundwork: log the resolved model id. speech-swift's
            // `fromPretrained` has no `revision:` parameter and does not
            // return a resolved commit/revision — see the upstream-blocked
            // TODO in `ModelPins.swift`. The modelId is the closest honest
            // provenance signal available today.
            //
            // H6: bound the multi-GB download+load. `fromPretrained` has no
            // timeout; a stalled first download would otherwise hang the episode
            // in `transcribing` forever. `Qwen3ASRModel` is non-Sendable, so it
            // cannot itself cross the task-group boundary `withTimeout` uses — we
            // box it in an @unchecked-Sendable wrapper that is created and
            // unwrapped without ever touching the model off the loading context.
            let modelId = self.modelId   // capture for the @Sendable closure
            let box = try await withTimeout(seconds: modelLoadTimeoutSeconds) {
                let loaded = try await Qwen3ASRModel.fromPretrained(
                    modelId: modelId,
                    progressHandler: { frac, _ in progress(frac) }
                )
                return QwenModelBox(loaded)
            }
            let m = box.model
            Log.info("QwenTranscriber: model loaded", component: "QwenTranscriber",
                     context: [("modelId", modelId), ("revisionPin", "none (M-3 upstream-blocked)"),
                               ("seconds", String(format: "%.1f", Date().timeIntervalSince(loadStart)))])
            self.model = m
            isLoadingModel = false
            let waiters = loadWaiters; loadWaiters.removeAll()
            for w in waiters { w.resume() }
            return m
        } catch let timeout as TimeoutError {
            // H6: transient — surface a bare TimeoutError so the pipeline requeues
            // (FallbackTranscriber will also try Whisper on this run). Log the
            // wedge explicitly so the in-app log proves it wasn't a silent hang.
            Log.error("QwenTranscriber: model load TIMED OUT — requeue (transient)",
                      component: "QwenTranscriber",
                      context: [("modelId", modelId),
                                ("elapsedSec", String(format: "%.0f", Date().timeIntervalSince(loadStart))),
                                ("timeoutSec", String(format: "%.0f", timeout.seconds))])
            isLoadingModel = false
            let waiters = loadWaiters; loadWaiters.removeAll()
            for w in waiters { w.resume(throwing: timeout) }
            throw timeout
        } catch {
            isLoadingModel = false
            let waiters = loadWaiters; loadWaiters.removeAll()
            for w in waiters { w.resume(throwing: error) }
            throw error
        }
    }

    // MARK: - Helpers

    /// A compact model tag for provenance, e.g.
    /// "aufklarer/Qwen3-ASR-1.7B-MLX-8bit" → "1.7B-8bit".
    static func shortTag(for modelId: String) -> String {
        let last = modelId.split(separator: "/").last.map(String.init) ?? modelId
        // Strip a leading "Qwen3-ASR-" and any "-MLX" infix for brevity.
        var t = last
        for token in ["Qwen3-ASR-", "qwen3-asr-"] where t.hasPrefix(token) { t = String(t.dropFirst(token.count)) }
        t = t.replacingOccurrences(of: "-MLX", with: "").replacingOccurrences(of: "-mlx", with: "")
        return t.isEmpty ? modelId : t
    }

    /// Decodes any AVFoundation-readable audio file into mono Float PCM at
    /// `sampleRate`, resampling/downmixing as needed.
    static func loadMonoSamples(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw QwenTranscriberError.audioFormat("cannot build 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw QwenTranscriberError.audioFormat("cannot build audio converter")
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
            throw QwenTranscriberError.audioFormat("cannot allocate output buffer")
        }

        // One-shot: the whole file is already in `inBuf`, so feed it once then
        // report end-of-stream. A reference flag avoids a captured-var mutation in
        // the (nominally @Sendable) input block.
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
            throw QwenTranscriberError.audioFormat("audio conversion failed")
        }
        let n = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}

// MARK: - Errors

public enum QwenTranscriberError: Error, CustomStringConvertible {
    case audioFormat(String)
    case modelLoad(String)
    public var description: String {
        switch self {
        case .audioFormat(let m): return "QwenTranscriber audio error: \(m)"
        case .modelLoad(let m): return "QwenTranscriber model error: \(m)"
        }
    }
}
