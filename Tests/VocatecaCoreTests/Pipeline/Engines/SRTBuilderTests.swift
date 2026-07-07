import XCTest
@testable import VocatecaCore

// MARK: - SRTBuilderTests

/// Golden-style tests verifying that `WhisperKitTranscriptionEngine.buildSRT`
/// produces byte-for-byte SRT matching Python's reference implementation.
///
/// Python reference (`core/transcriber.py`):
/// ```python
/// def _build_srt(segments):
///     lines = []
///     for i, seg in enumerate(segments, 1):
///         lines.append(str(i))
///         lines.append(f"{_fmt_srt_time(seg.start)} --> {_fmt_srt_time(seg.end)}")
///         lines.append(seg.text)
///         lines.append("")
///     return "\n".join(lines)
///
/// def _fmt_srt_time(seconds: float) -> str:
///     ms = round(seconds * 1000)
///     h, rem = divmod(ms, 3_600_000)
///     m, rem = divmod(rem, 60_000)
///     s, ms = divmod(rem, 1000)
///     return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"
/// ```
final class SRTBuilderTests: XCTestCase {

    // MARK: - Single segment golden test

    func testSingleSegment() {
        let segments = [
            TranscriptionSegment(start: 0.0, end: 2.5, text: "Hello world")
        ]
        let srt = WhisperKitTranscriptionEngine.buildSRT(segments: segments)

        let expected = """
        1
        00:00:00,000 --> 00:00:02,500
        Hello world

        """
        XCTAssertEqual(srt, expected)
    }

    // MARK: - Multiple segments golden test

    func testMultipleSegments() {
        let segments = [
            TranscriptionSegment(start: 0.0,   end: 2.5,  text: "First segment"),
            TranscriptionSegment(start: 2.5,   end: 5.0,  text: "Second segment"),
            TranscriptionSegment(start: 5.0,   end: 61.0, text: "Third segment"),
        ]
        let srt = WhisperKitTranscriptionEngine.buildSRT(segments: segments)

        let expected = [
            "1",
            "00:00:00,000 --> 00:00:02,500",
            "First segment",
            "",
            "2",
            "00:00:02,500 --> 00:00:05,000",
            "Second segment",
            "",
            "3",
            "00:00:05,000 --> 00:01:01,000",
            "Third segment",
            "",
        ].joined(separator: "\n")

        XCTAssertEqual(srt, expected)
    }

    // MARK: - Empty segments

    func testEmptySegments() {
        let srt = WhisperKitTranscriptionEngine.buildSRT(segments: [])
        XCTAssertEqual(srt, "")
    }

    // MARK: - Timestamp edge cases

    func testTimestampFormatHoursMinutesSeconds() {
        // 3661.001 seconds = 1:01:01,001
        let ts = WhisperKitTranscriptionEngine.formatSRTTime(3661.001)
        XCTAssertEqual(ts, "01:01:01,001")
    }

    func testTimestampFormatSubSecond() {
        // 0.999 → 00:00:00,999
        XCTAssertEqual(WhisperKitTranscriptionEngine.formatSRTTime(0.999), "00:00:00,999")
    }

    func testTimestampFormatExactMinute() {
        // 60.0 → 00:01:00,000
        XCTAssertEqual(WhisperKitTranscriptionEngine.formatSRTTime(60.0), "00:01:00,000")
    }

    func testTimestampFormatRounding() {
        // 1.9999 → rounds to 2000ms → 00:00:02,000
        XCTAssertEqual(WhisperKitTranscriptionEngine.formatSRTTime(1.9999), "00:00:02,000")
    }

    func testTimestampFormatLargeValue() {
        // 7200.0 → 02:00:00,000
        XCTAssertEqual(WhisperKitTranscriptionEngine.formatSRTTime(7200.0), "02:00:00,000")
    }

    // MARK: - Comma decimal separator (not dot)

    func testTimestampUsesCommaNotDot() {
        // Python SRT uses "," to separate seconds from milliseconds.
        let ts = WhisperKitTranscriptionEngine.formatSRTTime(1.5)
        XCTAssertTrue(ts.contains(","), "SRT timestamps must use comma separator, not dot")
        XCTAssertFalse(ts.contains("."), "SRT timestamps must NOT use dot separator")
    }

    // MARK: - Index starts at 1 and increments

    func testIndexStartsAtOneAndIncrements() {
        let segments = (0..<3).map { i in
            TranscriptionSegment(start: Double(i), end: Double(i) + 1.0, text: "Seg \(i + 1)")
        }
        let srt = WhisperKitTranscriptionEngine.buildSRT(segments: segments)
        let lines = srt.components(separatedBy: "\n")
        // First line of each block: 1, 2, 3.
        // Block size = 4 lines (index, timestamp, text, blank).
        XCTAssertEqual(lines[0], "1")
        XCTAssertEqual(lines[4], "2")
        XCTAssertEqual(lines[8], "3")
    }

    // MARK: - Blank line separators between blocks

    func testBlankLineSeparatorsBetweenBlocks() {
        let segments = [
            TranscriptionSegment(start: 0.0, end: 1.0, text: "A"),
            TranscriptionSegment(start: 1.0, end: 2.0, text: "B"),
        ]
        let srt = WhisperKitTranscriptionEngine.buildSRT(segments: segments)
        let lines = srt.components(separatedBy: "\n")
        // Block 1: lines[0..2], blank at lines[3].
        XCTAssertEqual(lines[3], "", "Must have a blank line after each SRT block")
    }

    // MARK: - Word count helper

    func testWordCountEmpty() {
        XCTAssertEqual(WhisperKitTranscriptionEngine.countWords(""), 0)
    }

    func testWordCountSimple() {
        XCTAssertEqual(WhisperKitTranscriptionEngine.countWords("hello world"), 2)
    }

    func testWordCountLeadingTrailingWhitespace() {
        XCTAssertEqual(WhisperKitTranscriptionEngine.countWords("  hello   world  "), 2)
    }

    func testWordCountMultilineText() {
        XCTAssertEqual(WhisperKitTranscriptionEngine.countWords("line one\nline two\nthree"), 5)
    }
}
