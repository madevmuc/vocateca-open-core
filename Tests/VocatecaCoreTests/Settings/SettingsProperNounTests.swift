import XCTest
@testable import VocatecaCore

/// Task 4: `Settings.properNounCorrection` decodes/round-trips like every other
/// string setting (mirrors `transcriptionEngine`). Class name is unique so
/// `swift test --filter SettingsProperNounTests` selects exactly these.
final class SettingsProperNounTests: XCTestCase {

    /// An empty YAML document must yield the compiled-in default.
    func testEmptyYAMLYieldsDefault() throws {
        // `{}` is a valid empty YAML mapping — decodeIfPresent misses every key,
        // so every field (incl. proper_noun_correction) falls back to its default.
        let s = try SettingsStore.decode(from: "{}")
        XCTAssertEqual(s.properNounCorrection, "conservative")
        XCTAssertEqual(Settings.defaultProperNounCorrection, "conservative")
    }

    /// An explicit value overrides the default.
    func testExplicitValueDecodes() throws {
        let yaml = """
        proper_noun_correction: "off"
        """
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s.properNounCorrection, "off")
    }

    /// The value survives an encode → decode round-trip through the real store.
    func testRoundTripsThroughYamlString() throws {
        let s1 = Settings(properNounCorrection: "aggressive")
        let yaml = try SettingsStore.yamlString(s1)
        XCTAssertTrue(yaml.contains("proper_noun_correction"),
                      "YAML should carry the snake_case key: \(yaml)")
        let s2 = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s2.properNounCorrection, "aggressive")
        XCTAssertEqual(s1, s2, "Round-trip broke equality")
    }
}
