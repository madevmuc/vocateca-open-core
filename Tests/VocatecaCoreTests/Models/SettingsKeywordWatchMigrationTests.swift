import XCTest
@testable import VocatecaCore

/// Watchlist (#5) — `Settings.keywordWatch` migration from legacy `[String]`.
final class SettingsKeywordWatchMigrationTests: XCTestCase {

    func testLegacyStringArrayMigratesToTerms() throws {
        let yaml = "keyword_watch:\n  - swift\n  - rust\n"
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(s.keywordWatch.map(\.term), ["swift", "rust"])
        XCTAssertTrue(s.keywordWatch.allSatisfy { !$0.isRegex && $0.enabled })
    }

    func testAbsentIsEmpty() throws {
        let s = try SettingsStore.decode(from: "whisper_model: large-v3-turbo\n")
        XCTAssertTrue(s.keywordWatch.isEmpty)
    }

    func testNewShapeRoundTrips() throws {
        var s = Settings()
        s.keywordWatch = [
            WatchTerm(id: "a", term: "swift", isRegex: false, enabled: true, notify: true, createdAt: "2026-07-01"),
            WatchTerm(id: "b", term: "\\d+", isRegex: true, enabled: false, notify: false, createdAt: "2026-07-01"),
        ]
        let yaml = try SettingsStore.yamlString(s)
        let decoded = try SettingsStore.decode(from: yaml)
        XCTAssertEqual(decoded.keywordWatch, s.keywordWatch)
    }
}
