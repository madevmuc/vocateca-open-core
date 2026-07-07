import Foundation
import VocatecaCore

// MARK: - FallbackTranscriber

/// Wraps a `primary` transcriber (Qwen) with a `fallback` (Whisper): if the
/// primary fails — most importantly a model download/load failure on first use —
/// it logs and permanently switches to the fallback for the rest of the run.
/// Cancellation is never swallowed.
///
/// This is the runtime half of the design's "fallback to Whisper if Qwen
/// load/download fails" rule (`EngineSelector` handles the static choice).
public actor FallbackTranscriber: Transcriber {

    private let primary: any Transcriber
    private let fallback: any Transcriber
    private var primaryDisabled = false

    public init(primary: any Transcriber, fallback: any Transcriber) {
        self.primary = primary
        self.fallback = fallback
    }

    /// `true` only when the engine this run will actually dispatch to is
    /// warm: once `primaryDisabled` is set (sticky for the run — see
    /// `transcribe`), that IS the fallback, so only the fallback's warmth
    /// matters; before that, the primary is the answer. Reporting "warm"
    /// while the about-to-be-used engine is actually cold would suppress the
    /// `modelLoading` stage on a genuine first-download — the false negative
    /// this property exists to avoid — so the two candidates are never OR'd
    /// together; only the currently-relevant one is checked.
    public var isWarm: Bool {
        get async {
            primaryDisabled ? await fallback.isWarm : await primary.isWarm
        }
    }

    public func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, context: nil, progress: { _ in })
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        progress: @escaping ProgressReporter
    ) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, context: nil, progress: progress)
    }

    /// Context-aware entry point (the real fallback logic lives here). Forwards
    /// `context` through to whichever engine runs — the primary (Qwen) or, after
    /// a sticky failure, the fallback (Whisper) — so a per-episode prompt/glossary
    /// reaches the engine that actually transcribes.
    public func transcribe(
        audioURL: URL,
        language: String?,
        context: TranscriptionContext?,
        progress: @escaping ProgressReporter
    ) async throws -> TranscriptionResult {
        if !primaryDisabled {
            do {
                return try await primary.transcribe(audioURL: audioURL, language: language, context: context, progress: progress)
            } catch is CancellationError {
                throw CancellationError()   // user stop / worker cancel — never fall back
            } catch {
                primaryDisabled = true       // sticky: don't re-try the primary this run
                Log.warn("Primary transcription engine failed — falling back to Whisper",
                         component: "Transcribe", context: [("error", "\(error)")])
            }
        }
        return try await fallback.transcribe(audioURL: audioURL, language: language, context: context, progress: progress)
    }
}
