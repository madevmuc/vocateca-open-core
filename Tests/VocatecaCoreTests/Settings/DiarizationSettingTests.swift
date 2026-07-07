import XCTest
@testable import VocatecaCore

/// Package D (speaker diarization) Task 6: `Settings.diarizationEnabled`
/// decodes/round-trips like every other Codable setting (mirrors
/// `transcriptionEngine`'s four-site wiring) and defaults to `true`.
/// Class name is unique so `swift test --filter DiarizationSettingTests`
/// selects exactly these.
final class DiarizationSettingTests: XCTestCase {

    /// An empty YAML document must yield the compiled-in default (`true`).
    func testEmptyYAMLYieldsDefaultTrue() throws {
        // `{}` is a valid empty YAML mapping — decodeIfPresent misses the key,
        // so diarization_enabled falls back to its default.
        let s = try SettingsStore.decode(from: "{}")
        XCTAssertEqual(s.diarizationEnabled, true)
        XCTAssertEqual(Settings.defaultDiarizationEnabled, true)
    }

    /// An explicit `false` overrides the (true) default — proves the decode
    /// path actually reads the key rather than always returning the default.
    func testExplicitFalseDecodes() throws {
        let yaml = """
        diarization_enabled: false
        """
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s.diarizationEnabled, false)
    }

    /// The value survives an encode → decode round-trip through the real store,
    /// for both the non-default (false) and default (true) values.
    func testRoundTripsThroughYamlString() throws {
        let s1 = Settings(diarizationEnabled: false)
        let yaml = try SettingsStore.yamlString(s1)
        XCTAssertTrue(yaml.contains("diarization_enabled"),
                      "YAML should carry the snake_case key: \(yaml)")
        let s2 = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s2.diarizationEnabled, false)
        XCTAssertEqual(s1, s2, "Round-trip broke equality")

        let s3 = Settings(diarizationEnabled: true)
        let yaml2 = try SettingsStore.yamlString(s3)
        let s4 = try SettingsStore.decode(from: yaml2)
        XCTAssertEqual(s4.diarizationEnabled, true)
        XCTAssertEqual(s3, s4, "Round-trip broke equality")
    }
}
