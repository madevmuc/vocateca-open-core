import XCTest
@testable import VocatecaCore

/// Regression: quiet-hours times are sanitized on decode. An invalid stored
/// value (e.g. a hand-edited or version-drifted "25:99") must fall back to the
/// default rather than reaching `HHmmField` and being silently normalized by
/// Calendar into a nonsense notification schedule. Unlike `dailyCheckTime` we do
/// NOT throw here — a bad quiet-hours string must not fail the whole settings
/// load and reset every other setting.
final class SettingsQuietHoursDecodeTests: XCTestCase {

    func testInvalidQuietHoursSanitizeToDefault() throws {
        let yaml = """
        notify_quiet_hours_start: "25:99"
        notify_quiet_hours_end: "not-a-time"
        """
        let settings = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(settings.notifyQuietHoursStart, Settings.defaultNotifyQuietHoursStart)
        XCTAssertEqual(settings.notifyQuietHoursEnd, Settings.defaultNotifyQuietHoursEnd)
    }

    func testValidQuietHoursPreserved() throws {
        let yaml = """
        notify_quiet_hours_start: "23:15"
        notify_quiet_hours_end: "07:45"
        """
        let settings = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(settings.notifyQuietHoursStart, "23:15")
        XCTAssertEqual(settings.notifyQuietHoursEnd, "07:45")
    }

    func testAbsentQuietHoursUseDefaults() throws {
        let settings = try SettingsStore.decode(from: "whisper_model: large-v3-turbo\n")
        XCTAssertEqual(settings.notifyQuietHoursStart, Settings.defaultNotifyQuietHoursStart)
        XCTAssertEqual(settings.notifyQuietHoursEnd, Settings.defaultNotifyQuietHoursEnd)
    }
}
