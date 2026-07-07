import XCTest
@testable import VocatecaCore

final class WebhookFormatTests: XCTestCase {
    private func event() -> Event {
        Event(type: "episode.transcribed", showSlug: "my-show", guid: "g1",
              payload: ["title": .string("Ep 1")])
    }
    func testRawIsThePayloadJSON() throws {
        let body = WebhookFormat.body(for: event(), format: "raw")
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "episode.transcribed")   // full envelope
    }
    func testSlackWrapsInTextField() throws {
        let body = WebhookFormat.body(for: event(), format: "slack")
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNotNil(obj?["text"])
        XCTAssertTrue((obj?["text"] as? String ?? "").contains("episode.transcribed"))
    }
    func testDiscordUsesContentField() throws {
        let obj = try JSONSerialization.jsonObject(
            with: WebhookFormat.body(for: event(), format: "discord")) as? [String: Any]
        XCTAssertNotNil(obj?["content"])
    }
    func testUnknownFormatFallsBackToRaw() throws {
        let raw  = WebhookFormat.body(for: event(), format: "raw")
        let junk = WebhookFormat.body(for: event(), format: "nonsense")
        XCTAssertEqual(raw, junk)
    }
    func testPresetsHaveExpectedFormats() {
        let byName = Dictionary(uniqueKeysWithValues: WebhookPresets.all.map { ($0.name, $0) })
        XCTAssertEqual(byName["Slack"]?.entry.format, "slack")
        XCTAssertEqual(byName["Discord"]?.entry.format, "discord")
        XCTAssertEqual(byName["n8n"]?.entry.format, "raw")
    }
}
