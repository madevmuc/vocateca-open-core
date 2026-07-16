import XCTest
@testable import VocatecaCore

/// Guards the stale per-show language pin that forced a wrong-language
/// re-transcription (2026-07-16): "The Diary Of A CEO" (an English feed) carried
/// `language: de` from the long-removed hardcoded `Show.defaultLanguage = "de"`.
final class LanguagePinTests: XCTestCase {

    // MARK: - Show.primaryLanguageSubtag

    func testPrimaryLanguageSubtagStripsRegionAndCase() {
        XCTAssertEqual(Show.primaryLanguageSubtag("de-DE"), "de")
        XCTAssertEqual(Show.primaryLanguageSubtag("en_US"), "en")
        XCTAssertEqual(Show.primaryLanguageSubtag("EN"), "en")
        XCTAssertEqual(Show.primaryLanguageSubtag("  pt-BR "), "pt")
        XCTAssertEqual(Show.primaryLanguageSubtag(""), "")
    }

    // MARK: - Show.languagePinConflicts

    func testPinConflictsWhenFeedDeclaresADifferentLanguage() {
        XCTAssertTrue(Show.languagePinConflicts(pinned: "de", declared: "en"))
        XCTAssertTrue(Show.languagePinConflicts(pinned: "de", declared: "en-US"))
    }

    func testRegionOnlyDifferenceIsNotAConflict() {
        XCTAssertFalse(Show.languagePinConflicts(pinned: "de", declared: "de-AT"))
        XCTAssertFalse(Show.languagePinConflicts(pinned: "de-DE", declared: "de"))
    }

    /// Auto-detect can never be wrong, and a feed that declares nothing is no
    /// evidence — neither may trigger a reset.
    func testAutoPinAndSilentFeedNeverConflict() {
        XCTAssertFalse(Show.languagePinConflicts(pinned: "", declared: "en"))
        XCTAssertFalse(Show.languagePinConflicts(pinned: "auto", declared: "en"))
        XCTAssertFalse(Show.languagePinConflicts(pinned: "de", declared: ""))
    }
}
