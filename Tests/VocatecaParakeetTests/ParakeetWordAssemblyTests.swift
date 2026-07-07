import XCTest
@testable import VocatecaParakeet
import FluidAudio

/// Tests `ParakeetWordAssembly.words(from:)` against synthetic `TokenTiming`
/// values — no model load, no network. Confirms the SentencePiece `▁`
/// (U+2581) word-boundary convention: a token that begins with `▁` starts a
/// new word; tokens without it continue the current word.
final class ParakeetWordAssemblyTests: XCTestCase {

    private func timing(_ token: String, _ start: Double, _ end: Double, confidence: Float = 1.0) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
    }

    func testAssemblesWordsAcrossMultipleTokens() {
        // "Hallo" = two subword pieces ("▁Hal", "lo"); "Welt." = one piece.
        let tokens = [
            timing("▁Hal", 0.0, 0.2),
            timing("lo", 0.2, 0.4),
            timing("▁Welt.", 0.4, 0.9),
        ]
        let words = ParakeetWordAssembly.words(from: tokens)
        XCTAssertEqual(words.map(\.text), ["Hallo", "Welt."])
        XCTAssertEqual(words[0].start, 0.0)
        XCTAssertEqual(words[0].end, 0.4)
        XCTAssertEqual(words[1].start, 0.4)
        XCTAssertEqual(words[1].end, 0.9)
    }

    func testFirstTokenWithoutBoundaryMarkerStillStartsAWord() {
        // Some decoders may emit the very first token without a leading ▁.
        let tokens = [
            timing("Hi", 0.0, 0.3),
            timing("▁there", 0.3, 0.6),
        ]
        let words = ParakeetWordAssembly.words(from: tokens)
        XCTAssertEqual(words.map(\.text), ["Hi", "there"])
    }

    func testSkipsAngleBracketedSpecialTokens() {
        // Any `<…>` control token is dropped so none leaks into word text —
        // not just <blank>/<pad> but also <unk>/<sos>/<eos> and the like.
        let tokens = [
            timing("<sos>", 0.0, 0.0),
            timing("▁Hallo", 0.0, 0.4),
            timing("<blank>", 0.4, 0.4),
            timing("<pad>", 0.4, 0.4),
            timing("<unk>", 0.4, 0.4),
            timing("▁Welt", 0.4, 0.9),
            timing("<eos>", 0.9, 0.9),
        ]
        let words = ParakeetWordAssembly.words(from: tokens)
        XCTAssertEqual(words.map(\.text), ["Hallo", "Welt"])
    }

    func testEmptyInputReturnsEmptyArray() {
        XCTAssertEqual(ParakeetWordAssembly.words(from: []).count, 0)
    }
}
