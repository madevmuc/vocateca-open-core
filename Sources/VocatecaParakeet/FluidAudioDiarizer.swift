// Runtime: FluidAudio (CoreML diarization runtime) — licensed Apache-2.0.
// Models: FluidInference/speaker-diarization-coreml (pyannote community-1) — auto-
// downloaded on first `process()`. Attribution surfaced in AboutSheet.

import Foundation
import VocatecaCore
import FluidAudio

// MARK: - FluidAudioDiarizer

/// A ``Diarizer`` backed by FluidAudio's `OfflineDiarizerManager` (CoreML/ANE).
///
/// Isolated in `VocatecaParakeet` — the module that already links FluidAudio —
/// so the diarization model graph stays out of `VocatecaCore` and its fast unit
/// tests. Mirrors ``ParakeetTranscriber``'s structure.
///
/// ## Notes / limits
/// - `OfflineDiarizerManager` memory-maps and resamples the audio file itself
///   and lazily downloads its CoreML models on the first `process()` call, so
///   construction is cheap (no I/O). It is a plain `final class` (not an actor)
///   whose `process` is `nonisolated`; to stay clear of Swift 6 "sending a
///   `self`-isolated value" data-race diagnostics we create a fresh manager
///   **local** to each `diarize` call rather than caching one in actor state.
///   The models themselves are cached on disk by FluidAudio, so a second call's
///   `prepareModels()` is a fast no-op check (no re-download).
/// - FluidAudio labels clusters `"S1"`, `"S2"`, … (1-based). ``SpeakerSegment``
///   is documented **zero-based**, so ``map(_:)`` subtracts one.
/// - The package's deployment floor is macOS 15, which already satisfies
///   `OfflineDiarizerManager`'s `@available(macOS 14.0, *)`, so no availability
///   guard is required at the call site.
/// - `Diarizer` is fully qualified as `VocatecaCore.Diarizer` throughout —
///   FluidAudio also exports an (unrelated, `AnyObject`) `Diarizer` protocol,
///   so the bare name is ambiguous once both modules are imported.
public actor FluidAudioDiarizer: VocatecaCore.Diarizer {

    public init() {}

    // MARK: Diarizer

    public func diarize(
        audioURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerSegment] {
        Log.info("Diarization started", component: "Diarize", context: [("file", audioURL.lastPathComponent)])

        let result = try await OfflineDiarizerManager().process(audioURL) { done, total in
            progress?(Double(done) / Double(max(total, 1)))
        }

        let segments = Self.map(result.segments)
        Log.info(
            "Diarization finished",
            component: "Diarize",
            context: [("segments", String(segments.count))]
        )
        return segments
    }

    // MARK: Mapping (pure)

    /// Maps FluidAudio's `TimedSpeakerSegment`s to engine-agnostic
    /// ``SpeakerSegment``s, order-preserving and 1:1 (no coalescing/sorting).
    ///
    /// Pure and side-effect-free so it can be unit-tested without loading models
    /// or audio. `speakerId` (`"S1"`, `"S2"`, …) is converted to the zero-based
    /// ``SpeakerSegment/speaker`` index; an unparseable id falls back to `0`.
    public static func map(_ segments: [TimedSpeakerSegment]) -> [SpeakerSegment] {
        segments.map { seg in
            SpeakerSegment(
                speaker: speakerIndex(from: seg.speakerId),
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds)
            )
        }
    }

    /// Parses FluidAudio's 1-based `"S<N>"` cluster label into a zero-based
    /// speaker index. Tolerates a missing/absent `"S"` prefix and defends
    /// against non-numeric ids by falling back to `0`.
    private static func speakerIndex(from speakerId: String) -> Int {
        let digits = speakerId.hasPrefix("S") ? String(speakerId.dropFirst()) : speakerId
        guard let oneBased = Int(digits) else { return 0 }
        return max(0, oneBased - 1)
    }
}
