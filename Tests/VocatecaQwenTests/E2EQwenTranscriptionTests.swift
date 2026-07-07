import XCTest
@testable import VocatecaQwen
import VocatecaCore

/// Live end-to-end test of the Qwen3-ASR engine. Downloads the model
/// (`aufklarer/Qwen3-ASR-1.7B-MLX-8bit`, ~1.7 GB) on first run and executes MLX
/// GPU inference, so it is env-gated (`VOCATECA_RUN_QWEN_TESTS=1`) and never runs
/// in the default suite. Mirrors the WhisperKit live-test gating.
final class E2EQwenTranscriptionTests: XCTestCase {

    /// Path to the shared English speech fixture (16 kHz mono, ~5.5 s).
    private var fixtureWAV: URL {
        // …/Tests/VocatecaQwenTests/<thisfile> → …/Tests/VocatecaCoreTests/Fixtures/speech_en.wav
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // VocatecaQwenTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("VocatecaCoreTests/Fixtures/speech_en.wav")
    }

    func testQwenTranscribesFixtureWAV() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_QWEN_TESTS"] == "1" else {
            throw XCTSkip("gated — set VOCATECA_RUN_QWEN_TESTS=1 (downloads ~1.7 GB + runs MLX)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureWAV.path),
                      "fixture missing at \(fixtureWAV.path)")

        let transcriber = QwenTranscriber()   // default 1.7B-8bit
        let result = try await transcriber.transcribe(audioURL: fixtureWAV, language: "en")

        print("=== QWEN TRANSCRIPT ===\n\(result.text)\n=======================")
        print("segments=\(result.segments.count) origin=\(result.origin?.storageString ?? "nil")")

        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Qwen must return non-empty text for a speech clip")
        XCTAssertEqual(result.origin?.method, .asr)
        XCTAssertEqual(result.origin?.engine, "qwen3-asr")
        // Base API is text-only → exactly one whole-file segment.
        XCTAssertEqual(result.segments.count, 1)
    }

    /// Pure (no download): the audio decoder produces 16 kHz mono Float samples.
    func testAudioDecodeProducesSamples() throws {
        let samples = try QwenTranscriber.loadMonoSamples(url: fixtureWAV, sampleRate: 16000)
        // ~5.5 s at 16 kHz ≈ 87k samples.
        XCTAssertGreaterThan(samples.count, 16000, "expected ≳1 s of samples")
        XCTAssertTrue(samples.contains { $0 != 0 }, "decoded audio must not be all-zero")
    }
}
