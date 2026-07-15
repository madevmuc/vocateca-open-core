import XCTest
@testable import VocatecaCore

/// Tests for the v2-additive `.vtt` / `.csv` transcript export renderers.
/// These are explicitly NOT oracle-locked (no Python reference implementation,
/// no golden fixtures) — see `TranscriptFormat.swift`'s module doc for the
/// oracle-lock contract this file's functions are deliberately outside of.
/// Correctness here is defined by these unit tests alone.
final class TranscriptFormatCSVVTTTests: XCTestCase {

    // MARK: - vttFromSegments

    func testVttFromSegmentsBasic() {
        let segments = [
            TranscriptionSegment(start: 0.0, end: 4.12, text: "Hallo und willkommen"),
            TranscriptionSegment(start: 4.12, end: 8.4, text: "Danke fuers Einladen"),
        ]
        let vtt = TranscriptFormat.vttFromSegments(segments)
        XCTAssertEqual(vtt, """
        WEBVTT

        00:00:00.000 --> 00:00:04.120
        Hallo und willkommen

        00:00:04.120 --> 00:00:08.400
        Danke fuers Einladen

        """)
    }

    func testVttFromSegmentsEmptyIsHeaderOnly() {
        XCTAssertEqual(TranscriptFormat.vttFromSegments([]), "WEBVTT\n\n")
    }

    // MARK: - csvFromSegments (basic — no quoting-required text yet)

    func testCsvFromSegmentsBasicHeaderAndRows() {
        let segments = [
            TranscriptionSegment(start: 0.0, end: 4.12, text: "Hallo und willkommen", speaker: 0),
            TranscriptionSegment(start: 4.12, end: 8.4, text: "Danke fuers Einladen", speaker: 1),
        ]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertEqual(csv, """
        start,end,speaker,text
        0.00,4.12,S1,Hallo und willkommen
        4.12,8.40,S2,Danke fuers Einladen

        """)
    }

    func testCsvFromSegmentsNilSpeakerIsEmptyColumn() {
        let segments = [TranscriptionSegment(start: 1.0, end: 2.0, text: "no diarization")]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertEqual(csv, """
        start,end,speaker,text
        1.00,2.00,,no diarization

        """)
    }

    func testCsvFromSegmentsSpeakerIndexMapsToOneBasedLabel() {
        let segments = [
            TranscriptionSegment(start: 0.0, end: 1.0, text: "first", speaker: 0),
            TranscriptionSegment(start: 1.0, end: 2.0, text: "second", speaker: 4),
        ]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertTrue(csv.contains("0.00,1.00,S1,first"))
        XCTAssertTrue(csv.contains("1.00,2.00,S5,second"))
    }

    func testCsvFromSegmentsEmptyIsHeaderOnly() {
        XCTAssertEqual(TranscriptFormat.csvFromSegments([]), "start,end,speaker,text\n")
    }

    // MARK: - csvFromSegments RFC-4180 quoting edge cases

    func testCsvFromSegmentsQuotesCommaInText() {
        let segments = [TranscriptionSegment(start: 0.0, end: 1.0, text: "Hello, world")]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertTrue(csv.contains("0.00,1.00,,\"Hello, world\""), csv)
    }

    func testCsvFromSegmentsDoublesEmbeddedQuotes() {
        let segments = [TranscriptionSegment(start: 0.0, end: 1.0, text: "She said \"hi\"")]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertTrue(csv.contains("0.00,1.00,,\"She said \"\"hi\"\"\""), csv)
    }

    func testCsvFromSegmentsQuotesEmbeddedNewline() {
        let segments = [TranscriptionSegment(start: 0.0, end: 1.0, text: "line one\nline two")]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertTrue(csv.contains("0.00,1.00,,\"line one\nline two\""), csv)
    }

    func testCsvFromSegmentsUnquotedUnicodeTextPassesThrough() {
        let segments = [TranscriptionSegment(start: 0.0, end: 1.0, text: "Grüße 🎉 — kein Komma", speaker: 0)]
        let csv = TranscriptFormat.csvFromSegments(segments)
        XCTAssertTrue(csv.contains("0.00,1.00,S1,Grüße 🎉 — kein Komma"), csv)
    }
}
