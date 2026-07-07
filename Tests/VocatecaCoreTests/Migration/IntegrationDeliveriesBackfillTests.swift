import XCTest
import Foundation
import GRDB
@testable import VocatecaCore

/// Stability wave 1 — package 4 (H4): the v4 `integration_deliveries` table must
/// exist even on a **pre-v4** database.
///
/// On such a DB `StateStore.init` skips the GRDB migrator entirely (the base
/// `episodes` table already exists), so the `v4_integration_deliveries` migration
/// never runs. `Schema.ensureAdditiveTables` — the additive safety net — must
/// therefore create it too, or every Notion/webhook delivery insert + dedupe
/// check throws "no such table" (silently swallowed → duplicate pages).
final class IntegrationDeliveriesBackfillTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntDeliveriesBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Simulate a legacy DB: create ONLY the base `episodes` table (+ `meta`,
    /// needed by other init paths) and an empty `grdb_migrations`, so the migrator
    /// is skipped. `integration_deliveries` must NOT exist yet.
    private func seedPreV4Database(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE episodes (
                    guid TEXT PRIMARY KEY, show_slug TEXT NOT NULL, title TEXT NOT NULL,
                    pub_date TEXT NOT NULL, mp3_url TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending', mp3_path TEXT,
                    transcript_path TEXT, attempts INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        }
        // Release the file handle before StateStore reopens it.
    }

    func testOpeningPreV4StoreCreatesIntegrationDeliveries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("legacy.sqlite")

        try seedPreV4Database(at: dbURL)

        // Sanity: the legacy DB genuinely lacks the table before we open StateStore.
        do {
            let probe = try DatabaseQueue(path: dbURL.path)
            let existsBefore = try probe.read { try $0.tableExists("integration_deliveries") }
            XCTAssertFalse(existsBefore, "precondition: legacy DB must not have integration_deliveries")
        }

        // Opening StateStore (skips the migrator, runs ensureAdditiveTables).
        let store = try StateStore(databaseURL: dbURL)

        // The additive safety net must have created the v4 table + its index.
        let (hasTable, hasIndex) = try store.dbQueue.read { db in
            (try db.tableExists("integration_deliveries"),
             try db.indexes(on: "integration_deliveries").contains { $0.name == "idx_int_deliveries_episode" })
        }
        XCTAssertTrue(hasTable, "integration_deliveries must exist after opening a pre-v4 store")
        XCTAssertTrue(hasIndex, "the dedupe index must exist too")

        // End-to-end: a delivery record now inserts + reads back (no 'no such table').
        try store.recordDelivery(integration: "notion", episodeGuid: "g1", target: "db",
                                 status: "ok", externalRef: "page1", errorText: nil)
        XCTAssertEqual(try store.lastDelivery(integration: "notion", episodeGuid: "g1")?.status, "ok")
    }
}
