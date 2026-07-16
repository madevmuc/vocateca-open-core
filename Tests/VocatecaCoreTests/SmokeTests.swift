import XCTest
@testable import VocatecaCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        // `Vocateca.version` is read live from the bundle's
        // CFBundleShortVersionString (host-dependent under `swift test`) with a
        // dev fallback — so assert it resolves to a non-empty version string
        // rather than a hardcoded release number.
        XCTAssertFalse(Vocateca.version.isEmpty)
    }

    func testUserDataDirEndsWithVocateca() {
        XCTAssertEqual(Paths.userDataDir().lastPathComponent, "Vocateca")
    }
}
