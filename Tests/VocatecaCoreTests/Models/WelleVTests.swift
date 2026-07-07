import XCTest
import Yams
@testable import VocatecaCore

// MARK: - WelleVTests
//
// Focused tests for the Welle V Settings additions:
//   1. StartupTabResolver — pure resolution logic
//   2. Settings model — openOnLastUsedTab / startupTab defaults
//   3. Settings model — YAML backward compat (new keys absent → defaults)

final class WelleVTests: XCTestCase {

    // MARK: - 1. StartupTabResolver

    func testResolver_openOnLastUsed_returnsLastUsed() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: true,
            lastUsed: "Queue",
            explicitTab: "Shows"
        )
        XCTAssertEqual(result, "Queue")
    }

    func testResolver_openOnLastUsed_nilLastUsed_returnsFallback() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: true,
            lastUsed: nil,
            explicitTab: "Library"
        )
        XCTAssertEqual(result, "Shows", "nil lastUsed should fall back to the default fallback")
    }

    func testResolver_openOnLastUsed_emptyLastUsed_returnsFallback() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: true,
            lastUsed: "",
            explicitTab: "Library"
        )
        XCTAssertEqual(result, "Shows", "empty lastUsed should fall back to the default fallback")
    }

    func testResolver_explicitTab_usesExplicitTab() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: false,
            lastUsed: "Queue",
            explicitTab: "Library"
        )
        XCTAssertEqual(result, "Library", "when openOnLastUsed=false, explicitTab must be used")
    }

    func testResolver_explicitTab_ignoresLastUsed() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: false,
            lastUsed: "Failed",
            explicitTab: "Creators"
        )
        XCTAssertEqual(result, "Creators")
    }

    func testResolver_emptyExplicitTab_returnsFallback() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: false,
            lastUsed: nil,
            explicitTab: ""
        )
        XCTAssertEqual(result, "Shows")
    }

    func testResolver_customFallback() {
        let result = StartupTabResolver.resolve(
            openOnLastUsed: true,
            lastUsed: nil,
            explicitTab: "",
            fallback: "Library"
        )
        XCTAssertEqual(result, "Library")
    }

    // MARK: - 2. Settings defaults

    func testDefaultOpenOnLastUsedTab() {
        let s = Settings()
        XCTAssertTrue(s.openOnLastUsedTab, "openOnLastUsedTab should default to true")
    }

    func testDefaultStartupTab() {
        let s = Settings()
        XCTAssertEqual(s.startupTab, "Shows", "startupTab should default to \"Shows\"")
    }

    // MARK: - 3. YAML backward compatibility

    func testDecodeWithoutWelleVKeys_fallsBackToDefaults() throws {
        let yaml = """
        output_root: ~/Desktop/Vocateca/transcripts
        daily_check_time: "09:00"
        """
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertTrue(s.openOnLastUsedTab,
                      "openOnLastUsedTab must default to true when key absent in YAML")
        XCTAssertEqual(s.startupTab, "Shows",
                       "startupTab must default to \"Shows\" when key absent in YAML")
    }

    func testDecodeWithWelleVKeys_usesStoredValues() throws {
        let yaml = """
        output_root: ~/Desktop/Vocateca/transcripts
        daily_check_time: "09:00"
        open_on_last_used_tab: false
        startup_tab: Library
        """
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertFalse(s.openOnLastUsedTab)
        XCTAssertEqual(s.startupTab, "Library")
    }
}
