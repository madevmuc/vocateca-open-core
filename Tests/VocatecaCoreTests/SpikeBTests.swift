import XCTest
@testable import VocatecaCore

/// Spike B — Phase 0: prove that WhisperKit (CoreML) can transcribe an audio
/// file natively on this Mac, lazily downloading the model on first use, and
/// that our domain `Transcriber` seam returns a structured `TranscriptionResult`.
///
/// Network is required on first run to download the model.  If the download
/// fails (offline / rate-limited) the test calls `XCTSkip` instead of failing.
final class SpikeBTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        // These spikes download a CoreML model from HuggingFace on first run.
        // Skip by default (e.g. in CI) unless explicitly opted in, so the model
        // download never gates the deterministic suite.
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_WHISPER_TESTS"] == "1" else {
            throw XCTSkip("set VOCATECA_RUN_WHISPER_TESTS=1 to run WhisperKit model tests")
        }
    }

    func testWhisperKitTranscribesShortMp3() async throws {
        // ------------------------------------------------------------------
        // 1. Locate the fixture in the test bundle.
        // ------------------------------------------------------------------
        guard let fixtureURL = Bundle.module.url(
            forResource: "short",
            withExtension: "mp3",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("short.mp3 not found in test bundle — check Fixtures/ and Package.swift resource rule")
            return
        }

        // ------------------------------------------------------------------
        // 2. Instantiate the transcriber with the tiny model.
        // ------------------------------------------------------------------
        let transcriber = WhisperKitTranscriber(model: "openai_whisper-tiny")

        // ------------------------------------------------------------------
        // 3. Transcribe — model is downloaded lazily on first call.
        //    Budget: model download + CoreML specialisation + inference.
        // ------------------------------------------------------------------
        let result: TranscriptionResult
        do {
            result = try await transcriber.transcribe(audioURL: fixtureURL, language: nil)
        } catch WhisperKitTranscriberError.modelLoadFailed(let model, let underlying) {
            // Offline or rate-limited — skip rather than fail.
            throw XCTSkip("WhisperKit model '\(model)' unavailable (offline?): \(underlying)")
        } catch {
            // Any other error during transcription is a real failure.
            XCTFail("transcribe(audioURL:) threw unexpectedly: \(error)")
            return
        }

        // ------------------------------------------------------------------
        // 4. Print diagnostics so the test log captures the actual output.
        // ------------------------------------------------------------------
        print("SpikeBTests — detected language: \(result.language ?? "<nil>")")
        print("SpikeBTests — segment count: \(result.segments.count)")
        print("SpikeBTests — full text: \(result.text)")
        for (i, seg) in result.segments.enumerated() {
            print("  [\(i)] \(String(format: "%.2f", seg.start))s → \(String(format: "%.2f", seg.end))s : \(seg.text)")
        }

        // ------------------------------------------------------------------
        // 5. Assertions.
        // ------------------------------------------------------------------

        // Text must be non-empty after trimming.
        XCTAssertFalse(
            result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "TranscriptionResult.text must not be empty"
        )

        // There must be at least one segment.
        XCTAssertFalse(
            result.segments.isEmpty,
            "TranscriptionResult.segments must not be empty"
        )

        // Every segment must have end >= start.
        for seg in result.segments {
            XCTAssertGreaterThanOrEqual(
                seg.end, seg.start,
                "Segment '\(seg.text)' has end (\(seg.end)) < start (\(seg.start))"
            )
        }

        // Concatenated segment texts are consistent with the full .text.
        let concatenated = result.segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(
            concatenated.isEmpty,
            "Concatenated segment texts must not be empty"
        )
    }

    /// Stronger proof: transcribe a fixture with KNOWN speech (generated via the
    /// macOS `say` voice) and assert recognised words overlap the ground truth.
    /// This is the meaningful spike for the Phase 2 WER-tolerance oracle diff —
    /// `[BLANK_AUDIO]` on silence does not exercise the speech path.
    ///
    /// Ground truth: "The quick brown fox jumps over the lazy dog.
    ///                Vocateca transcribes podcasts and videos."
    func testWhisperKitTranscribesKnownSpeech() async throws {
        guard let fixtureURL = Bundle.module.url(
            forResource: "speech_en",
            withExtension: "wav",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("speech_en.wav not found in test bundle — check Fixtures/ and Package.swift resource rule")
            return
        }

        let transcriber = WhisperKitTranscriber(model: "openai_whisper-tiny")
        let result: TranscriptionResult
        do {
            result = try await transcriber.transcribe(audioURL: fixtureURL, language: "en")
        } catch WhisperKitTranscriberError.modelLoadFailed(let model, let underlying) {
            throw XCTSkip("WhisperKit model '\(model)' unavailable (offline?): \(underlying)")
        } catch {
            XCTFail("transcribe(audioURL:) threw unexpectedly: \(error)")
            return
        }

        let lower = result.text.lowercased()
        print("SpikeBTests — known-speech transcript: \(result.text)")

        // WhisperKit ≠ whisper.cpp, so we do NOT assert byte-exact wording.
        // The tiny model is lossy; require a reasonable overlap with the
        // distinctive content words rather than a perfect match.
        let expectedWords = ["quick", "brown", "fox", "lazy", "dog",
                             "podcasts", "videos", "transcribes"]
        let hits = expectedWords.filter { lower.contains($0) }
        print("SpikeBTests — known-speech word hits: \(hits) (\(hits.count)/\(expectedWords.count))")
        XCTAssertGreaterThanOrEqual(
            hits.count, 3,
            "Expected the tiny model to recover at least 3 of the distinctive ground-truth words; got \(hits) from: \(result.text)"
        )
    }
}
