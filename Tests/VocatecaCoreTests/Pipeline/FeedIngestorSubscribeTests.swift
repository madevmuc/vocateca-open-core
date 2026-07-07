import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - FeedIngestorSubscribeTests

/// Deterministic unit tests for the subscribe-time ingest path.
///
/// These tests verify that calling the ingest pipeline (parse fixture XML →
/// upsert into StateStore) correctly populates the database with pending
/// episodes — the exact path that `IngestCoordinator.ingest(show:)` exercises.
///
/// ## Design
/// We do NOT hit the network. Instead we:
///  1. Load a committed RSS XML fixture from `Bundle.module` (same files used
///     by `OracleRSSTests`).
///  2. Run `RSSManifest.build(fromXML:)` to get `[ManifestEntry]`.
///  3. Call `StateStore.upsertEpisodeFromFeed` for each entry — the same loop
///     that `FeedIngestor.pollPodcast` executes.
///  4. Assert episode count > 0 and that all inserted rows have `status == "pending"`.
///
/// Fixture used: `Fixtures/feeds/1alage.xml` — a small German podcast with a
/// well-formed RSS 2.0 feed that exercises guid / title / pubDate / mp3URL /
/// itunes:duration fields.
final class FeedIngestorSubscribeTests: XCTestCase {

    // MARK: - Helpers (shared with FeedUpsertTests)

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedIngestorSubscribeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    /// Load the 1alage RSS fixture from `Bundle.module`.
    private func load1alageFixture() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "1alage",
            withExtension: "xml",
            subdirectory: "Fixtures/feeds"
        ) else {
            XCTFail("RSS fixture not found: Fixtures/feeds/1alage.xml")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Core ingest helper (mirrors FeedIngestor.pollPodcast loop)

    /// Parse XML → upsert all entries into `store`.
    ///
    /// This is the exact sequence performed by `FeedIngestor.pollPodcast` and
    /// therefore by `IngestCoordinator.ingest(show:)` for a podcast source.
    /// Running it here against a file-URL fixture gives deterministic coverage
    /// without any live network dependency.
    private func ingestFixture(data: Data, showSlug: String, store: StateStore) throws -> Int {
        let entries = try RSSManifest.build(fromXML: data)
        var upsertCount = 0
        for entry in entries {
            let durationSec = FeedIngestor.parseDurationSeconds(entry.duration)
            try store.upsertEpisodeFromFeed(
                showSlug: showSlug,
                guid: entry.guid,
                title: entry.title,
                pubDate: entry.pubDate,
                mp3URL: entry.mp3URL,
                durationSec: durationSec
            )
            upsertCount += 1
        }
        return upsertCount
    }

    // MARK: - Tests

    /// Ingesting the 1alage fixture produces > 0 pending episodes.
    ///
    /// This is the "subscribe triggers ingest" gate: when a user subscribes to
    /// a podcast, `IngestCoordinator.ingest(show:)` must populate the DB.
    func testIngestFixturePopulatesEpisodesAsPending() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try load1alageFixture()
        let slug = "1alage-subscribe-test"
        let count = try ingestFixture(data: data, showSlug: slug, store: store)

        XCTAssertGreaterThan(count, 0,
            "Ingesting 1alage.xml must produce at least one episode")

        // Verify every upserted episode is pending and belongs to the correct show.
        let episodes = try store.episodes(showSlug: slug)
        XCTAssertEqual(episodes.count, count,
            "DB episode count must match the upserted count")

        for ep in episodes {
            XCTAssertEqual(ep.status, "pending",
                "Every freshly-ingested episode must have status=pending (got '\(ep.status)' for '\(ep.guid)')")
            XCTAssertEqual(ep.showSlug, slug,
                "Episode show_slug must match the subscribed show")
            XCTAssertFalse(ep.guid.isEmpty,
                "Episode guid must not be empty")
            XCTAssertFalse(ep.title.isEmpty,
                "Episode title must not be empty")
        }
    }

    /// Re-ingesting the same fixture is idempotent — no duplicate rows.
    ///
    /// The Refresh action calls the same ingest path. Running it twice must not
    /// double the row count.
    func testReIngestIsIdempotent() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try load1alageFixture()
        let slug = "1alage-idempotent-test"

        let first  = try ingestFixture(data: data, showSlug: slug, store: store)
        let second = try ingestFixture(data: data, showSlug: slug, store: store)

        XCTAssertEqual(first, second,
            "Both ingest passes must report the same upsert count")

        let episodes = try store.episodes(showSlug: slug)
        XCTAssertEqual(episodes.count, first,
            "Re-ingesting must not create duplicate rows (idempotency)")
    }

    /// Episodes already in a non-pending status are not reset to pending on re-ingest.
    ///
    /// Verifies the COALESCE / pipeline-state-preservation semantics that
    /// `upsertEpisodeFromFeed` guarantees — critical for the Refresh action.
    func testReIngestPreservesInFlightStatus() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try load1alageFixture()
        let slug = "1alage-preserve-test"

        // First ingest: all episodes enter as "pending".
        let count = try ingestFixture(data: data, showSlug: slug, store: store)
        XCTAssertGreaterThan(count, 0)

        // Simulate the pipeline setting one episode to "downloading".
        let all = try store.episodes(showSlug: slug)
        let targetGUID = try XCTUnwrap(all.first?.guid, "Need at least one episode")
        var ep = try XCTUnwrap(store.episode(guid: targetGUID))
        ep.status = "downloading"
        ep.attempts = 1
        try store.upsert(ep)

        // Second ingest (Refresh): re-poll the same fixture data.
        _ = try ingestFixture(data: data, showSlug: slug, store: store)

        // The in-flight episode must NOT be reset.
        let after = try XCTUnwrap(store.episode(guid: targetGUID))
        XCTAssertEqual(after.status, "downloading",
            "Re-ingest (Refresh) must not reset an in-flight episode's status to pending")
        XCTAssertEqual(after.attempts, 1,
            "Re-ingest (Refresh) must not reset an in-flight episode's attempts counter")
    }
}
