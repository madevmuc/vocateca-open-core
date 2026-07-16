import XCTest
@testable import VocatecaCore

/// Non-oracle tests for segment-level rolling-caption dedup
/// (`TranscriptFormat.dedupeCaptionSegments` + the `isAuto` branch of
/// `captionResult`). Safe to evolve — no golden fixtures.
final class CaptionSegmentDedupTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text)
    }

    // The Stanford screenshot rolling sequence.
    func testCollapsesRollingBuildUps() {
        let input = [
            seg(8, 9, "this program is brought to you by"),
            seg(8, 11, "this program is brought to you by Stanford University please visit us at"),
            seg(11, 12, "Stanford University please visit us at"),
            seg(11, 13, "Stanford University please visit us at stanford.edu"),
        ]
        let out = TranscriptFormat.dedupeCaptionSegments(input)
        XCTAssertEqual(out.map(\.text), [
            "this program is brought to you by Stanford University please visit us at",
            "Stanford University please visit us at stanford.edu",
        ])
    }

    // Build-up survivor keeps earliest start + latest end of its group.
    func testMergesTimingEarliestStartLatestEnd() {
        let input = [
            seg(8.0, 9.0, "hello there"),
            seg(8.5, 11.0, "hello there world"),
        ]
        let out = TranscriptFormat.dedupeCaptionSegments(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "hello there world")
        XCTAssertEqual(out[0].start, 8.0, accuracy: 0.0001)
        XCTAssertEqual(out[0].end, 11.0, accuracy: 0.0001)
    }

    // Exact duplicate collapses, timing merges.
    func testExactDuplicateCollapses() {
        let input = [seg(1, 2, "same line"), seg(2, 3, "same line")]
        let out = TranscriptFormat.dedupeCaptionSegments(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "same line")
        XCTAssertEqual(out[0].start, 1, accuracy: 0.0001)
        XCTAssertEqual(out[0].end, 3, accuracy: 0.0001)
    }

    // Shorter build-up AFTER the fuller line: drop the shorter, keep fuller text.
    func testShorterAfterFullerDrops() {
        let input = [
            seg(1, 3, "the quick brown fox"),
            seg(3, 4, "the quick brown"),
        ]
        let out = TranscriptFormat.dedupeCaptionSegments(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "the quick brown fox")
        XCTAssertEqual(out[0].end, 4, accuracy: 0.0001)
    }

    // Unrelated lines are all kept, order preserved.
    func testUnrelatedLinesKept() {
        let input = [seg(1, 2, "alpha"), seg(2, 3, "beta"), seg(3, 4, "gamma")]
        let out = TranscriptFormat.dedupeCaptionSegments(input)
        XCTAssertEqual(out.map(\.text), ["alpha", "beta", "gamma"])
    }

    func testEmptyInput() {
        XCTAssertTrue(TranscriptFormat.dedupeCaptionSegments([]).isEmpty)
    }
}

extension CaptionSegmentDedupTests {

    // Minimal YouTube-style rolling VTT (two build-up pairs).
    private var rollingVTT: String {
        """
        WEBVTT

        00:00:08.000 --> 00:00:11.000
        this program is brought to you by

        00:00:08.500 --> 00:00:11.000
        this program is brought to you by Stanford University

        00:00:11.000 --> 00:00:13.000
        Stanford University

        00:00:11.500 --> 00:00:13.000
        Stanford University please visit stanford.edu
        """
    }

    func testCaptionResultAutoDedupesSegments() throws {
        let r = try XCTUnwrap(TranscriptFormat.captionResult(fromVTT: rollingVTT, language: "en", isAuto: true))
        XCTAssertEqual(r.segments.map(\.text), [
            "this program is brought to you by Stanford University",
            "Stanford University please visit stanford.edu",
        ])
        // First survivor keeps the earliest start of its collapsed group.
        // (XCTUnwrap because `.accuracy:` needs a non-optional Double.)
        let first = try XCTUnwrap(r.segments.first)
        XCTAssertEqual(first.start, 8.0, accuracy: 0.0001)
    }

    func testCaptionResultAutoTextMatchesSegments() {
        let r = TranscriptFormat.captionResult(fromVTT: rollingVTT, language: "en", isAuto: true)
        let joined = r?.segments.map(\.text).joined(separator: "\n")
        XCTAssertEqual(r?.text, joined)
    }

    // Manual path (default isAuto=false) keeps every raw segment.
    func testCaptionResultManualKeepsRawSegments() {
        let r = TranscriptFormat.captionResult(fromVTT: rollingVTT, language: "en")
        XCTAssertEqual(r?.segments.count, 4)
    }
}
