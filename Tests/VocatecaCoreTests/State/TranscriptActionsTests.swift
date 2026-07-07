import XCTest
import Foundation
import GRDB
@testable import VocatecaCore

/// Tests for `StateStore.clearTranscriptAndSkip(guid:)`.
///
/// Opens a fresh temp-backed `StateStore` (with v2 migrations applied), inserts
/// a `done` episode that has a `transcript_path`, then verifies:
/// 1. The returned prior path equals the one inserted.
/// 2. The episode's status is `skipped` after the call.
/// 3. The episode's `transcript_path` column is `nil` after the call.
final class TranscriptActionsTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir)
    }

    // MARK: - Tests

    func test_clearTranscriptAndSkip_returnsOldPath_andUpdatesDB() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Insert a minimal show so foreign-key constraints (if any) are met.
        // VocatecaCore uses a plain INSERT — shows table may not have FK on episodes.
        // Insert episode directly with transcript_path and status=done.
        let guid = "test-ep-\(UUID().uuidString)"
        let fakePath = "/tmp/fake-transcript-\(guid).md"

        try store.upsert(Episode(
            guid: guid,
            showSlug: "test-show",
            title: "Test Episode",
            pubDate: "2026-06-29",
            mp3Url: "https://example.com/ep.mp3",
            status: "done",
            transcriptPath: fakePath
        ))

        // Call under test.
        let returnedPath = try store.clearTranscriptAndSkip(guid: guid)

        // 1. Returned path must equal the one we inserted.
        XCTAssertEqual(returnedPath, fakePath,
                       "clearTranscriptAndSkip should return the prior transcript_path")

        // 2. Status must now be "skipped".
        // 3. transcript_path must be nil.
        let episodes = try store.fetchEpisodesForTest(guid: guid)
        guard let ep = episodes.first else {
            XCTFail("Episode not found after clearTranscriptAndSkip"); return
        }
        XCTAssertEqual(ep.status, EpisodeStatus.skipped.rawValue,
                       "status should be 'skipped' after clearTranscriptAndSkip")
        XCTAssertNil(ep.transcriptPath,
                     "transcript_path should be nil after clearTranscriptAndSkip")
    }

    func test_clearTranscriptAndSkip_nilPath_returnsNil() throws {
        // Episode with no transcript_path — should return nil and still set skipped.
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guid = "test-ep-nillpath-\(UUID().uuidString)"
        try store.upsert(Episode(
            guid: guid,
            showSlug: "test-show",
            title: "No-path episode",
            pubDate: "2026-06-29",
            mp3Url: "",
            status: "pending"
        ))

        let returnedPath = try store.clearTranscriptAndSkip(guid: guid)
        XCTAssertNil(returnedPath, "Should return nil when no prior transcript_path")

        let episodes = try store.fetchEpisodesForTest(guid: guid)
        XCTAssertEqual(episodes.first?.status, "skipped")
        XCTAssertNil(episodes.first?.transcriptPath)
    }

    // MARK: - clearTranscriptAndMarkDeleted (ITEM 11b)

    /// Mirror of `test_clearTranscriptAndSkip_returnsOldPath_andUpdatesDB` for the
    /// new user-delete method: same clear-and-return-prior-path contract, but the
    /// status it writes is `deleted` rather than `skipped`.
    func test_clearTranscriptAndMarkDeleted_returnsOldPath_andSetsDeleted() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guid = "test-ep-del-\(UUID().uuidString)"
        let fakePath = "/tmp/fake-transcript-\(guid).md"

        try store.upsert(Episode(
            guid: guid,
            showSlug: "test-show",
            title: "Test Episode",
            pubDate: "2026-06-29",
            mp3Url: "https://example.com/ep.mp3",
            status: "done",
            transcriptPath: fakePath
        ))

        let returnedPath = try store.clearTranscriptAndMarkDeleted(guid: guid)
        XCTAssertEqual(returnedPath, fakePath,
                       "clearTranscriptAndMarkDeleted should return the prior transcript_path")

        let episodes = try store.fetchEpisodesForTest(guid: guid)
        guard let ep = episodes.first else {
            XCTFail("Episode not found after clearTranscriptAndMarkDeleted"); return
        }
        XCTAssertEqual(ep.status, EpisodeStatus.deleted.rawValue,
                       "status should be 'deleted' (NOT 'skipped') after clearTranscriptAndMarkDeleted")
        XCTAssertNil(ep.transcriptPath,
                     "transcript_path should be nil after clearTranscriptAndMarkDeleted")
    }

    func test_clearTranscriptAndMarkDeleted_nilPath_returnsNil() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guid = "test-ep-del-nilpath-\(UUID().uuidString)"
        try store.upsert(Episode(
            guid: guid,
            showSlug: "test-show",
            title: "No-path episode",
            pubDate: "2026-06-29",
            mp3Url: "",
            status: "pending"
        ))

        let returnedPath = try store.clearTranscriptAndMarkDeleted(guid: guid)
        XCTAssertNil(returnedPath, "Should return nil when no prior transcript_path")

        let episodes = try store.fetchEpisodesForTest(guid: guid)
        XCTAssertEqual(episodes.first?.status, "deleted")
        XCTAssertNil(episodes.first?.transcriptPath)
    }
}

// MARK: - Test helper extension

private extension StateStore {
    /// Fetches episodes for a single guid. For testing only.
    func fetchEpisodesForTest(guid: String) throws -> [Episode] {
        try dbQueue.read { db in
            try Episode.fetchAll(
                db,
                SQLRequest(sql: "SELECT * FROM episodes WHERE guid = ?", arguments: [guid])
            )
        }
    }
}
