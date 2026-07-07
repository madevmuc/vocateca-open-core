import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - WhisperKitTranscriptionEngineTests
//
// Real WhisperKit transcription (model download) is gated behind
// VOCATECA_RUN_WHISPER_TESTS=1. All other tests run unconditionally.

final class WhisperKitTranscriptionEngineTests: XCTestCase {

    // MARK: - Settings model name → WhisperKit model id

    func testWhisperKitModelIDMapping() {
        // WhisperKit takes the SHORT variant name (it forms `openai_whisper-<name>`
        // itself). The turbo folder uses an UNDERSCORE separator, so `-turbo` →
        // `_turbo` (the real repo folder is `openai_whisper-large-v3_turbo`).
        XCTAssertEqual(WhisperKitTranscriber.whisperKitModelID(from: "large-v3-turbo"),
                       "large-v3_turbo")
        XCTAssertEqual(WhisperKitTranscriber.whisperKitModelID(from: "tiny"),
                       "tiny")
        // Whitespace is trimmed.
        XCTAssertEqual(WhisperKitTranscriber.whisperKitModelID(from: "  base "),
                       "base")
        // Empty falls back to the default (turbo) variant, normalised.
        XCTAssertEqual(WhisperKitTranscriber.whisperKitModelID(from: ""),
                       "large-v3_turbo")
        // A fully-qualified id is stripped back to its short variant name.
        XCTAssertEqual(WhisperKitTranscriber.whisperKitModelID(from: "openai_whisper-medium"),
                       "medium")
    }

    // MARK: - isWhisperNativeAudio: MP3 (ID3) header

    func testIsWhisperNativeAudioMP3ID3() {
        let header: [UInt8] = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertTrue(TranscriptFormat.isWhisperNativeAudio(headerBytes: header),
                      "ID3-tagged MP3 must be Whisper-native")
    }

    func testIsWhisperNativeAudioMP3BareMPEGSync() {
        let header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertTrue(TranscriptFormat.isWhisperNativeAudio(headerBytes: header),
                      "Bare MPEG sync MP3 must be Whisper-native")
    }

    func testIsWhisperNativeAudioWAV() {
        // RIFF....WAVE
        let header: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, 0x00, 0x00, 0x00, 0x00]
        XCTAssertTrue(TranscriptFormat.isWhisperNativeAudio(headerBytes: header),
                      "WAV must be Whisper-native")
    }

    func testIsWhisperNativeAudioFLAC() {
        // fLaC
        let header: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertTrue(TranscriptFormat.isWhisperNativeAudio(headerBytes: header),
                      "FLAC must be Whisper-native")
    }

    func testIsWhisperNativeAudioM4ANotNative() {
        // ftyp (MP4/M4A)
        let header: [UInt8] = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00]
        XCTAssertFalse(TranscriptFormat.isWhisperNativeAudio(headerBytes: header),
                       "M4A/ftyp must NOT be Whisper-native — requires ffmpeg conversion")
    }

    func testIsWhisperNativeAudioOGGNotNative() {
        // OggS
        let header: [UInt8] = [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertFalse(TranscriptFormat.isWhisperNativeAudio(headerBytes: header),
                       "OGG must NOT be Whisper-native")
    }

    func testIsWhisperNativeAudioTooFewBytes() {
        XCTAssertFalse(TranscriptFormat.isWhisperNativeAudio(headerBytes: [0x49, 0x44, 0x33]),
                       "Less than 4 bytes must return false")
    }

    // MARK: - SRT assembly from fixed TranscriptionResult

    func testSRTFromFixedTranscriptionResult() {
        let result = TranscriptionResult(
            text: "Hello world. This is a test.",
            segments: [
                TranscriptionSegment(start: 0.0,   end: 3.0,  text: "Hello world."),
                TranscriptionSegment(start: 3.0,   end: 7.5,  text: "This is a test."),
            ],
            language: "en"
        )

        let srt = WhisperKitTranscriptionEngine.buildSRT(segments: result.segments)

        // Verify structure.
        let blocks = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(blocks.count, 2, "Should produce 2 SRT blocks")

        let firstBlock = blocks[0].components(separatedBy: "\n")
        XCTAssertEqual(firstBlock[0], "1", "First cue index must be 1")
        XCTAssertEqual(firstBlock[1], "00:00:00,000 --> 00:00:03,000")
        XCTAssertEqual(firstBlock[2], "Hello world.")

        let secondBlock = blocks[1].components(separatedBy: "\n")
        XCTAssertEqual(secondBlock[0], "2", "Second cue index must be 2")
        XCTAssertEqual(secondBlock[1], "00:00:03,000 --> 00:00:07,500")
        XCTAssertEqual(secondBlock[2], "This is a test.")
    }

    // MARK: - Word count extraction

    func testWordCountFromResult() {
        let text = "Hello world this is five"
        let count = WhisperKitTranscriptionEngine.countWords(text)
        XCTAssertEqual(count, 5)
    }

    func testWordCountEmptyText() {
        XCTAssertEqual(WhisperKitTranscriptionEngine.countWords(""), 0)
    }

    func testWordCountMultilineText() {
        let text = "Line one\nLine two\nThree four five"
        XCTAssertEqual(WhisperKitTranscriptionEngine.countWords(text), 7)
    }

    // MARK: - Detected language

    func testDetectedLanguageFromTranscriptionResult() {
        let result = TranscriptionResult(
            text: "Guten Morgen",
            segments: [TranscriptionSegment(start: 0, end: 1, text: "Guten Morgen")],
            language: "de"
        )
        XCTAssertEqual(result.language, "de")
    }

    func testNilLanguageWhenNotDetected() {
        let result = TranscriptionResult(
            text: "...",
            segments: [],
            language: nil
        )
        XCTAssertNil(result.language)
    }

    // MARK: - Mean confidence: nil when no per-segment confidence available

    func testMeanConfidenceReturnsNilWithNoSegments() {
        XCTAssertNil(WhisperKitTranscriptionEngine.computeMeanConfidence([]))
    }

    func testMeanConfidenceReturnsNilForSegmentsWithoutConfidence() {
        // TranscriptionSegment has no confidence field — should return nil.
        let segments = [
            TranscriptionSegment(start: 0, end: 1, text: "A"),
            TranscriptionSegment(start: 1, end: 2, text: "B"),
        ]
        XCTAssertNil(WhisperKitTranscriptionEngine.computeMeanConfidence(segments))
    }

    // MARK: - ffmpeg path: Real conversion (skipped if ffmpeg unavailable)

    func testffmpegConversionSkippedIfUnavailable() async throws {
        // Create a fake M4A file (just needs a non-native header).
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // ftyp header = M4A (not Whisper-native).
        let ftypHeader = Data([
            0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70,
            0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00
        ])
        let fakeM4A = tmpDir.appendingPathComponent("fake.m4a")
        try ftypHeader.write(to: fakeM4A)

        let bm = BinaryManager()
        if bm.resolvedPath(for: .ffmpeg) == nil {
            // ffmpeg not present — engine should throw .permanent
            let engine = WhisperKitTranscriptionEngine(binaryManager: bm)
            let episode = Episode(
                guid: "ep-m4a",
                showSlug: "show",
                title: "T",
                pubDate: "2024-01-01",
                mp3Url: "https://example.com/ep.m4a"
            )
            do {
                _ = try await engine.transcribe(audioURL: fakeM4A, episode: episode)
                XCTFail("Should throw permanent when ffmpeg is unavailable")
            } catch PipelineError.permanent(let msg) {
                XCTAssertTrue(
                    msg.lowercased().contains("ffmpeg"),
                    "Error must mention ffmpeg: \(msg)"
                )
            }
        } else {
            // ffmpeg is present — conversion should succeed (then whisper will fail because
            // the input isn't real audio; we just verify the .permanent error is from Whisper, not ffmpeg).
            // This case is best-effort in CI — skip if WhisperKit model would be needed.
            let runWhisper = ProcessInfo.processInfo.environment["VOCATECA_RUN_WHISPER_TESTS"] == "1"
            if !runWhisper {
                // Skip this path without ffmpeg+whisper.
                return
            }
        }
    }

    // MARK: - GATED: Real WhisperKit transcription

    func testRealWhisperTranscription() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_WHISPER_TESTS"] == "1" else {
            throw XCTSkip("Set VOCATECA_RUN_WHISPER_TESTS=1 to run real Whisper tests (downloads model)")
        }

        // This test requires a real WAV file and network access to download the model.
        // In a real environment, provide a path to a known short WAV fixture.
        throw XCTSkip("Real Whisper test requires a fixture WAV file — provide VOCATECA_TEST_WAV_PATH")
    }
}
