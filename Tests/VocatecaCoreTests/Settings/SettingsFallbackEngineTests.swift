import XCTest
@testable import VocatecaCore

/// Package C: `Settings.fallbackEngine` decodes/round-trips like every other
/// string setting (mirrors `transcriptionEngine`). Class name is unique so
/// `swift test --filter SettingsFallbackEngineTests` selects exactly these.
final class SettingsFallbackEngineTests: XCTestCase {

    /// An empty YAML document must yield the compiled-in default ("whisper").
    func testEmptyYAMLYieldsDefault() throws {
        // `{}` is a valid empty YAML mapping — decodeIfPresent misses every key,
        // so fallback_engine falls back to its default.
        let s = try SettingsStore.decode(from: "{}")
        XCTAssertEqual(s.fallbackEngine, "whisper")
        XCTAssertEqual(Settings.defaultFallbackEngine, "whisper")
    }

    /// An explicit value overrides the default.
    func testExplicitValueDecodes() throws {
        let yaml = """
        fallback_engine: "qwen"
        """
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s.fallbackEngine, "qwen")
    }

    /// The value survives an encode → decode round-trip through the real store.
    func testRoundTripsThroughYamlString() throws {
        let s1 = Settings(fallbackEngine: "parakeet")
        let yaml = try SettingsStore.yamlString(s1)
        XCTAssertTrue(yaml.contains("fallback_engine"),
                      "YAML should carry the snake_case key: \(yaml)")
        let s2 = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s2.fallbackEngine, "parakeet")
        XCTAssertEqual(s1, s2, "Round-trip broke equality")
    }
}
