import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - FakeDescriptionFetcher

/// A test-only `DescriptionFetcher` that returns pre-programmed descriptions.
final class FakeDescriptionFetcher: DescriptionFetcher, @unchecked Sendable {

    /// Map from episode guid → description string.
    /// If the guid is not in the map, `fetchDescription` returns `nil`.
    var descriptions: [String: String]

    /// How many times `fetchDescription` was called, keyed by guid.
    private let lock = NSLock()
    private var _callCounts: [String: Int] = [:]
    var callCounts: [String: Int] { lock.withLock { _callCounts } }

    init(descriptions: [String: String] = [:]) {
        self.descriptions = descriptions
    }

    func fetchDescription(for episode: Episode) async throws -> String? {
        lock.withLock { _callCounts[episode.guid, default: 0] += 1 }
        return descriptions[episode.guid]
    }
}

// MARK: - DescriptionBackfillTests

/// Tests for ``DescriptionBackfill``.
///
/// All tests use a temp `StateStore` (v2 schema) with injected `FakeDescriptionFetcher`.
/// No network access.
final class DescriptionBackfillTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a temp `StateStore` with the v2 schema.
    private func makeTempStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DescriptionBackfillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir)
    }

    /// Creates a minimal `Episode` for insertion into the store.
    private func makeEpisode(
        guid: String,
        showSlug: String = "test-show",
        description: String? = nil
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: "Episode \(guid)",
            pubDate: "2026-01-01T00:00:00",
            mp3Url: "https://example.com/\(guid).mp3",
            description: description
        )
    }

    // MARK: - Tests

    /// Fetcher is called for episodes with nil description; resulting description is written.
    func testBackfillWritesDescriptionForNilEpisodes() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed two episodes with no description.
        let ep1 = makeEpisode(guid: "g1", description: nil)
        let ep2 = makeEpisode(guid: "g2", description: nil)
        try store.upsert(ep1)
        try store.upsert(ep2)

        // Fake fetcher returns descriptions for both guids.
        let fetcher = FakeDescriptionFetcher(descriptions: [
            "g1": "Description for episode 1",
            "g2": "Description for episode 2",
        ])

        let backfill = DescriptionBackfill(store: store, fetcher: fetcher)
        let result = await backfill.run()

        XCTAssertEqual(result.updated, 2, "Both nil-description episodes must be updated")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)

        // Verify descriptions were written.
        let updated1 = try store.episode(guid: "g1")
        let updated2 = try store.episode(guid: "g2")
        XCTAssertEqual(updated1?.description, "Description for episode 1")
        XCTAssertEqual(updated2?.description, "Description for episode 2")
    }

    /// Episodes that already have a description must be skipped (never overwritten).
    func testBackfillSkipsExistingDescriptions() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = makeEpisode(guid: "g1", description: "Already has this description")
        try store.upsert(ep)

        let fetcher = FakeDescriptionFetcher(descriptions: [
            "g1": "Overwrite attempt",
        ])

        let backfill = DescriptionBackfill(store: store, fetcher: fetcher)
        let result = await backfill.run()

        XCTAssertEqual(result.skipped, 1, "Episode with existing description must be skipped")
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.failed, 0)

        // Verify the original description is unchanged.
        let unchanged = try store.episode(guid: "g1")
        XCTAssertEqual(unchanged?.description, "Already has this description",
            "Existing description must not be overwritten")

        // Fetcher must NOT have been called for skipped episodes.
        XCTAssertEqual(fetcher.callCounts["g1", default: 0], 0,
            "Fetcher must not be called for episodes that already have a description")
    }

    /// When fetcher returns nil, the episode is counted as failed (description stays nil).
    func testBackfillCountsNilFetcherResponseAsFailed() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = makeEpisode(guid: "g1", description: nil)
        try store.upsert(ep)

        // Fetcher returns nil — no description available.
        let fetcher = FakeDescriptionFetcher(descriptions: [:])

        let backfill = DescriptionBackfill(store: store, fetcher: fetcher)
        let result = await backfill.run()

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.skipped, 0)

        // Description must still be nil in the store.
        let ep2 = try store.episode(guid: "g1")
        XCTAssertNil(ep2?.description, "Description must remain nil when fetcher returns nil")
    }

    /// Mixed: some episodes have descriptions, some don't.
    func testBackfillMixedEpisodes() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let withDesc    = makeEpisode(guid: "with-desc",    description: "Existing")
        let withoutDesc = makeEpisode(guid: "without-desc", description: nil)
        let alsoMissing = makeEpisode(guid: "also-missing", description: nil)
        try store.upsert(withDesc)
        try store.upsert(withoutDesc)
        try store.upsert(alsoMissing)

        let fetcher = FakeDescriptionFetcher(descriptions: [
            "without-desc": "Fetched description",
            // "also-missing" intentionally not in the map → nil → failed
        ])

        let backfill = DescriptionBackfill(store: store, fetcher: fetcher)
        let result = await backfill.run()

        XCTAssertEqual(result.skipped, 1, "One episode with existing description must be skipped")
        XCTAssertEqual(result.updated, 1, "One episode must be updated with fetched description")
        XCTAssertEqual(result.failed,  1, "One episode with no available description must be failed")

        // Verify.
        XCTAssertEqual((try store.episode(guid: "with-desc"))?.description, "Existing")
        XCTAssertEqual((try store.episode(guid: "without-desc"))?.description, "Fetched description")
        XCTAssertNil(   (try store.episode(guid: "also-missing"))?.description)
    }

    /// Empty store: result is 0/0/0.
    func testBackfillEmptyStoreReturnsZeroCounts() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fetcher = FakeDescriptionFetcher()
        let backfill = DescriptionBackfill(store: store, fetcher: fetcher)
        let result = await backfill.run()

        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.failed, 0)
    }

    /// Fetcher throwing an error counts as failed (not crash).
    func testBackfillHandlesFetcherError() async throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = makeEpisode(guid: "g1", description: nil)
        try store.upsert(ep)

        // Fetcher that always throws.
        struct ThrowingFetcher: DescriptionFetcher {
            func fetchDescription(for episode: Episode) async throws -> String? {
                throw URLError(.notConnectedToInternet)
            }
        }

        let backfill = DescriptionBackfill(store: store, fetcher: ThrowingFetcher())
        let result = await backfill.run()

        XCTAssertEqual(result.failed, 1, "A fetcher error must count as failed (not crash)")
        XCTAssertEqual(result.updated, 0)
    }
}
