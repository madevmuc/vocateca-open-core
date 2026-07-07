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
}
