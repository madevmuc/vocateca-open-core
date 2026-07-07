import Foundation
import VocatecaCore

/// Dual-model router: sends languages outside Parakeet's 25 straight to Whisper,
/// otherwise runs Parakeet, then verifies the output language (NLLanguageRecognizer
/// + optional confidence) and re-runs Whisper once on a clear mismatch.
/// Cancellation is never swallowed.
public actor LanguageRoutingTranscriber: Transcriber {
    public enum RouteDecision: Equatable { case whisperDirect, parakeetThenVerify }

    private let parakeet: any Transcriber
    private let whisper: any Transcriber
    private let minConfidence: Double
    private let confidenceProvider: (@Sendable () async -> Double?)?

    /// Confidence floor below which a Parakeet result is re-checked against Whisper.
    /// Named so every call site (QueueController + the CLI) shares one value instead
    /// of each relying on an implicit literal.
    public static let defaultMinConfidence: Double = 0.55

    public init(parakeet: any Transcriber, whisper: any Transcriber,
                minConfidence: Double = LanguageRoutingTranscriber.defaultMinConfidence,
                confidenceProvider: (@Sendable () async -> Double?)? = nil) {
        self.parakeet = parakeet
        self.whisper = whisper
        self.minConfidence = minConfidence
        self.confidenceProvider = confidenceProvider
    }

    /// `true` only when BOTH candidates are warm. Unlike `FallbackTranscriber`,
    /// the route here is decided per-call from the `language` hint (see
    /// `route(expected:)`) — `isWarm` has no such parameter, so which engine
    /// THIS call will hit isn't knowable in advance. Parakeet can also cascade
    /// into Whisper mid-call on a failed load/verification, so either engine
    /// may end up doing the actual work. Requiring both warm is the
    /// conservative choice: it never reports "warm" while an engine this call
    /// could still land on is cold, avoiding the false negative that would
    /// suppress `Pipeline`'s `modelLoading` stage on a genuine first download.
    public var isWarm: Bool {
        get async {
            // Await each separately: an `async` access can't sit in the
            // autoclosure `&&` builds for its right operand.
            let parakeetWarm = await parakeet.isWarm
            let whisperWarm = await whisper.isWarm
            return parakeetWarm && whisperWarm
        }
    }

    /// Pure routing decision (unit-tested).
    public static func route(expected: String?) -> RouteDecision {
        guard let expected, !expected.isEmpty else { return .parakeetThenVerify } // unknown → try + verify
        return ParakeetLanguages.supports(expected) ? .parakeetThenVerify : .whisperDirect
    }

    public func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, context: nil, progress: { _ in })
    }

    public func transcribe(audioURL: URL, language: String?,
                           progress: @escaping ProgressReporter) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, context: nil, progress: progress)
    }

    /// Context-aware entry point (the real routing lives here). Forwards
    /// `context` through to whichever inner engine runs — Whisper directly, or
    /// Parakeet then a possible Whisper re-run — so a per-episode prompt/glossary
    /// reaches the engine that actually transcribes.
    public func transcribe(audioURL: URL, language: String?,
                           context: TranscriptionContext?,
                           progress: @escaping ProgressReporter) async throws -> TranscriptionResult {
        // A failed verification runs a second (Whisper) pass over the same file;
        // clamp the reporter monotonically so the bar never visibly jumps backward.
        let progress = Self.monotonic(progress)
        switch Self.route(expected: language) {
        case .whisperDirect:
            Log.info("Language \(language ?? "?") ∉ Parakeet-25 → Whisper",
                     component: "Transcribe", context: [("lang", language ?? "nil")])
            return try await whisper.transcribe(audioURL: audioURL, language: language, context: context, progress: progress)

        case .parakeetThenVerify:
            let result: TranscriptionResult
            do {
                result = try await parakeet.transcribe(audioURL: audioURL, language: language, context: context, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.warn("Parakeet failed → Whisper", component: "Transcribe", context: [("error", "\(error)")])
                return try await whisper.transcribe(audioURL: audioURL, language: language, context: context, progress: progress)
            }
            // Verify only when we know the expected language.
            if let expected = language, !expected.isEmpty {
                let confOK = await confidenceOK()
                let langOK = TranscriptLanguageCheck.looksLike(expected, text: result.text)
                if !langOK || !confOK {
                    Log.info("Parakeet output failed verification → re-run Whisper",
                             component: "Transcribe",
                             context: [("expected", expected), ("langOK", "\(langOK)"), ("confOK", "\(confOK)")])
                    return try await whisper.transcribe(audioURL: audioURL, language: expected, context: context, progress: progress)
                }
            }
            return result
        }
    }

    private func confidenceOK() async -> Bool {
        guard let provider = confidenceProvider, let c = await provider() else { return true } // no signal → don't block
        return c >= minConfidence
    }

    /// Wraps a reporter so emitted fractions never decrease — prevents the progress
    /// bar from visibly resetting when a failed language/confidence check triggers a
    /// second Whisper pass. Thread-safe: engines may call `progress` from their own
    /// executors.
    private static func monotonic(_ progress: @escaping ProgressReporter) -> ProgressReporter {
        final class Box: @unchecked Sendable { let lock = NSLock(); var seen = 0.0 }
        let box = Box()
        return { frac in
            box.lock.lock()
            box.seen = Swift.max(box.seen, frac)
            let v = box.seen
            box.lock.unlock()
            progress(v)
        }
    }
}
