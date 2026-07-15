import Foundation

// MARK: - Domain types

/// A single timed segment from a transcription pass.
public struct TranscriptionSegment: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String
    /// Probability that this segment contains no speech (0–1).
    /// Populated from WhisperKit's `noSpeechProb`; `nil` for other backends.
    public let noSpeechProb: Double?
    /// Average log-probability of the decoded tokens in this segment.
    /// Populated from WhisperKit's `avgLogprob`; `nil` for other backends.
    public let avgLogprob: Double?
    /// Zero-based speaker index assigned by `SpeakerAssignment` from a
    /// diarization pass, or `nil` when diarization is disabled/unavailable
    /// or no `SpeakerSegment` overlapped this segment.
    public var speaker: Int?

    public init(
        start: Double,
        end: Double,
        text: String,
        noSpeechProb: Double? = nil,
        avgLogprob: Double? = nil,
        speaker: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
        self.speaker = speaker
    }
}

/// The full result returned by any `Transcriber` implementation.
public struct TranscriptionResult: Sendable, Equatable {
    /// Full concatenated transcript text.
    public let text: String
    /// Per-segment breakdown with timestamps.
    public let segments: [TranscriptionSegment]
    /// BCP-47 language code detected by the model, if available (e.g. `"en"`).
    public let language: String?
    /// How this transcript was derived (engine/model or source captions).
    /// `nil` when a producer does not report provenance (e.g. legacy fakes).
    public let origin: TranscriptOrigin?

    public init(text: String,
                segments: [TranscriptionSegment],
                language: String?,
                origin: TranscriptOrigin? = nil) {
        self.text = text
        self.segments = segments
        self.language = language
        self.origin = origin
    }

    /// Returns a copy tagged with the given provenance.
    public func withOrigin(_ origin: TranscriptOrigin) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: segments, language: language, origin: origin)
    }
}

// MARK: - Protocol

/// Domain-level seam for audio transcription engines.
///
/// Implementations must be `Sendable` so they can be stored in actors and
/// shared across structured concurrency trees without data races.
public protocol Transcriber: Sendable {
    /// `true` when the engine's model is already loaded in memory and the next
    /// `transcribe` call will run inference immediately; `false` when the next
    /// call must first download and/or load the model — a step that can take
    /// tens of seconds to minutes on first use (e.g. WhisperKit/Parakeet/Qwen's
    /// ~0.6–1.7 GB first download) and, without any visible signal, reads as a
    /// hang.
    ///
    /// `Pipeline` checks this immediately before calling `transcribe` and, when
    /// `false`, emits a `modelLoading` progress stage so the UI can show
    /// "Modell wird geladen…" instead of a frozen bar.
    ///
    /// Default `true` (a conformer that has no lazy load — e.g. test fakes —
    /// is always "ready"). Real engines with a lazy/cached model override this
    /// with a cheap synchronous check of their cached-instance state (never a
    /// network call).
    var isWarm: Bool { get async }

    /// Transcribes the audio file at `audioURL`.
    ///
    /// - Parameters:
    ///   - audioURL: A `file://` URL to the audio file (mp3, m4a, wav, …).
    ///   - language: BCP-47 hint to the model (e.g. `"en"`, `"de"`), or `nil`
    ///               to auto-detect.
    /// - Returns: A `TranscriptionResult` with full text, timed segments, and
    ///            the detected language.
    /// - Throws: Any error from the underlying engine (model load, decoding, …).
    func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult

    /// Transcribes the audio file, calling `progress` with 0.0–1.0 fractions
    /// as the engine processes audio segments.
    ///
    /// Default implementation emits 0.0 at start (a "started" signal so the UI
    /// shows activity) and delegates to `transcribe(audioURL:language:)`.
    /// Override to emit real per-segment fractions when the engine supports it.
    ///
    /// ## WhisperKit note
    /// WhisperKit's `transcribe(audioPath:decodeOptions:)` returns all segments
    /// in one `await` with no intermediate callbacks. The default implementation
    /// therefore emits a coarse 0.0 signal at start so the progress bar shows
    /// activity. A real per-segment fraction would require WhisperKit to expose
    /// a streaming / segment callback API (not available in the current version).
    ///
    /// NOTE: `progress` is `@escaping` so engines can retain it across their own
    /// async callbacks (WhisperKit captures it in a per-window callback). Every
    /// conformer's override MUST spell the parameter `@escaping ProgressReporter`
    /// verbatim — a mismatched spelling makes the method a non-witness overload,
    /// silently routing `any Transcriber` calls to the default below (which drops
    /// real progress) instead of the engine's implementation.
    func transcribe(audioURL: URL, language: String?, progress: @escaping ProgressReporter) async throws -> TranscriptionResult

    /// Transcribes with an optional per-episode `context` (prompt + glossary +
    /// language) that an engine may use to bias decoding (WhisperKit turns the
    /// prompt into `DecodingOptions.promptTokens`; other engines ignore it and
    /// rely on post-ASR correction).
    ///
    /// The default implementation (below) **drops** `context` and forwards to
    /// `transcribe(audioURL:language:progress:)`, so an engine that only
    /// implements the progress overload keeps satisfying this requirement
    /// unchanged. Engines that consume the prompt (WhisperKit) and wrappers that
    /// must thread it inward (LanguageRoutingTranscriber, FallbackTranscriber)
    /// override this method.
    ///
    /// NOTE: like the progress overload, a conformer's override MUST spell the
    /// parameters verbatim (`context: TranscriptionContext?`,
    /// `progress: @escaping ProgressReporter`) or it becomes a non-witness
    /// overload and `any Transcriber` calls silently route to the context-dropping
    /// default below.
    func transcribe(audioURL: URL, language: String?, context: TranscriptionContext?, progress: @escaping ProgressReporter) async throws -> TranscriptionResult

    /// Releases any resident model so its memory can be reclaimed by ARC,
    /// without discarding the engine itself — a later `transcribe` call
    /// simply re-loads lazily, exactly like a fresh instance's first call.
    ///
    /// Exists so a caller that knows two large ASR models must never be
    /// resident at once (e.g. `LanguageRoutingTranscriber`'s Parakeet→Whisper
    /// verification fallback) can force the losing engine's memory back
    /// before the winning engine loads, instead of relying on both staying
    /// "warm" simultaneously. Conformers with no lazy-loaded model (test
    /// fakes, simple wrappers) get the default no-op below; real engines with
    /// a cached model (e.g. `ParakeetTranscriber`) override this to drop
    /// their strong reference to it.
    func releaseModel() async
}

public extension Transcriber {
    /// Default: emit 0.0 at start (activity signal), then forward to primary method.
    func transcribe(audioURL: URL, language: String?, progress: @escaping ProgressReporter) async throws -> TranscriptionResult {
        progress(0.0)
        return try await transcribe(audioURL: audioURL, language: language)
    }

    /// Default: **drop** `context` and forward to the progress overload, so every
    /// existing conformer (which implements only the progress overload) keeps
    /// satisfying the protocol without change. Engines/wrappers that use the
    /// context override this method instead.
    func transcribe(audioURL: URL, language: String?, context: TranscriptionContext?, progress: @escaping ProgressReporter) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, progress: progress)
    }

    /// Default: always warm. Correct for conformers with no lazy load (test
    /// fakes, simple wrappers) — never causes a spurious "modelLoading" stage.
    var isWarm: Bool {
        get async { true }
    }

    /// Default: no-op. Correct for conformers with no lazy-loaded model
    /// (test fakes, simple wrappers) — nothing to release.
    func releaseModel() async {}
}
