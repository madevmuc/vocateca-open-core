import XCTest
@testable import VocatecaCore

// MARK: - YouTubeTranscriptServiceRenderTests
//
// Task E.4 — `YouTubeTranscriptService.render(_:format:)`: pure, no-I/O
// rendering of an `ExtractedTranscript` into md/txt/srt/vtt/csv/json. Chains
// through the existing oracle-locked `TranscriptFormat.vttToSRT` and the
// Phase A `TranscriptFormat.vttFromSegments`/`csvFromSegments` rather than
// inventing a parallel renderer.

final class YouTubeTranscriptServiceRenderTests: XCTestCase {

    // MARK: - Fixture (mirrors the design doc's own dialogue example, extended
    // with a third, unspoken-speaker segment to exercise the nil-speaker path)

    private static let fixtureSegments: [TranscriptionSegment] = [
        TranscriptionSegment(start: 0.0, end: 4.12, text: "Hallo und willkommen", speaker: 0),
        TranscriptionSegment(start: 4.12, end: 8.4, text: "Danke fürs Einladen", speaker: 1),
        TranscriptionSegment(start: 8.4, end: 12.0, text: "Und weiter geht's", speaker: nil),
    ]

    private static let fixtureTranscript = ExtractedTranscript(
        videoID: "dQw4w9WgXcQ",
        title: "Never Gonna Give You Up",
        channelID: "UCuAXFkgsw1L7xaCfnd5JJOw",
        channelHandle: "@RickAstleyYT",
        segments: fixtureSegments,
        language: "de",
        source: .captions
    )

    // MARK: - vtt

    func testRender_vtt() {
        let out = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "vtt")
        XCTAssertTrue(out.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(out.contains("00:00:00.000 --> "))
    }

    // MARK: - srt

    func testRender_srt() {
        let out = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "srt")
        XCTAssertTrue(out.hasPrefix("1\n00:00:00,000 --> "))
    }

    // MARK: - txt

    func testRender_txt() {
        let out = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "txt")
        XCTAssertFalse(out.contains("-->"))
        for segment in Self.fixtureSegments {
            XCTAssertTrue(out.contains(segment.text))
        }
        // No cue-number-only lines survive.
        let lines = out.split(separator: "\n")
        XCTAssertFalse(lines.contains { $0.allSatisfy(\.isNumber) })
    }

    // MARK: - md

    func testRender_md() {
        let out = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "md")
        XCTAssertTrue(out.hasPrefix("# Never Gonna Give You Up\n\n"))
        XCTAssertTrue(out.contains("Hallo und willkommen"))
        XCTAssertTrue(out.contains("Danke fürs Einladen"))
    }

    // MARK: - csv

    func testRender_csv() {
        let out = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "csv")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, "start,end,speaker,text")
        XCTAssertTrue(lines.contains { $0.contains("S1") && $0.contains("Hallo und willkommen") })
        XCTAssertTrue(lines.contains { $0.contains("S2") && $0.contains("Danke fürs Einladen") })
        // Third (nil-speaker) row: empty speaker field ",,\"Und weiter geht's\"" shape —
        // just assert the text made it through with no "S<n>" token on its row.
        let thirdRow = lines.first { $0.contains("Und weiter geht") }
        XCTAssertNotNil(thirdRow)
        XCTAssertFalse(thirdRow?.contains("S3") ?? true)
    }

    // MARK: - json

    private struct JSONSegmentMirror: Decodable, Equatable {
        let start: Double
        let end: Double
        let speaker: String?
        let text: String
    }

    func testRender_json() throws {
        let out = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "json")
        let rows = try JSONDecoder().decode([JSONSegmentMirror].self, from: Data(out.utf8))

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], JSONSegmentMirror(start: 0.0, end: 4.12, speaker: "S1", text: "Hallo und willkommen"))
        XCTAssertEqual(rows[1], JSONSegmentMirror(start: 4.12, end: 8.4, speaker: "S2", text: "Danke fürs Einladen"))
        XCTAssertEqual(rows[2], JSONSegmentMirror(start: 8.4, end: 12.0, speaker: nil, text: "Und weiter geht's"))
    }

    // MARK: - unknown format falls back to txt

    func testRender_unknownFormatFallsBackToTxt() {
        let bogus = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "bogus")
        let txt = YouTubeTranscriptService.render(Self.fixtureTranscript, format: "txt")
        XCTAssertEqual(bogus, txt)
    }
}
