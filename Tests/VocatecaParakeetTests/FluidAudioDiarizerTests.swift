import XCTest
import FluidAudio
import VocatecaCore
@testable import VocatecaParakeet

// MARK: - FluidAudioDiarizer

/// Unit tests for the FluidAudio-backed ``Diarizer``.
///
/// These exercise **only** the pure, model-free surface:
/// - the actor constructs without touching CoreML / the network, and
/// - the static `map(_:)` helper turns FluidAudio's `TimedSpeakerSegment`
///   values into engine-agnostic `SpeakerSegment`s.
///
/// The real `process()` call (which downloads ~models and reads audio) is
/// deliberately **not** invoked here — that stays out of CI per the plan's
/// network-gating constraint.
final class FluidAudioDiarizerTests: XCTestCase {

    /// A `TimedSpeakerSegment` fixture. `embedding`/`qualityScore` are irrelevant
    /// to the mapping, so we feed empty/zero values.
    private func fixture(_ speakerId: String, _ start: Float, _ end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 0
        )
    }

    // MARK: Construction

    func testConstructs() {
        // Must not download models or read audio — just allocate the actor.
        _ = FluidAudioDiarizer()
    }

    // MARK: map(_:)

    /// FluidAudio labels clusters `"S1"`, `"S2"`, … (1-based). Core's
    /// `SpeakerSegment.speaker` is documented **zero-based**, so `"S1"` → 0.
    func testMapConvertsSpeakerIdAndTimes() {
        let out = FluidAudioDiarizer.map([
            fixture("S1", 0.0, 2.5),
            fixture("S2", 2.5, 6.0),
            fixture("S1", 6.0, 7.25),
        ])

        XCTAssertEqual(out, [
            SpeakerSegment(speaker: 0, start: 0.0, end: 2.5),
            SpeakerSegment(speaker: 1, start: 2.5, end: 6.0),
            SpeakerSegment(speaker: 0, start: 6.0, end: 7.25),
        ])
    }

    /// Order is preserved 1:1 (no sorting / coalescing in the mapper).
    func testMapPreservesOrderAndCount() {
        let out = FluidAudioDiarizer.map([
            fixture("S3", 10.0, 11.0),
            fixture("S1", 0.0, 1.0),
        ])

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].speaker, 2)   // "S3" → 2
        XCTAssertEqual(out[1].speaker, 0)   // "S1" → 0
    }

    func testMapEmptyIsEmpty() {
        XCTAssertTrue(FluidAudioDiarizer.map([]).isEmpty)
    }
}
