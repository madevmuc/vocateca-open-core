import XCTest
@testable import VocatecaCore

// MARK: - DiarizerTypesTests

/// Core-type proof for Package D (speaker diarization) Task 1:
/// `TranscriptionSegment.speaker` defaults to `nil` and can be set, and
/// `SpeakerSegment` is a plain `Sendable, Equatable` value type. No FluidAudio
/// involved here — this is pure Core.
final class DiarizerTypesTests: XCTestCase {

    func testTranscriptionSegmentSpeakerDefaultsToNil() {
        let segment = TranscriptionSegment(start: 0, end: 1, text: "x")
        XCTAssertNil(segment.speaker)
    }

    func testTranscriptionSegmentSpeakerCanBeSet() {
        let segment = TranscriptionSegment(start: 0, end: 1, text: "x", speaker: 2)
        XCTAssertEqual(segment.speaker, 2)
    }

    func testSpeakerSegmentEquatable() {
        let a = SpeakerSegment(speaker: 0, start: 0, end: 1)
        let b = SpeakerSegment(speaker: 0, start: 0, end: 1)
        let c = SpeakerSegment(speaker: 1, start: 0, end: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
