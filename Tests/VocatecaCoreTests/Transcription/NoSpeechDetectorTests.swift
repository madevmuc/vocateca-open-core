import XCTest
@testable import VocatecaCore

// MARK: - NoSpeechDetectorTests

/// TDD tests for ``NoSpeechDetector``.
///
/// Each test builds a synthetic ``TranscriptionResult`` and asserts the
/// ``NoSpeechVerdict``. No network or file I/O occurs.
final class NoSpeechDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a `TranscriptionResult` from raw text and optional per-segment
    /// noSpeechProb values.  The segment list is divided into equal-length
    /// slices when `noSpeechProbs` is provided; otherwise one segment per word.
    private func makeResult(
        text: String,
        noSpeechProbs: [Double]? = nil
    ) -> TranscriptionResult {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let probs = noSpeechProbs {
            // Build one segment per prob value, distributing words evenly.
            let segCount = probs.count
            let wordsPerSeg = max(1, words.count / max(segCount, 1))
            var segments: [TranscriptionSegment] = []
            for (i, prob) in probs.enumerated() {
                let start = words.indices.startIndex + i * wordsPerSeg
                let end = min(start + wordsPerSeg, words.count)
                let slice = words[start..<end]
                let segText = slice.joined(separator: " ")
                segments.append(TranscriptionSegment(
                    start: Double(i) * 5,
                    end: Double(i) * 5 + 5,
                    text: segText.isEmpty ? "…" : segText,
                    noSpeechProb: prob
                ))
            }
            return TranscriptionResult(text: text, segments: segments, language: nil)
        } else {
            // One segment for the whole text.
            let seg = TranscriptionSegment(start: 0, end: 10, text: text)
            return TranscriptionResult(text: text, segments: [seg], language: nil)
        }
    }

    // MARK: - 1. Empty text → flagged

    func testEmptyTextIsNoSpeech() {
        let result = TranscriptionResult(text: "", segments: [], language: nil)
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertTrue(verdict.isNoSpeech, "Empty transcript must be flagged as no-speech")
        XCTAssertNotNil(verdict.reason)
    }

    func testWhitespaceOnlyTextIsNoSpeech() {
        let result = TranscriptionResult(
            text: "   \n\t  ",
            segments: [TranscriptionSegment(start: 0, end: 5, text: "   ")],
            language: nil
        )
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertTrue(verdict.isNoSpeech, "Whitespace-only transcript must be flagged as no-speech")
    }

    // MARK: - 2. High noSpeechProb → flagged

    func testHighNoSpeechProbIsFlagged() {
        // All segments have noSpeechProb = 0.85 — well above 0.60 threshold.
        let result = makeResult(
            text: "some mumble sounds",
            noSpeechProbs: [0.85, 0.90, 0.80]
        )
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertTrue(verdict.isNoSpeech,
                      "Mean noSpeechProb > 0.60 must be flagged")
        XCTAssertTrue(verdict.reason?.contains("noSpeechProb") == true,
                      "Reason must mention noSpeechProb")
    }

    func testNoSpeechProbJustAboveThresholdIsFlagged() {
        // Mean = 0.61 — just above 0.60 threshold.
        let result = makeResult(
            text: "barely any speech here",
            noSpeechProbs: [0.61, 0.61]
        )
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertTrue(verdict.isNoSpeech,
                      "Mean noSpeechProb of 0.61 (> 0.60) must be flagged")
    }

    func testNoSpeechProbJustBelowThresholdIsNotFlagged() {
        // Mean = 0.55 — below 0.60 threshold.  Other signals also absent.
        let result = makeResult(
            text: "hello world this is normal speech content with enough words to avoid other signals",
            noSpeechProbs: [0.55, 0.55]
        )
        // No duration → WPM check skipped; few enough words → no repetition check.
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertFalse(verdict.isNoSpeech,
                       "Mean noSpeechProb of 0.55 (< 0.60) must NOT be flagged")
    }

    // MARK: - 3. Looping / low unique-word ratio → flagged

    func testLoopingWhisperIsFlagged() {
        // 40 words, only 4 unique → ratio = 0.10 < 0.20. Whisper looping on music.
        let loopText = Array(repeating: "the music plays on and on", count: 8).joined(separator: " ")
        let result = makeResult(text: loopText)
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertTrue(verdict.isNoSpeech,
                      "Very low unique-word ratio must be flagged as Whisper looping")
        XCTAssertTrue(verdict.reason?.contains("unique-word ratio") == true,
                      "Reason must mention unique-word ratio")
    }

    func testExactlyMinWordsForRepetitionCheckNotFlagged() {
        // 29 words (below the 30-word minimum) → repetition check skipped even if ratio is low.
        // We fill with 5 unique words repeated to stay under 30 total.
        let text = Array(repeating: "boom", count: 29).joined(separator: " ")
        let result = makeResult(text: text)
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        // noSpeechProb absent, duration absent → only repetition check applies,
        // but it is skipped because word count < 30.
        XCTAssertFalse(verdict.isNoSpeech,
                       "Fewer than \(NoSpeechDetector.minWordsForRepetitionCheck) words must skip the repetition check")
    }

    // MARK: - 4. Low WPM on long clip → flagged

    func testLowWpmOnLongClipIsFlagged() {
        // 5 words, 300 seconds (5 min) → 1 wpm < 3.0 threshold.
        let result = makeResult(text: "the end")
        let verdict = NoSpeechDetector.classify(result, durationSec: 300)
        XCTAssertTrue(verdict.isNoSpeech,
                      "Very low WPM on a long clip must be flagged")
        XCTAssertTrue(verdict.reason?.contains("wpm") == true,
                      "Reason must mention wpm")
    }

    func testLowWpmOnShortClipNotFlagged() {
        // 2 words, 30 seconds (<60s) → WPM check skipped.
        let result = makeResult(text: "hello world")
        let verdict = NoSpeechDetector.classify(result, durationSec: 30)
        XCTAssertFalse(verdict.isNoSpeech,
                       "Short clip (<60 s) with few words must NOT be flagged")
    }

    // MARK: - 5. Normal speech → NOT flagged

    func testNormalSpeechIsNotFlagged() {
        // ~100 varied words, low noSpeechProb, 120-second clip → all signals negative.
        let speechText = """
            Welcome to today's episode where we explore the fascinating world of science
            technology and human behaviour. Our guest today has spent twenty years studying
            the intersection of psychology economics and decision making. We will cover
            topics ranging from behavioural nudges to institutional design and look at
            what the research actually tells us about how people change their habits.
            """
        let words = speechText.split(whereSeparator: \.isWhitespace).map(String.init)
        let segments = stride(from: 0, to: words.count, by: 10).map { i -> TranscriptionSegment in
            let slice = words[i..<min(i + 10, words.count)]
            return TranscriptionSegment(
                start: Double(i),
                end: Double(i) + 10,
                text: slice.joined(separator: " "),
                noSpeechProb: 0.05   // low — real speech
            )
        }
        let result = TranscriptionResult(
            text: speechText,
            segments: segments,
            language: "en"
        )
        let verdict = NoSpeechDetector.classify(result, durationSec: 120)
        XCTAssertFalse(verdict.isNoSpeech,
                       "Normal varied speech must NOT be flagged as no-speech")
        XCTAssertNil(verdict.reason,
                     "Reason must be nil when isNoSpeech is false")
    }

    // MARK: - Qwen-style results (no noSpeechProb) degrade gracefully

    /// Qwen (and any non-Whisper engine) produces segments with `noSpeechProb == nil`.
    /// Signal 2 must be skipped (not crash / not false-positive); normal speech with
    /// nil probs stays classified as speech via the other signals.
    func testNilNoSpeechProbNormalSpeechNotFlagged() {
        let speechText = """
            Welcome to today's episode where we explore the fascinating world of science
            technology and human behaviour. Our guest has spent twenty years studying
            the intersection of psychology economics and decision making across cultures.
            """
        let words = speechText.split(whereSeparator: \.isWhitespace).map(String.init)
        let segments = stride(from: 0, to: words.count, by: 10).map { i -> TranscriptionSegment in
            let slice = words[i..<min(i + 10, words.count)]
            return TranscriptionSegment(
                start: Double(i), end: Double(i) + 10,
                text: slice.joined(separator: " "),
                noSpeechProb: nil, avgLogprob: nil   // Qwen-style: no Whisper metrics
            )
        }
        let result = TranscriptionResult(text: speechText, segments: segments, language: "en")
        let verdict = NoSpeechDetector.classify(result, durationSec: 120)
        XCTAssertFalse(verdict.isNoSpeech,
                       "Nil-prob (Qwen) normal speech must not be flagged as no-speech")
    }

    /// Even without `noSpeechProb`, a looping/music transcript is still caught by the
    /// unique-word-ratio signal (Signal 4), which needs only text.
    func testNilNoSpeechProbLoopingStillFlagged() {
        let loop = Array(repeating: "music", count: 60).joined(separator: " ")
        let seg = TranscriptionSegment(start: 0, end: 60, text: loop, noSpeechProb: nil, avgLogprob: nil)
        let result = TranscriptionResult(text: loop, segments: [seg], language: nil)
        let verdict = NoSpeechDetector.classify(result, durationSec: 120)
        XCTAssertTrue(verdict.isNoSpeech,
                      "Looping transcript must still be flagged via unique-word ratio even with nil prob")
    }

    func testShortLegitimateClipIsNotFlagged() {
        // A short 30-second clip with only a few words but high speech confidence
        // (low noSpeechProb) must NOT be flagged.
        let result = makeResult(
            text: "okay see you later",
            noSpeechProbs: [0.08]
        )
        let verdict = NoSpeechDetector.classify(result, durationSec: 30)
        XCTAssertFalse(verdict.isNoSpeech,
                       "Short legit clip with low noSpeechProb must NOT be flagged")
    }

    func testModerateProbWithGoodTextIsNotFlagged() {
        // Mean noSpeechProb = 0.40 (below 0.60 threshold), varied text, decent WPM.
        let text = "this podcast covers interesting research in many diverse areas of science"
        let result = makeResult(text: text, noSpeechProbs: [0.40, 0.40])
        let verdict = NoSpeechDetector.classify(result, durationSec: 10)
        XCTAssertFalse(verdict.isNoSpeech,
                       "Moderate noSpeechProb (0.40) with good text must NOT be flagged")
    }

    // MARK: - 6. Missing optional fields → no crash

    func testNilDurationDoesNotCrash() {
        let result = makeResult(text: "just a few words")
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        // WPM check skipped; no other strong signal → not flagged.
        XCTAssertFalse(verdict.isNoSpeech)
    }

    func testNoSegmentNoSpeechProbDoesNotCrash() {
        // Segments have no noSpeechProb → that signal is simply skipped.
        let result = makeResult(text: "hello there how are you doing today")
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        XCTAssertFalse(verdict.isNoSpeech)
    }

    // MARK: - 7. Reason string is nil when speech is detected

    func testReasonIsNilForSpeech() {
        let result = makeResult(text: "normal conversational speech content here")
        let verdict = NoSpeechDetector.classify(result, durationSec: nil)
        if !verdict.isNoSpeech {
            XCTAssertNil(verdict.reason, "Reason must be nil when speech is detected")
        }
    }
}
