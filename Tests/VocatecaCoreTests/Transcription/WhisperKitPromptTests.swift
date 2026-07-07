import XCTest
@testable import VocatecaCore

/// Task 6: the (previously dead) per-episode prompt is turned into WhisperKit
/// `DecodingOptions.promptTokens`. These tests exercise the PURE helpers only —
/// a fake tokenizer is injected so no CoreML model is ever downloaded/loaded.
///
/// Class name is unique so `swift test --filter WhisperKitPromptTests` selects
/// exactly these.
final class WhisperKitPromptTests: XCTestCase {

    /// Fake conforming to the narrow tokenizing seam (word-count = token IDs).
    private struct FakeTokenizer: WhisperPromptTokenizing {
        func encode(text: String) -> [Int] {
            // Deterministic, non-empty for any non-empty text: one id per word.
            text.split(whereSeparator: { $0 == " " || $0 == "," })
                .filter { !$0.isEmpty }
                .enumerated()
                .map { i, _ in i + 1 }
        }
    }

    // MARK: promptString(from:)

    func testPromptStringCombinesPromptAndGlossary() {
        let ctx = TranscriptionContext(prompt: "DOAC, Flightstory",
                                       glossary: ["gocomo", "Firtina"],
                                       language: "de")
        XCTAssertEqual(WhisperKitTranscriber.promptString(from: ctx),
                       "DOAC, Flightstory gocomo, Firtina")
    }

    func testPromptStringPromptOnly() {
        let ctx = TranscriptionContext(prompt: "DOAC, Flightstory", glossary: [], language: nil)
        XCTAssertEqual(WhisperKitTranscriber.promptString(from: ctx), "DOAC, Flightstory")
    }

    func testPromptStringGlossaryOnly() {
        let ctx = TranscriptionContext(prompt: nil, glossary: ["gocomo", "Firtina"], language: nil)
        XCTAssertEqual(WhisperKitTranscriber.promptString(from: ctx), "gocomo, Firtina")
    }

    func testPromptStringNilContextIsNil() {
        XCTAssertNil(WhisperKitTranscriber.promptString(from: nil))
    }

    func testPromptStringEmptyContextIsNil() {
        // No prompt, empty glossary, whitespace-only prompt → nil (not "").
        XCTAssertNil(WhisperKitTranscriber.promptString(from: TranscriptionContext()))
        XCTAssertNil(WhisperKitTranscriber.promptString(
            from: TranscriptionContext(prompt: "   ", glossary: [], language: nil)))
    }

    // MARK: promptTokens(for:tokenizer:)

    func testPromptTokensNonEmptyForRealPrompt() {
        let ctx = TranscriptionContext(prompt: "DOAC, Flightstory", glossary: ["gocomo"], language: nil)
        let tokens = WhisperKitTranscriber.promptTokens(for: ctx, tokenizer: FakeTokenizer())
        XCTAssertNotNil(tokens)
        XCTAssertEqual(tokens, [1, 2, 3]) // DOAC, Flightstory, gocomo → 3 words
    }

    func testPromptTokensNilForEmptyContext() {
        XCTAssertNil(WhisperKitTranscriber.promptTokens(for: TranscriptionContext(),
                                                        tokenizer: FakeTokenizer()))
    }

    func testPromptTokensNilForNilContext() {
        XCTAssertNil(WhisperKitTranscriber.promptTokens(for: nil, tokenizer: FakeTokenizer()))
    }

    /// A prompt that the tokenizer maps to an empty array yields nil (guarded so
    /// DecodingOptions.promptTokens is never set to []).
    func testPromptTokensNilWhenTokenizerReturnsEmpty() {
        struct EmptyTokenizer: WhisperPromptTokenizing { func encode(text: String) -> [Int] { [] } }
        let ctx = TranscriptionContext(prompt: "something", glossary: [], language: nil)
        XCTAssertNil(WhisperKitTranscriber.promptTokens(for: ctx, tokenizer: EmptyTokenizer()))
    }
}
