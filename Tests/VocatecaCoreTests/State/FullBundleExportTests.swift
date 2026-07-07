import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - FullBundleExportTests

/// Tests for ``ImportExportService/encodeFullBundle(settings:watchlist:episodes:exportedAt:)``
/// — the single-file "export all my data" bundle (Privacy pass, Task 4).
///
/// Covers:
/// (a) Envelope header fields (`app`, `kind`, `version`).
/// (b) Settings block present with webhook secrets blanked (redacted).
/// (c) Subscriptions block present.
/// (d) Episode metadata present (guid/title/status) and no transcript body,
///     only the on-disk `transcriptPath`.
final class FullBundleExportTests: XCTestCase {

    private let fixedTimestamp = "2026-07-02T12:00:00Z"

    // MARK: - Helpers

    private func makeSettingsWithWebhookSecret() -> Settings {
        var s = Settings()
        s.webhooksEnabled = true
        s.webhooks = [
            WebhookEntry(
                target: "https://example.com/hook",
                enabled: true,
                secret: "super-secret-hmac-key"
            )
        ]
        return s
    }

    private func makeWatchlist() -> Watchlist {
        Watchlist(shows: [
            Show(slug: "alpha-podcast", title: "Alpha Podcast", rss: "https://alpha.example.com/feed"),
        ])
    }

    private func makeEpisodes() -> [Episode] {
        [
            Episode(
                guid: "guid-1",
                showSlug: "alpha-podcast",
                title: "Episode One",
                pubDate: "2026-06-01T00:00:00Z",
                mp3Url: "https://alpha.example.com/ep1.mp3",
                status: "completed",
                transcriptPath: "/Users/test/Vocateca/Alpha/ep1.txt",
                completedAt: "2026-06-01T01:00:00Z",
                description: "Some show notes that should not leak transcript text"
            ),
            Episode(
                guid: "guid-2",
                showSlug: "alpha-podcast",
                title: "Episode Two",
                pubDate: "2026-06-08T00:00:00Z",
                mp3Url: "https://alpha.example.com/ep2.mp3",
                status: "pending"
            ),
        ]
    }

    // MARK: - Tests

    func testFullBundleEnvelopeHeaderFields() throws {
        let data = try ImportExportService.encodeFullBundle(
            settings: makeSettingsWithWebhookSecret(),
            watchlist: makeWatchlist(),
            episodes: makeEpisodes(),
            exportedAt: fixedTimestamp
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["app"] as? String, "vocateca")
        XCTAssertEqual(json["kind"] as? String, "full")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["exportedAt"] as? String, fixedTimestamp)
    }

    func testFullBundleRedactsWebhookSecret() throws {
        let data = try ImportExportService.encodeFullBundle(
            settings: makeSettingsWithWebhookSecret(),
            watchlist: makeWatchlist(),
            episodes: makeEpisodes(),
            exportedAt: fixedTimestamp
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "full")

        let full = try XCTUnwrap(payload["full"] as? [String: Any])
        let settingsBlock = try XCTUnwrap(full["settings"] as? [String: Any])
        let webhooks = try XCTUnwrap(settingsBlock["webhooks"] as? [[String: Any]])
        XCTAssertEqual(webhooks.count, 1)
        XCTAssertEqual(webhooks[0]["secret"] as? String, "",
                        "Webhook secret must be blanked in the full export bundle")
        // Sanity: the raw secret string must not appear anywhere in the file.
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("super-secret-hmac-key"),
                        "Webhook secret must not leak into the exported JSON")
    }

    func testFullBundleContainsSubscriptions() throws {
        let data = try ImportExportService.encodeFullBundle(
            settings: makeSettingsWithWebhookSecret(),
            watchlist: makeWatchlist(),
            episodes: makeEpisodes(),
            exportedAt: fixedTimestamp
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let full = try XCTUnwrap(payload["full"] as? [String: Any])
        let subscriptions = try XCTUnwrap(full["subscriptions"] as? [String: Any])
        let shows = try XCTUnwrap(subscriptions["shows"] as? [[String: Any]])
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows.first?["slug"] as? String, "alpha-podcast")
    }

    func testFullBundleContainsEpisodeMetadataOnly() throws {
        let data = try ImportExportService.encodeFullBundle(
            settings: makeSettingsWithWebhookSecret(),
            watchlist: makeWatchlist(),
            episodes: makeEpisodes(),
            exportedAt: fixedTimestamp
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let full = try XCTUnwrap(payload["full"] as? [String: Any])
        let episodes = try XCTUnwrap(full["episodes"] as? [[String: Any]])
        XCTAssertEqual(episodes.count, 2)

        let ep1 = try XCTUnwrap(episodes.first { $0["guid"] as? String == "guid-1" })
        XCTAssertEqual(ep1["showSlug"] as? String, "alpha-podcast")
        XCTAssertEqual(ep1["title"] as? String, "Episode One")
        XCTAssertEqual(ep1["status"] as? String, "completed")
        XCTAssertEqual(ep1["pubDate"] as? String, "2026-06-01T00:00:00Z")
        XCTAssertEqual(ep1["transcriptPath"] as? String, "/Users/test/Vocateca/Alpha/ep1.txt")

        // Only metadata fields are exported — no transcript body / OCR text /
        // description field must be present on the exported episode.
        XCTAssertNil(ep1["ocrText"], "Full bundle must not carry transcript/OCR bodies")
        XCTAssertNil(ep1["description"], "Full bundle must not carry the episode description")
        XCTAssertNil(ep1["transcriptText"], "Full bundle must not carry transcript text")
    }

    func testFullBundleRoundTripsThroughEnvelopeDecode() throws {
        let data = try ImportExportService.encodeFullBundle(
            settings: makeSettingsWithWebhookSecret(),
            watchlist: makeWatchlist(),
            episodes: makeEpisodes(),
            exportedAt: fixedTimestamp
        )
        let envelope = try ImportExportService.decodeEnvelope(from: data)
        XCTAssertEqual(envelope.kind, .full)
        guard case .full(let bundle) = envelope.payload else {
            return XCTFail("Expected .full payload")
        }
        XCTAssertEqual(bundle.subscriptions.shows.count, 1)
        XCTAssertEqual(bundle.episodes.count, 2)
        XCTAssertEqual(bundle.settings.webhooks.first?.secret, "",
                        "Decoded bundle must still show the redacted (blank) secret")
    }
}
