import XCTest
@testable import VocatecaParakeet

final class ParakeetLanguagesTests: XCTestCase {
    func testSupportedIncludesCoreEUAndEnglish() {
        for code in ["de", "en", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk"] {
            XCTAssertTrue(ParakeetLanguages.supports(code), "\(code) should be supported")
        }
    }
    func testUnsupportedLanguagesRejected() {
        for code in ["tr", "ja", "zh", "ar", "hi", "no", "ko"] {
            XCTAssertFalse(ParakeetLanguages.supports(code), "\(code) must route to Whisper")
        }
    }
    func testRegionTagAndCasingNormalized() {
        XCTAssertTrue(ParakeetLanguages.supports("de-DE"))
        XCTAssertTrue(ParakeetLanguages.supports("EN"))
    }
    func testNilIsNotClaimedAsSupported() {
        XCTAssertFalse(ParakeetLanguages.supports(nil))  // unknown → caller decides, not a hard "yes"
    }
}
