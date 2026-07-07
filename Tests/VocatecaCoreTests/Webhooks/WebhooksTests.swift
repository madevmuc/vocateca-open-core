import XCTest
@testable import VocatecaCore

/// Webhooks (#6) Core — payload / signing / routing (pure).
final class WebhooksTests: XCTestCase {

    private func event(_ type: String) -> Event {
        Event(type: type, showSlug: "myshow", guid: "g1", payload: ["title": .string("Hi")])
    }

    // MARK: - Routing

    func testEndpointsMatchEnabledAndSubscribed() {
        let hooks = [
            WebhookEntry(events: ["episode.transcribed"], target: "https://a", enabled: true, id: "a"),
            WebhookEntry(events: ["episode.transcribed"], target: "https://b", enabled: false, id: "b"), // disabled
            WebhookEntry(events: ["episode.failed"], target: "https://c", enabled: true, id: "c"),        // other event
        ]
        let matched = Webhooks.endpoints(matching: event("episode.transcribed"), in: hooks)
        XCTAssertEqual(matched.map(\.id), ["a"])
    }

    // MARK: - Signature

    func testSignatureIsDeterministicAndFormatted() {
        let body = Data("hello".utf8)
        let s1 = Webhooks.signature(body: body, secret: "sekret")
        let s2 = Webhooks.signature(body: body, secret: "sekret")
        XCTAssertEqual(s1, s2)
        XCTAssertTrue(s1.hasPrefix("sha256="))
        XCTAssertEqual(s1.dropFirst("sha256=".count).count, 64)  // hex SHA-256
        XCTAssertNotEqual(s1, Webhooks.signature(body: body, secret: "different"))
    }

    // MARK: - Payload

    func testJSONBodyContainsEnvelopeFieldsAndIsDeterministic() throws {
        let ev = event("episode.transcribed")
        let b1 = Webhooks.jsonBody(for: ev, deliveryID: "d1", occurredAt: "2026-07-01T00:00:00Z")
        let b2 = Webhooks.jsonBody(for: ev, deliveryID: "d1", occurredAt: "2026-07-01T00:00:00Z")
        XCTAssertEqual(b1, b2, "sorted-keys output must be byte-stable")

        let obj = try JSONSerialization.jsonObject(with: b1) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "episode.transcribed")
        XCTAssertEqual(obj?["id"] as? String, "d1")
        XCTAssertEqual(obj?["occurredAt"] as? String, "2026-07-01T00:00:00Z")
        XCTAssertEqual((obj?["show"] as? [String: Any])?["slug"] as? String, "myshow")
        XCTAssertEqual((obj?["episode"] as? [String: Any])?["guid"] as? String, "g1")
    }
}
