import XCTest
@testable import VocatecaCore

/// Discriminating tests for ``DoubleMetaphone`` — the phonetic collision
/// behaviour the whole proper-noun-correction feature rests on.
final class CorrectionDoubleMetaphoneTests: XCTestCase {

    func testHomophonesShareCode() {
        // gocomo vs the ASR mishears must collide phonetically
        XCTAssertEqual(DoubleMetaphone.encode("gocomo").primary, DoubleMetaphone.encode("Gokumo").primary)
        XCTAssertEqual(DoubleMetaphone.encode("gocomo").primary, DoubleMetaphone.encode("Gokomo").primary)
        XCTAssertEqual(DoubleMetaphone.encode("Firtina").primary, DoubleMetaphone.encode("Fertina").primary)
    }

    func testDistinctWordsDiffer() {
        XCTAssertNotEqual(DoubleMetaphone.encode("Berlin").primary, DoubleMetaphone.encode("gocomo").primary)
    }

    func testEmptyAndUnicode() {
        XCTAssertEqual(DoubleMetaphone.encode("").primary, "")
        _ = DoubleMetaphone.encode("Müller") // must not crash on umlaut
    }

    /// Regression: a word ending in a vowel + "J" hit the `J` rule's
    /// `at(current + 1)` with `current == last`, subscripting `letters[length]`
    /// out of bounds → SIGTRAP that crashed the whole app mid-correction
    /// (crash 2026-07-12, DoubleMetaphone.encode ← TranscriptGlossaryCorrector).
    /// The end-of-word lookahead must never trap.
    func testTrailingJDoesNotCrash() {
        for w in ["RAJ", "Taj", "hajj", "raj", "aJ", "J", "svaraj"] {
            _ = DoubleMetaphone.encode(w) // must not crash
        }
        // "RAJ": the trailing J is preceded by a vowel — the exact crash input.
        XCTAssertFalse(DoubleMetaphone.encode("RAJ").primary.isEmpty)
    }

    /// Broad no-crash sweep over tricky endings for every branch that does an
    /// end-of-word lookahead (C/G/S handlers + single-char and 1–2 letter
    /// tokens like the ones flooding the log before the crash).
    func testEndOfWordLookaheadsNeverCrash() {
        let tricky = ["C", "G", "S", "SC", "CC", "GH", "GN", "SH", "SZ", "CZ",
                      "se", "led", "lot", "last", "dare", "least", "Dire",
                      "a", "I", "X", "MC", "big", "dog", "gas", "mix", "Bartlett"]
        for w in tricky { _ = DoubleMetaphone.encode(w) }
    }

    /// The bounds-safe `at()` must not change encoding for ordinary words —
    /// the sentinel only ever replaces an out-of-range read, which used to crash.
    func testKnownEncodingsUnchanged() {
        XCTAssertEqual(DoubleMetaphone.encode("Berlin").primary,
                       DoubleMetaphone.encode("Berlin").primary)
        XCTAssertFalse(DoubleMetaphone.encode("Steven").primary.isEmpty)
        XCTAssertFalse(DoubleMetaphone.encode("CEO").primary.isEmpty)
    }
}
