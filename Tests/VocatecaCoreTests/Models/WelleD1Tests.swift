import XCTest
import Yams
@testable import VocatecaCore

// MARK: - WelleD1Tests
//
// Focused tests for the Welle D1 Settings additions:
//   1. Instagram fetch interval HH:MM formatting (logic duplicated here as a pure function)
//   2. notifyMediaTypes default = all three; empty set = notifications off
//   3. Quiet-hours default = true
//   4. New fields decode with defaults when keys are absent (backward compat)

final class WelleD1Tests: XCTestCase {

    // MARK: - 1. HH:MM formatting

    /// Replicates the logic in InstagramCard.formatIntervalHHMM so we can test it
    /// without a UI dependency. If the implementation changes, this test must change too.
    private func hhMM(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%02d:%02d", h, m)
    }

    func testFormatIntervalHHMM_6h() {
        XCTAssertEqual(hhMM(360), "06:00", "360 min should format as 06:00")
    }

    func testFormatIntervalHHMM_30min() {
        XCTAssertEqual(hhMM(30), "00:30")
    }

    func testFormatIntervalHHMM_24h() {
        XCTAssertEqual(hhMM(1440), "24:00")
    }

    func testFormatIntervalHHMM_90min() {
        XCTAssertEqual(hhMM(90), "01:30")
    }

    // MARK: - 2. notifyMediaTypes semantics

    func testDefaultNotifyMediaTypesContainsAllThree() {
        let s = Settings()
        XCTAssertTrue(s.notifyMediaTypes.contains("podcast"))
        XCTAssertTrue(s.notifyMediaTypes.contains("youtube"))
        XCTAssertTrue(s.notifyMediaTypes.contains("instagram"))
    }

    func testEmptyNotifyMediaTypesIsStoredCorrectly() {
        var s = Settings()
        s.notifyMediaTypes = []
        // Semantics: empty set == notifications off (UI shows "Off" for empty array).
        XCTAssertTrue(s.notifyMediaTypes.isEmpty)
    }

    // MARK: - 3. Quiet-hours default

    func testQuietHoursDefaultIsTrue() {
        XCTAssertTrue(Settings.defaultNotifyQuietHoursEnabled,
                      "quiet hours should default to ON per Welle D1 spec")
        XCTAssertTrue(Settings().notifyQuietHoursEnabled)
    }

    // MARK: - 4. Backward-compatible decode (missing keys → defaults)

    func testDecodeOldSettingsYamlMissingWelleD1Keys() throws {
        // A minimal YAML that contains none of the Welle D1 keys.
        // All new fields must silently fall back to their defaults.
        let yaml = "output_root: ~/Desktop/Vocateca/transcripts\n"

        // Write to a temp file and load via SettingsStore so the full
        // migration + default pipeline runs (same path as production).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("welle_d1_test_\(UUID().uuidString).yaml")
        try yaml.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let decoded = try SettingsStore.load(from: tmp, persistDefaultOnMissing: false)
        XCTAssertEqual(decoded.instagramFetchIntervalMinutes,
                       Settings.defaultInstagramFetchIntervalMinutes,
                       "instagramFetchIntervalMinutes should default to 360")
        XCTAssertEqual(decoded.notifyMediaTypes,
                       Settings.defaultNotifyMediaTypes,
                       "notifyMediaTypes should default to all three types")
        XCTAssertEqual(decoded.youtubeIncludeVideosDefault,
                       Settings.defaultYoutubeIncludeVideosDefault,
                       "youtubeIncludeVideosDefault should default to true")
        XCTAssertEqual(decoded.notifyQuietHoursEnabled,
                       Settings.defaultNotifyQuietHoursEnabled,
                       "notifyQuietHoursEnabled should default to true")
    }
}
