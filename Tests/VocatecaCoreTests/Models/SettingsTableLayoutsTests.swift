import XCTest
@testable import VocatecaCore

/// Tables Task 4 — `Settings.tableLayouts` round-trips through settings YAML.
final class SettingsTableLayoutsTests: XCTestCase {

    func testTableLayoutsDefaultIsEmpty() {
        XCTAssertEqual(Settings().tableLayouts, [:])
    }

    func testAbsentKeyDecodesToEmpty() throws {
        // A minimal YAML without `table_layouts` must fall back to the default.
        let settings = try SettingsStore.decode(from: "whisper_model: large-v3-turbo\n")
        XCTAssertEqual(settings.tableLayouts, [:])
    }

    func testTableLayoutsYAMLRoundTrip() throws {
        var s = Settings()
        s.tableLayouts = [
            "shows": TableLayout(
                columns: [
                    ColumnState(id: "title", visible: true, width: 240, order: 0),
                    ColumnState(id: "added", visible: false, width: 110, order: 1),
                ],
                sort: SortState(columnID: "added", ascending: false)
            )
        ]

        let yaml = try SettingsStore.yamlString(s)
        let decoded = try SettingsStore.decode(from: yaml)

        XCTAssertEqual(decoded.tableLayouts, s.tableLayouts)
        XCTAssertTrue(yaml.contains("table_layouts"), "YAML must use the snake_case key")
    }

    /// Regression: a MALFORMED `table_layouts` blob (e.g. after a column-schema
    /// change across app versions) must fall back to defaults WITHOUT failing the
    /// whole settings decode — otherwise LiveDataLoader falls back to `Settings()`
    /// and silently resets every other setting too.
    func testMalformedTableLayoutsFallsBackWithoutLosingOtherSettings() throws {
        let yaml = """
        whisper_model: tiny
        table_layouts:
          shows: "this is not a valid layout"
        """
        let settings = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(settings.tableLayouts, [:],
                       "a malformed layouts blob must fall back to the default")
        XCTAssertEqual(settings.whisperModel, "tiny",
                       "a malformed layouts blob must NOT reset unrelated settings")
    }
}
