import XCTest
@testable import VocatecaCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(Vocateca.version, "2.0.0")
    }

    func testUserDataDirEndsWithVocateca() {
        XCTAssertEqual(Paths.userDataDir().lastPathComponent, "Vocateca")
    }
}
