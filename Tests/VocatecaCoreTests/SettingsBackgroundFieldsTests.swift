import XCTest
@testable import VocatecaCore

final class SettingsBackgroundFieldsTests: XCTestCase {
    func testDefaults() {
        let s = Settings()
        XCTAssertTrue(s.runInBackground)            // default ON
        XCTAssertFalse(s.hideDockIconInBackground)  // Dock icon shown by default
    }

    func testDecodeFromYAMLOverridesDefaults() throws {
        let yaml = "run_in_background: false\nhide_dock_icon_in_background: true\n"
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertFalse(s.runInBackground)
        XCTAssertTrue(s.hideDockIconInBackground)
    }

    func testMissingKeysUseDefaults() throws {
        let s = try SettingsStore.decode(from: "output_root: /tmp/x\n")
        XCTAssertTrue(s.runInBackground)
        XCTAssertFalse(s.hideDockIconInBackground)
    }
}
