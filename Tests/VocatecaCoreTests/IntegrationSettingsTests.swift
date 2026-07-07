import XCTest
@testable import VocatecaCore

final class IntegrationSettingsTests: XCTestCase {
    // New Notion fields default correctly when absent from YAML.
    func testNotionFieldsDefaultWhenAbsent() throws {
        let yaml = "output_root: /tmp/x\n"                     // no notion_* keys
        let s = try SettingsStore.decode(from: yaml)
        XCTAssertFalse(s.notionEnabled)
        XCTAssertFalse(s.notionAutoPush)
        XCTAssertEqual(s.notionDatabaseId, "")
    }

    // Legacy webhook entries (no `format`) decode to format == "raw".
    func testLegacyWebhookEntryDefaultsToRawFormat() throws {
        let entry = try JSONDecoder().decode(
            WebhookEntry.self,
            from: Data(#"{"events":["episode.transcribed"],"target":"https://x"}"#.utf8))
        XCTAssertEqual(entry.format, "raw")
    }

    // Round-trip: new fields survive encode→decode.
    func testNotionFieldsRoundTrip() throws {
        var s = Settings()
        s.notionEnabled = true
        s.notionDatabaseId = "db123"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(back.notionEnabled)
        XCTAssertEqual(back.notionDatabaseId, "db123")
    }
}
