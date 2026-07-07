import Foundation

// MARK: - SpeakerSegment

/// A single timed speaker span produced by a diarization pass.
///
/// Engine-agnostic (no FluidAudio types leak into Core): any `Diarizer`
/// conformer — real (FluidAudio-backed) or fake (tests) — maps its own
/// result type into `SpeakerSegment` values.
public struct SpeakerSegment: Sendable, Equatable {
    /// Zero-based speaker index as assigned by the diarization engine.
    public let speaker: Int
    /// Segment start time in seconds, relative to the start of the audio file.
    public let start: Double
    /// Segment end time in seconds, relative to the start of the audio file.
    public let end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

// MARK: - Diarizer

/// Domain-level seam for speaker diarization engines.
///
/// Mirrors `Transcriber`: `VocatecaCore` depends only on this abstraction,
/// while the concrete FluidAudio-backed implementation lives in
/// `VocatecaParakeet` (the module that already links FluidAudio) so Core
/// stays free of that dependency.
///
/// Implementations must be `Sendable` so they can be stored in actors and
/// shared across structured concurrency trees without data races.
public protocol Diarizer: Sendable {
    /// Diarizes the audio file at `audioURL`, returning one `SpeakerSegment`
    /// per detected speaker turn.
    ///
    /// - Parameters:
    ///   - audioURL: A `file://` URL to the audio file (mp3, m4a, wav, …).
    ///   - progress: Optional callback invoked with 0.0–1.0 fractions as the
    ///               engine processes the file. `nil` when the caller doesn't
    ///               need progress updates.
    /// - Returns: The detected speaker segments, in engine-reported order.
    /// - Throws: Any error from the underlying engine (model load, decoding, …).
    func diarize(audioURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerSegment]
}
