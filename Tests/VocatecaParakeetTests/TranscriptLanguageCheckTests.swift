import XCTest
@testable import VocatecaParakeet

final class TranscriptLanguageCheckTests: XCTestCase {
    func testGermanTextRecognizedAsGerman() {
        let t = "Guten Tag, dies ist ein deutscher Satz über das elektronische Postfach der Behörde."
        XCTAssertTrue(TranscriptLanguageCheck.looksLike("de", text: t))
    }
    func testGermanAudioMisTranscribedAsEnglishFailsCheck() {
        let englishGarble = "good tark this is an english looking sentence about the mailbox authority"
        XCTAssertFalse(TranscriptLanguageCheck.looksLike("de", text: englishGarble))
    }
    func testCodeSwitchingGermanWithEnglishTermsStillPassesForGerman() {
        // Real LNP-style: German with English tech loanwords — must NOT falsely fail.
        let t = "Das permanente Nudging der Behörden ist mühsam, aber am Ende verschicken sie doch ein PDF."
        XCTAssertTrue(TranscriptLanguageCheck.looksLike("de", text: t))
    }
    func testShortTextIsLenient() {
        // Too little signal → don't reject (avoid needless Whisper re-runs).
        XCTAssertTrue(TranscriptLanguageCheck.looksLike("de", text: "Ja."))
    }
    func testRouteUnsupportedGoesWhisperDirect() {
        XCTAssertEqual(LanguageRoutingTranscriber.route(expected: "tr"), .whisperDirect)   // Turkish ∉ 25
        XCTAssertEqual(LanguageRoutingTranscriber.route(expected: "de"), .parakeetThenVerify)
        XCTAssertEqual(LanguageRoutingTranscriber.route(expected: nil), .parakeetThenVerify) // unknown → try Parakeet, verify
    }
}
