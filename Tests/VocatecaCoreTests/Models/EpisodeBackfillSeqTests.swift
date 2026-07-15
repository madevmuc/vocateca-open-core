import XCTest
@testable import VocatecaCore

/// Tests for the additive `episodes.backfill_seq` column (`v7_backfill_seq`
/// migration) + the `Episode.backfillSeq` field. See `BackfillSeqAssigner` +
/// `Schema.swift`'s `v7_backfill_seq` migration.
final class EpisodeBackfillSeqTests: XCTestCase {
    func testDefaultsToNilAndRoundTrips() throws {
        let store = try StateStore.inMemory()
        var ep = Episode.makePodcast(guid: "e1")
        XCTAssertNil(ep.backfillSeq)
        try store.upsert(ep)
        var reloaded = try XCTUnwrap(try store.episode(guid: "e1"))
        XCTAssertNil(reloaded.backfillSeq)

        ep.backfillSeq = 42
        try store.upsert(ep)
        reloaded = try XCTUnwrap(try store.episode(guid: "e1"))
        XCTAssertEqual(reloaded.backfillSeq, 42)
    }

    func testColumnExistsInSchema() throws {
        let store = try StateStore.inMemory()
        // Reach into the DB directly (dbQueue is `internal`, visible via
        // `@testable import`, same pattern as other StateStore test files)
        // to assert the column is really there — not just tolerated by
        // Episode's defensive `row.hasColumn` read.
        let hasColumn = try store.dbQueue.read { db in
            try db.columns(in: "episodes").map(\.name).contains("backfill_seq")
        }
        XCTAssertTrue(hasColumn)
    }
}
