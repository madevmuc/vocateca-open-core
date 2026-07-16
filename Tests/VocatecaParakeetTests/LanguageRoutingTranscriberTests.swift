import XCTest
import VocatecaCore
@testable import VocatecaParakeet

// MARK: - Fake Transcriber

/// Records calls and returns a canned result (or throws a canned error).
/// An actor so it can safely be mutated/observed from concurrent test code.
private actor FakeTranscriber: Transcriber {
    private(set) var callCount = 0
    private(set) var lastLanguage: String?
    private let result: TranscriptionResult
    private let error: Error?

    init(text: String = "ok", language: String? = "de", error: Error? = nil) {
        self.result = TranscriptionResult(text: text, segments: [], language: language)
        self.error = error
    }

    func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audioURL: audioURL, language: language, progress: { _ in })
    }

    func transcribe(audioURL: URL, language: String?, progress: @escaping ProgressReporter) async throws -> TranscriptionResult {
        callCount += 1
        lastLanguage = language
        if let error { throw error }
        return result
    }
}

private struct StubError: Error {}

private let testURL = URL(fileURLWithPath: "/tmp/fake.wav")

final class LanguageRoutingTranscriberTests: XCTestCase {

    // MARK: - Routing: unsupported language → Whisper only

    func testUnsupportedLanguageGoesWhisperDirectAndSkipsParakeet() async throws {
        let parakeet = FakeTranscriber(text: "should not be called")
        let whisper = FakeTranscriber(text: "türkçe metin", language: "tr")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        let result = try await router.transcribe(audioURL: testURL, language: "tr")

        XCTAssertEqual(result.text, "türkçe metin")
        let parakeetCalls = await parakeet.callCount
        let whisperCalls = await whisper.callCount
        XCTAssertEqual(parakeetCalls, 0, "Parakeet must not be touched for unsupported languages")
        XCTAssertEqual(whisperCalls, 1)
    }

    // MARK: - Routing: supported language, good output → Parakeet only

    func testSupportedLanguageGoodOutputUsesParakeetOnly() async throws {
        let germanText = "Guten Tag, dies ist ein deutscher Satz über das elektronische Postfach der Behörde."
        let parakeet = FakeTranscriber(text: germanText, language: "de")
        let whisper = FakeTranscriber(text: "should not be called")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        let result = try await router.transcribe(audioURL: testURL, language: "de")

        XCTAssertEqual(result.text, germanText)
        let parakeetCalls = await parakeet.callCount
        let whisperCalls = await whisper.callCount
        XCTAssertEqual(parakeetCalls, 1)
        XCTAssertEqual(whisperCalls, 0, "Whisper must not re-run when Parakeet's output verifies fine")
    }

    // MARK: - Routing: supported language, garbled (wrong-language) output → Whisper re-run

    func testSupportedLanguageEnglishGarbleOutputTriggersWhisperRerun() async throws {
        let englishGarble = "good tark this is an english looking sentence about the mailbox authority indeed"
        let parakeet = FakeTranscriber(text: englishGarble, language: "de")
        let whisper = FakeTranscriber(text: "korrigierter deutscher text", language: "de")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        let result = try await router.transcribe(audioURL: testURL, language: "de")

        XCTAssertEqual(result.text, "korrigierter deutscher text")
        let parakeetCalls = await parakeet.callCount
        let whisperCalls = await whisper.callCount
        XCTAssertEqual(parakeetCalls, 1)
        XCTAssertEqual(whisperCalls, 1, "Whisper must re-run once when Parakeet's output fails language verification")
    }

    /// The 2026-07-16 incident: an English podcast pinned to `de` reached here,
    /// and the re-run forced `de` onto Whisper — decoding English audio as German.
    /// The re-run must auto-detect: getting here means `expected` is exactly the
    /// value we just lost trust in.
    func testVerificationFailureRerunsWhisperWithAutoDetectNotTheFailedHint() async throws {
        let englishGarble = "good tark this is an english looking sentence about the mailbox authority indeed"
        let parakeet = FakeTranscriber(text: englishGarble, language: "de")
        let whisper = FakeTranscriber(text: "the real english transcript", language: "en")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        _ = try await router.transcribe(audioURL: testURL, language: "de")

        let whisperLang = await whisper.lastLanguage
        XCTAssertNil(whisperLang, "the re-run must not force the language that just failed verification")
        let parakeetLang = await parakeet.lastLanguage
        XCTAssertEqual(parakeetLang, "de", "the first pass still uses the hint — only the re-run drops it")
    }

    /// A low-confidence re-run takes the same auto-detect path.
    func testLowConfidenceRerunAlsoDropsTheHint() async throws {
        let germanText = "Guten Tag, dies ist ein deutscher Satz über das elektronische Postfach der Behörde."
        let parakeet = FakeTranscriber(text: germanText, language: "de")
        let whisper = FakeTranscriber(text: "whisper redo", language: "de")
        let router = LanguageRoutingTranscriber(
            parakeet: parakeet, whisper: whisper, minConfidence: 0.55,
            confidenceProvider: { 0.1 })

        _ = try await router.transcribe(audioURL: testURL, language: "de")

        let whisperLang = await whisper.lastLanguage
        XCTAssertNil(whisperLang)
    }

    /// Parakeet *failing* is not a language disagreement — the hint is still our
    /// best information there and must survive.
    func testParakeetErrorFallbackKeepsTheLanguageHint() async throws {
        let parakeet = FakeTranscriber(text: "", language: "de", error: StubError())
        let whisper = FakeTranscriber(text: "deutscher text", language: "de")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        _ = try await router.transcribe(audioURL: testURL, language: "de")

        let whisperLang = await whisper.lastLanguage
        XCTAssertEqual(whisperLang, "de")
    }

    // MARK: - Routing: low confidence → Whisper re-run even if text passes language check

    func testLowConfidenceTriggersWhisperRerun() async throws {
        let germanText = "Guten Tag, dies ist ein deutscher Satz über das elektronische Postfach der Behörde."
        let parakeet = FakeTranscriber(text: germanText, language: "de")
        let whisper = FakeTranscriber(text: "whisper redo", language: "de")
        let router = LanguageRoutingTranscriber(
            parakeet: parakeet, whisper: whisper, minConfidence: 0.55,
            confidenceProvider: { 0.1 }
        )

        let result = try await router.transcribe(audioURL: testURL, language: "de")

        XCTAssertEqual(result.text, "whisper redo")
        let whisperCalls = await whisper.callCount
        XCTAssertEqual(whisperCalls, 1)
    }

    // MARK: - Parakeet throws (non-cancellation) → Whisper

    func testParakeetThrowFallsBackToWhisper() async throws {
        let parakeet = FakeTranscriber(error: StubError())
        let whisper = FakeTranscriber(text: "whisper saved the day", language: "de")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        let result = try await router.transcribe(audioURL: testURL, language: "de")

        XCTAssertEqual(result.text, "whisper saved the day")
        let whisperCalls = await whisper.callCount
        XCTAssertEqual(whisperCalls, 1)
    }

    // MARK: - Cancellation propagates, never falls back

    func testCancellationPropagatesWithoutFallback() async throws {
        let parakeet = FakeTranscriber(error: CancellationError())
        let whisper = FakeTranscriber(text: "should not be called")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        do {
            _ = try await router.transcribe(audioURL: testURL, language: "de")
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let whisperCalls = await whisper.callCount
        XCTAssertEqual(whisperCalls, 0, "Cancellation must never fall back to Whisper")
    }

    // MARK: - Unknown expected language → Parakeet, verification skipped (no expected to check against)

    func testUnknownLanguageUsesParakeetWithoutVerification() async throws {
        let parakeet = FakeTranscriber(text: "anything at all, no expectation to violate", language: nil)
        let whisper = FakeTranscriber(text: "should not be called")
        let router = LanguageRoutingTranscriber(parakeet: parakeet, whisper: whisper)

        let result = try await router.transcribe(audioURL: testURL, language: nil)

        XCTAssertEqual(result.text, "anything at all, no expectation to violate")
        let parakeetCalls = await parakeet.callCount
        let whisperCalls = await whisper.callCount
        XCTAssertEqual(parakeetCalls, 1)
        XCTAssertEqual(whisperCalls, 0)
    }
}
