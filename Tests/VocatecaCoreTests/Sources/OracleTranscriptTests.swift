import XCTest
@testable import VocatecaCore

/// Oracle tests for ``TranscriptFormat`` — Phase 2 Work Package 2.
///
/// **Deterministic tests** load committed golden JSON fixtures produced by the
/// Python reference oracle and assert byte-for-byte equality for every case.
/// Do NOT edit the JSON fixtures to make tests pass — Python is authoritative.
final class OracleTranscriptTests: XCTestCase {

    // MARK: - Fixture loading helpers

    private func fixtureURL(named filename: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "json",
            subdirectory: "Fixtures/oracle"
        ) else {
            XCTFail("Fixture not found: Fixtures/oracle/\(filename).json")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    private func fixtureData(named filename: String) throws -> Data {
        try Data(contentsOf: fixtureURL(named: filename))
    }

    // MARK: - testParseDetectedLanguage

    func testParseDetectedLanguage() throws {
        struct Case: Decodable {
            let input: String
            let output: String?
        }
        let cases = try JSONDecoder().decode([Case].self, from: fixtureData(named: "parse_detected_language"))
        XCTAssertFalse(cases.isEmpty, "parse_detected_language fixture is empty")
        var failures = 0
        for c in cases {
            let got = TranscriptFormat.parseDetectedLanguage(c.input)
            if got != c.output {
                XCTFail("""
                    parseDetectedLanguage mismatch:
                      input:    \(c.input.debugDescription)
                      expected: \(String(describing: c.output))
                      got:      \(String(describing: got))
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("parseDetectedLanguage: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - testIsWhisperNativeAudio

    func testIsWhisperNativeAudio() throws {
        struct Case: Decodable {
            let description: String
            let header_bytes: [Int]
            let output: Bool
        }
        let cases = try JSONDecoder().decode([Case].self, from: fixtureData(named: "whisper_native"))
        XCTAssertFalse(cases.isEmpty, "whisper_native fixture is empty")
        var failures = 0
        for c in cases {
            let bytes = c.header_bytes.map { UInt8(clamping: $0) }
            let got = TranscriptFormat.isWhisperNativeAudio(headerBytes: bytes)
            if got != c.output {
                XCTFail("""
                    isWhisperNativeAudio mismatch [\(c.description)]:
                      bytes:    \(c.header_bytes.prefix(8))
                      expected: \(c.output)
                      got:      \(got)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("isWhisperNativeAudio: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - testWhisperTimeoutSeconds

    func testWhisperTimeoutSeconds() throws {
        struct Case: Decodable {
            let file_size_bytes: Int
            let output: Int
        }
        let cases = try JSONDecoder().decode([Case].self, from: fixtureData(named: "whisper_timeout"))
        XCTAssertFalse(cases.isEmpty, "whisper_timeout fixture is empty")
        var failures = 0
        for c in cases {
            let got = TranscriptFormat.whisperTimeoutSeconds(fileSizeBytes: c.file_size_bytes)
            if got != c.output {
                XCTFail("""
                    whisperTimeoutSeconds mismatch:
                      file_size_bytes: \(c.file_size_bytes)
                      expected: \(c.output)
                      got:      \(got)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("whisperTimeoutSeconds: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - testVttToSRT

    func testVttToSRT() throws {
        struct Case: Decodable {
            let description: String
            let input: String
            let output: String
        }
        let cases = try JSONDecoder().decode([Case].self, from: fixtureData(named: "vtt_to_srt"))
        XCTAssertFalse(cases.isEmpty, "vtt_to_srt fixture is empty")
        var failures = 0
        for c in cases {
            let got = TranscriptFormat.vttToSRT(c.input)
            if got != c.output {
                XCTFail("""
                    vttToSRT mismatch [\(c.description)]:
                      input:    \(c.input.debugDescription)
                      expected: \(c.output.debugDescription)
                      got:      \(got.debugDescription)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("vttToSRT: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - testSrtToPlainText

    func testSrtToPlainText() throws {
        struct Case: Decodable {
            let description: String
            let input: String
            let output: String
        }
        let cases = try JSONDecoder().decode([Case].self, from: fixtureData(named: "srt_to_plain_text"))
        XCTAssertFalse(cases.isEmpty, "srt_to_plain_text fixture is empty")
        var failures = 0
        for c in cases {
            let got = TranscriptFormat.srtToPlainText(c.input)
            if got != c.output {
                XCTFail("""
                    srtToPlainText mismatch [\(c.description)]:
                      input:    \(c.input.debugDescription)
                      expected: \(c.output.debugDescription)
                      got:      \(got.debugDescription)
                    """)
                failures += 1
            }
        }
        if failures == 0 {
            print("srtToPlainText: all \(cases.count) cases passed ✓")
        }
    }

    // MARK: - YouTube captions → segments / result (1a)

    func testSrtToSegments() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello world

        2
        00:00:04,500 --> 00:00:06,250
        Second line
        """
        let segs = TranscriptFormat.srtToSegments(srt)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].end, 4.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].text, "Hello world")
        XCTAssertEqual(segs[1].start, 4.5, accuracy: 0.001)
        XCTAssertEqual(segs[1].end, 6.25, accuracy: 0.001)
    }

    func testCaptionResultFromVTT() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        Hallo Welt
        """
        let r = TranscriptFormat.captionResult(fromVTT: vtt, language: "de")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.language, "de")
        XCTAssertTrue(r?.text.contains("Hallo Welt") ?? false)
        XCTAssertEqual(r?.segments.count, 1)
    }

    func testCaptionResultEmptyReturnsNil() {
        XCTAssertNil(TranscriptFormat.captionResult(fromVTT: "WEBVTT\n\n", language: "en"))
    }

    /// Regression: YouTube auto-caption cue settings (`align:start position:0%`)
    /// are single-space-separated, so the oracle-locked `vttToSRT` leaves them on
    /// the timestamp line. `parseSRTTimestamp` must still extract the timestamp —
    /// otherwise EVERY segment is skipped (segments=0) even though the text parses
    /// fine. Real-world video O0UH966DG0s produced 1508 chars of text but 0
    /// segments before the fix.
    func testCaptionResultYouTubeStyleWithCueSettings() {
        let vtt = """
        WEBVTT
        Kind: captions
        Language: de

        00:00:00.880 --> 00:00:02.470 align:start position:0%
        Schwarze<00:00:01.319><c> Masse,</c><00:00:01.640><c> die</c>

        00:00:02.470 --> 00:00:02.480 align:start position:0%
        Schwarze Masse, die

        00:00:02.480 --> 00:00:04.789 align:start position:0%
        Schwarze Masse, die
        quillt<00:00:03.360><c> hier.</c>
        """
        let r = TranscriptFormat.captionResult(fromVTT: vtt, language: "de")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.language, "de")
        // The cue-setting timestamp line must still yield timed segments.
        XCTAssertGreaterThan(r?.segments.count ?? 0, 0,
                             "cue settings must not zero out segments")
        // Text is clean + deduped (rolling build-up collapsed).
        let text = r?.text ?? ""
        XCTAssertTrue(text.contains("Schwarze Masse, die"))
        XCTAssertTrue(text.contains("quillt hier."))
        // First segment carries the parsed start/end despite trailing cue settings.
        if let first = r?.segments.first {
            XCTAssertEqual(first.start, 0.880, accuracy: 0.001)
            XCTAssertEqual(first.end, 2.470, accuracy: 0.001)
        }
    }

    // MARK: - Live YouTube auto-caption path (network, env-gated)

    /// End-to-end proof of the caption path: fetch a real YouTube video's
    /// AUTO-generated German captions via yt-dlp and run them through the same
    /// parse+dedup the pipeline uses. Verifies the `manual_auto_whisper` chain's
    /// `auto` step yields a clean German transcript (so Whisper is skipped).
    ///
    /// Env-gated (`VOCATECA_RUN_NETWORK_TESTS=1`) — hits the network + spawns
    /// yt-dlp, so it never runs in the deterministic suite.
    func testYouTubeAutoCaptionPathLive() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("network test — set VOCATECA_RUN_NETWORK_TESTS=1 to run")
        }
        let vtt = await YtDlpCaptionFetcher.fetch(
            videoURL: "https://www.youtube.com/watch?v=O0UH966DG0s", auto: true, langHint: "de")
        let raw = try XCTUnwrap(vtt, "yt-dlp should return an auto-caption VTT track")

        let result = try XCTUnwrap(
            TranscriptFormat.captionResult(fromVTT: raw, language: "de"),
            "VTT should parse into a caption result")

        XCTAssertEqual(result.language, "de")
        // The real regression: cue-setting timestamp lines used to zero out
        // segments even though text parsed fine.
        XCTAssertGreaterThan(result.segments.count, 5, "expected many timed caption cues")
        XCTAssertGreaterThan(result.text.count, 200, "expected substantial transcript text")

        // Dedup sanity: after dedupe, no two ADJACENT segment texts identical.
        let texts = result.segments.map { $0.text }
        if texts.count > 1 {
            for i in 1..<texts.count {
                XCTAssertFalse(texts[i] == texts[i-1] && !texts[i].isEmpty,
                               "adjacent segments must not be exact duplicates at \(i)")
            }
        }
    }
}
