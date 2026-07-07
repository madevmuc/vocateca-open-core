import XCTest
@testable import VocatecaCore

/// Battery spec step 2 — `Settings.batteryPolicy` field + migration from the
/// legacy `pause_queue_on_battery` key.
final class BatterySettingsMigrationTests: XCTestCase {

    func testFreshInstallDefaultsToFinishThenPause() throws {
        // No battery keys at all → default policy.
        let s = try SettingsStore.decode(from: "whisper_model: large-v3-turbo\n")
        XCTAssertEqual(s.batteryPolicy, BatteryPolicy.finishThenPause.rawValue)
    }

    func testLegacyPauseTrueMigratesToFinishThenPause() throws {
        let s = try SettingsStore.decode(from: "pause_queue_on_battery: true\n")
        XCTAssertEqual(s.batteryPolicy, BatteryPolicy.finishThenPause.rawValue)
    }

    func testLegacyPauseFalseMigratesToNormal() throws {
        let s = try SettingsStore.decode(from: "pause_queue_on_battery: false\n")
        XCTAssertEqual(s.batteryPolicy, BatteryPolicy.normal.rawValue)
    }

    func testExplicitBatteryPolicyWins() throws {
        // Even with a legacy key present, an explicit battery_policy is authoritative.
        let yaml = "pause_queue_on_battery: true\nbattery_policy: mains_only\n"
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s.batteryPolicy, BatteryPolicy.mainsOnly.rawValue)
    }

    func testRoundTrip() throws {
        var s = Settings()
        s.batteryPolicy = BatteryPolicy.mainsOnly.rawValue
        let yaml = try SettingsStore.yamlString(s)
        XCTAssertTrue(yaml.contains("battery_policy"))
        let decoded = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(decoded.batteryPolicy, BatteryPolicy.mainsOnly.rawValue)
    }
}
