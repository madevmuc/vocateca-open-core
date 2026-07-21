import XCTest
import Yams
@testable import VocatecaCore

final class SettingsYouTubeExplorerFieldsTests: XCTestCase {

    func testDefaults() {
        XCTAssertEqual(Settings().youtubeCopyFormat, "txt")
    }

    func testMemberwiseInitOverrides() {
        XCTAssertEqual(Settings(youtubeCopyFormat: "vtt").youtubeCopyFormat, "vtt")
    }

    func testDecodeMissingKeysFallBackToDefaults() throws {
        let decoded = try YAMLDecoder().decode(Settings.self, from: "output_root: /tmp/out\n")
        XCTAssertEqual(decoded.youtubeCopyFormat, "txt")
    }

    func testDecodeRoundTrip() throws {
        let decoded = try YAMLDecoder().decode(Settings.self, from: "youtube_copy_format: srt\n")
        XCTAssertEqual(decoded.youtubeCopyFormat, "srt")
    }

    /// `youtube_explorer_enabled` gated a sidebar tab that no longer exists, so
    /// the field is gone. Every settings.yaml written before that still has the
    /// key, and finding one must not stop the app from loading its settings.
    func testRetiredExplorerToggleInAnOldSettingsFileIsIgnored() throws {
        let yaml = """
        youtube_explorer_enabled: true
        youtube_copy_format: srt
        """
        let decoded = try YAMLDecoder().decode(Settings.self, from: yaml)
        XCTAssertEqual(decoded.youtubeCopyFormat, "srt",
                       "a retired key must be skipped, not abort the decode of the keys around it")
    }
}
