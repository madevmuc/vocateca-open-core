import XCTest
@testable import VocatecaCore

final class UpdateCheckerTests: XCTestCase {

    func testNormalizeTag() {
        XCTAssertEqual(UpdateChecker.normalizeTag("v2.0.0"), "2.0.0")
        XCTAssertEqual(UpdateChecker.normalizeTag("V1.5"), "1.5")
        XCTAssertEqual(UpdateChecker.normalizeTag("  2.1.3 "), "2.1.3")
        XCTAssertEqual(UpdateChecker.normalizeTag("2.0.0"), "2.0.0")
    }

    func testCompareNewer() {
        XCTAssertTrue(UpdateChecker.compare("2.0.1", isNewerThan: "2.0.0"))
        XCTAssertTrue(UpdateChecker.compare("2.1.0", isNewerThan: "2.0.9"))
        XCTAssertTrue(UpdateChecker.compare("3.0.0", isNewerThan: "2.9.9"))
        XCTAssertTrue(UpdateChecker.compare("v2.0.1", isNewerThan: "2.0.0"))
    }

    func testCompareNotNewer() {
        XCTAssertFalse(UpdateChecker.compare("2.0.0", isNewerThan: "2.0.0"))
        XCTAssertFalse(UpdateChecker.compare("2.0.0", isNewerThan: "2.0.1"))
        XCTAssertFalse(UpdateChecker.compare("1.9.9", isNewerThan: "2.0.0"))
        XCTAssertFalse(UpdateChecker.compare("", isNewerThan: "2.0.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertFalse(UpdateChecker.compare("2.1", isNewerThan: "2.1.0"))
        XCTAssertTrue(UpdateChecker.compare("2.1.1", isNewerThan: "2.1"))
        XCTAssertFalse(UpdateChecker.compare("2", isNewerThan: "2.0.0"))
    }

    func testNonNumericComponentsCompareAsZero() {
        // "2.0.x" -> [2,0,0]; equal to 2.0.0, not newer.
        XCTAssertFalse(UpdateChecker.compare("2.0.x", isNewerThan: "2.0.0"))
    }
}
