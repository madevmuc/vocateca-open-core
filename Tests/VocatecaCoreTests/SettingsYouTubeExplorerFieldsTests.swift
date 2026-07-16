import XCTest
import Yams
@testable import VocatecaCore

final class SettingsYouTubeExplorerFieldsTests: XCTestCase {

    func testDefaults() {
        let s = Settings()
        XCTAssertEqual(s.youtubeExplorerEnabled, true)   // default ON (ships enabled)
        XCTAssertEqual(s.youtubeCopyFormat, "txt")
    }

    func testMemberwiseInitOverrides() {
        let s = Settings(youtubeExplorerEnabled: true, youtubeCopyFormat: "vtt")
        XCTAssertEqual(s.youtubeExplorerEnabled, true)
        XCTAssertEqual(s.youtubeCopyFormat, "vtt")
    }

    func testDecodeMissingKeysFallBackToDefaults() throws {
        let yaml = "output_root: /tmp/out\n"
        let decoded = try YAMLDecoder().decode(Settings.self, from: yaml)
        XCTAssertEqual(decoded.youtubeExplorerEnabled, true)   // absent key → default (now ON)
        XCTAssertEqual(decoded.youtubeCopyFormat, "txt")
    }

    func testDecodeRoundTrip() throws {
        let yaml = """
        youtube_explorer_enabled: true
        youtube_copy_format: srt
        """
        let decoded = try YAMLDecoder().decode(Settings.self, from: yaml)
        XCTAssertEqual(decoded.youtubeExplorerEnabled, true)
        XCTAssertEqual(decoded.youtubeCopyFormat, "srt")
    }
}
