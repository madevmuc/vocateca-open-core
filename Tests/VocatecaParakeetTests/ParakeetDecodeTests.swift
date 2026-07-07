import XCTest
@preconcurrency import AVFoundation
@testable import VocatecaParakeet

/// Tests `ParakeetTranscriber`'s pure helpers only — no CoreML model load, no
/// network. `decodeMonoSamples` is exercised against a tiny synthesized wav
/// (written to a temp file) rather than a bundled fixture, and
/// `fluidLanguage(from:)` is a pure BCP-47 → `FluidAudio.Language` mapping.
final class ParakeetDecodeTests: XCTestCase {

    /// Writes a short sine-wave mono wav (44.1 kHz) to a temp file and returns
    /// its URL. Deleted by the OS temp-dir cleanup; each test uses a unique name.
    private func makeTinyWav(seconds: Double = 0.2, sampleRate: Double = 44100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-decode-test-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: 1, interleaved: false) else {
            throw XCTSkip("could not construct AVAudioFormat")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw XCTSkip("could not allocate AVAudioPCMBuffer")
        }
        buffer.frameLength = frameCount
        if let ch = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                ch[0][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate)) * 0.2
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Writes a zero-length wav (header only, no audio frames) to a temp file.
    private func makeEmptyWav(sampleRate: Double = 44100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-decode-empty-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: 1, interleaved: false) else {
            throw XCTSkip("could not construct AVAudioFormat")
        }
        // Creating the file and closing it without ever writing frames yields
        // a valid, zero-length-audio wav.
        _ = try AVAudioFile(forWriting: url, settings: format.settings)
        return url
    }

    func testDecodeProducesNonEmptyMono16k() throws {
        let url = try makeTinyWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try ParakeetTranscriber.decodeMonoSamples(url: url, sampleRate: 16000)

        XCTAssertGreaterThan(samples.count, 0)
        // ~0.2s @ 16kHz ≈ 3200 frames; allow generous slack for converter framing.
        XCTAssertGreaterThan(samples.count, 1000)
        XCTAssertLessThan(samples.count, 10000)
    }

    func testDecodeEmptyFileReturnsEmptyArray() throws {
        let url = try makeEmptyWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try ParakeetTranscriber.decodeMonoSamples(url: url, sampleRate: 16000)

        XCTAssertEqual(samples, [])
    }

    // MARK: - fluidLanguage(from:)

    func testFluidLanguageMapsKnownBcp47Codes() {
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage(from: "de"), .german)
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage(from: "en"), .english)
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage(from: "fr"), .french)
    }

    func testFluidLanguageNormalizesRegionAndCasing() {
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage(from: "de-DE"), .german)
        XCTAssertEqual(ParakeetTranscriber.fluidLanguage(from: "EN-us"), .english)
    }

    func testFluidLanguageReturnsNilForUnknownOrMissing() {
        XCTAssertNil(ParakeetTranscriber.fluidLanguage(from: nil))
        XCTAssertNil(ParakeetTranscriber.fluidLanguage(from: ""))
        XCTAssertNil(ParakeetTranscriber.fluidLanguage(from: "xx-unknown"))
        // Japanese has no Latin/Cyrillic-script FluidAudio.Language case.
        XCTAssertNil(ParakeetTranscriber.fluidLanguage(from: "ja"))
    }
}
