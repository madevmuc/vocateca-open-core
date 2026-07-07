import XCTest
@testable import VocatecaCore

// MARK: - SpeakerAssignmentTests

/// Proof for Package D (speaker diarization) Task 2: `SpeakerAssignment`
/// assigns each `TranscriptionSegment` the speaker of the `SpeakerSegment`
/// with the largest time-overlap, pure and FluidAudio-free.
///
/// Three cases straight from the plan:
///   1. clear max-overlap winner per segment
///   2. no speaker segments at all ⇒ every segment stays `.speaker == nil`
///   3. an exact overlap tie ⇒ the lower speaker index wins
final class SpeakerAssignmentTests: XCTestCase {

    func testAssignsByMaxOverlap() {
        let segs = [
            TranscriptionSegment(start: 0, end: 5, text: "a"),   // mostly speaker 0
            TranscriptionSegment(start: 5, end: 10, text: "b")   // mostly speaker 1
        ]
        let spk = [
            SpeakerSegment(speaker: 0, start: 0, end: 6),
            SpeakerSegment(speaker: 1, start: 6, end: 10)
        ]
        let out = SpeakerAssignment.assign(segs, speakers: spk)
        XCTAssertEqual(out[0].speaker, 0)
        XCTAssertEqual(out[1].speaker, 1)
    }

    func testNoOverlapLeavesNil() {
        let segs = [
            TranscriptionSegment(start: 0, end: 5, text: "a"),
            TranscriptionSegment(start: 5, end: 10, text: "b")
        ]
        let out = SpeakerAssignment.assign(segs, speakers: [])
        XCTAssertNil(out[0].speaker)
        XCTAssertNil(out[1].speaker)
    }

    func testTiePrefersLowerIndex() {
        let segs = [TranscriptionSegment(start: 0, end: 10, text: "a")]
        // Both speaker segments overlap the transcript segment by exactly 5s.
        let spk = [
            SpeakerSegment(speaker: 1, start: 0, end: 5),
            SpeakerSegment(speaker: 0, start: 5, end: 10)
        ]
        let out = SpeakerAssignment.assign(segs, speakers: spk)
        XCTAssertEqual(out[0].speaker, 0)
    }
}
