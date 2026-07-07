import XCTest
import GRDB
@testable import VocatecaCore

/// Verifies the `notifications.sqlite` schema migrations (v1 → v2 → v3) apply
/// cleanly to a REAL pre-existing on-disk database — not just a fresh
/// in-memory one — and that the upgrade is idempotent and lossless.
///
/// Part 3 of the notifications reactivity fix brief: "find the migration,
/// confirm it's idempotent and guards missing columns, and add a migration
/// unit test that opens an older-schema fixture DB and asserts it upgrades
/// without data loss."
///
/// ## Fixture strategy
/// Each fixture is built by running a **partial** `DatabaseMigrator` that only
/// registers the migrations an old app build would have known about (e.g. just
/// `"v1_notifications"`), frozen here with the exact SQL those migrations used
/// at the time, so a future edit to the live migrator can't rewrite the
/// fixture out from under the test. This — not hand-written `CREATE TABLE`
/// outside any migrator — is what makes the fixture a faithful stand-in for a
/// real user's old DB: GRDB's `DatabaseMigrator` records applied migration
/// names in its own `grdb_migrations` bookkeeping table, so opening the SAME
/// file later through the full production migrator (`NotificationsDatabase
/// .migrator`, which registers v1 + v2 + v3) correctly resumes from "v1 already
/// applied" and only runs v2/v3 — exactly what happens for a real user
/// upgrading the app. (An earlier version of this fixture created the v1
/// tables with raw, un-tracked SQL; opening it through the full migrator then
/// re-ran "v1_notifications" from scratch and crashed with "table
/// notification already exists" — a good reminder that GRDB's migrator
/// tracks by *name*, not by inspecting the schema.)
final class NotificationsMigrationTests: XCTestCase {

    // MARK: - Fixture helpers

    /// A temp file URL for a fixture DB, cleaned up in `tearDown`.
    private var fixtureURL: URL!

    override func tearDown() {
        if let url = fixtureURL {
            try? FileManager.default.removeItem(at: url)
        }
        fixtureURL = nil
        super.tearDown()
    }

    private func makeFixtureURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-migration-fixture-\(UUID().uuidString).sqlite")
        fixtureURL = url
        return url
    }

    /// The exact `"v1_notifications"` migration body, frozen from
    /// `NotificationsDatabase.migrator` at the time v1 shipped (before the v2
    /// episode-metadata columns and the v3 resolved flag existed).
    private static func registerV1(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1_notifications") { db in
            try db.execute(sql: """
                CREATE TABLE notification (
                    id          TEXT    PRIMARY KEY,
                    kind        TEXT    NOT NULL,
                    title       TEXT    NOT NULL,
                    detail      TEXT    NOT NULL,
                    timestamp   TEXT    NOT NULL,
                    isUnread    INTEGER NOT NULL DEFAULT 1,
                    actionLabel TEXT,
                    createdAt   REAL    NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_notification_createdAt ON notification(createdAt DESC);

                CREATE TABLE notification_dismissed (
                    id         TEXT PRIMARY KEY,
                    dismissedAt REAL NOT NULL DEFAULT 0
                );
            """)
        }
    }

    /// The exact `"v2_new_episode_columns"` migration body, frozen the same way.
    private static func registerV2(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2_new_episode_columns") { db in
            try db.execute(sql: """
                ALTER TABLE notification ADD COLUMN episodeGuid TEXT;
                ALTER TABLE notification ADD COLUMN showSlug    TEXT;
            """)
        }
    }

    /// Builds a v1-schema fixture (only `"v1_notifications"` has ever run — the
    /// exact state of a DB created by the very first shipped build, before the
    /// v2 episode-metadata columns and the v3 resolved flag existed), then
    /// inserts `rowCount` raw rows directly.
    private func makeV1Fixture(rowCount: Int) throws -> URL {
        let url = makeFixtureURL()
        var migrator = DatabaseMigrator()
        Self.registerV1(&migrator)
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue)

        try queue.write { db in
            for i in 0..<rowCount {
                try db.execute(
                    sql: """
                        INSERT INTO notification
                            (id, kind, title, detail, timestamp, isUnread, actionLabel, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "v1-\(i)", "failure", "Old title \(i)", "Old detail \(i)",
                        "12:0\(i % 10)", i % 2 == 0 ? 1 : 0, i % 3 == 0 ? "Retry" : nil,
                        Double(1_700_000_000 + i)
                    ]
                )
            }
        }
        return url
    }

    /// Builds a v2-schema fixture (`"v1_notifications"` + `"v2_new_episode_columns"`
    /// have run; `isResolved` does not exist yet) with a few rows, some with the
    /// v2 columns populated, plus a pre-existing tombstone.
    private func makeV2Fixture() throws -> URL {
        let url = makeFixtureURL()
        var migrator = DatabaseMigrator()
        Self.registerV1(&migrator)
        Self.registerV2(&migrator)
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO notification
                    (id, kind, title, detail, timestamp, isUnread, actionLabel, createdAt, episodeGuid, showSlug)
                VALUES
                    ('newep-abc', 'newEpisode', 'New episode — "Ep 1"', 'Show A', '09:00', 1, 'Transcribe now', 1700000100, 'abc', 'show-a'),
                    ('failure-xyz', 'failure', 'Download failed', 'HTTP 500', '10:00', 0, 'Retry', 1700000200, 'xyz', NULL)
            """)
            // A user already dismissed one id under the v2 schema — the
            // tombstone table must survive the v3 migration untouched.
            try db.execute(sql: """
                INSERT INTO notification_dismissed (id, dismissedAt) VALUES ('deleted-old', 1700000000)
            """)
        }
        return url
    }

    // MARK: - v1 → live schema (v2 + v3 apply on top of a genuinely old DB)

    func testV1Fixture_migratesCleanly_noDataLoss() throws {
        let url = try makeV1Fixture(rowCount: 5)

        // Open through the REAL production path — runs the full migrator,
        // which must see "v1_notifications" already applied and only run
        // v2 + v3 on top.
        let db = try NotificationsDatabase(url: url)
        let rows = try db.fetchAll()

        XCTAssertEqual(rows.count, 5, "All pre-existing v1 rows must survive the v2+v3 migration")
        for row in rows {
            // v2 columns: nullable, must default to nil (not crash / not require backfill).
            XCTAssertNil(row.episodeGuid)
            XCTAssertNil(row.showSlug)
            // v3 column: NOT NULL DEFAULT 0 — every pre-existing row must load
            // as "unresolved", never crash on a missing column.
            XCTAssertFalse(row.isResolved, "Pre-existing rows must migrate as unresolved (isResolved=0)")
        }
        // Spot-check a couple of original fields survived untouched.
        let first = try XCTUnwrap(rows.first { $0.id == "v1-0" })
        XCTAssertEqual(first.title, "Old title 0")
        XCTAssertEqual(first.kind, "failure")
    }

    func testV1Fixture_migrationIsIdempotent_reopeningDoesNotDuplicateOrLose() throws {
        let url = try makeV1Fixture(rowCount: 3)

        // First open: runs v2 + v3 migrations.
        _ = try NotificationsDatabase(url: url)

        // Second open of the SAME file: migrator must see v2/v3 already applied
        // (tracked in GRDB's own `grdb_migrations` table) and skip them —
        // no duplicate ALTER TABLE (which would throw "duplicate column name"
        // and crash), no data duplication.
        let reopened = try NotificationsDatabase(url: url)
        let rows = try reopened.fetchAll()

        XCTAssertEqual(rows.count, 3, "Re-opening an already-migrated DB must not duplicate rows")
        XCTAssertTrue(rows.allSatisfy { !$0.isResolved })
    }

    func testV1Fixture_readWriteStillWorksAfterMigration() throws {
        let url = try makeV1Fixture(rowCount: 2)
        let db = try NotificationsDatabase(url: url)

        // The v3 column must be usable immediately post-migration.
        try db.markResolved(id: "v1-0")
        let rows = try db.fetchAll()
        let resolved = try XCTUnwrap(rows.first { $0.id == "v1-0" })
        let untouched = try XCTUnwrap(rows.first { $0.id == "v1-1" })
        XCTAssertTrue(resolved.isResolved)
        XCTAssertFalse(untouched.isResolved)
    }

    // MARK: - v2 → live schema (only the v3 migration needs to apply)

    func testV2Fixture_migratesCleanly_preservesV2ColumnsAndTombstones() throws {
        let url = try makeV2Fixture()

        let db = try NotificationsDatabase(url: url)
        let rows = try db.fetchAll()

        XCTAssertEqual(rows.count, 2, "Pre-existing v2 rows must survive the v3 migration")

        let newEp = try XCTUnwrap(rows.first { $0.id == "newep-abc" })
        XCTAssertEqual(newEp.episodeGuid, "abc", "v2 episodeGuid must survive the v3 ALTER TABLE")
        XCTAssertEqual(newEp.showSlug, "show-a")
        XCTAssertFalse(newEp.isResolved, "v3 column must default to unresolved on pre-existing rows")

        let failure = try XCTUnwrap(rows.first { $0.id == "failure-xyz" })
        XCTAssertEqual(failure.episodeGuid, "xyz")
        XCTAssertNil(failure.showSlug)

        // The tombstone table (and its pre-existing row) must be untouched —
        // re-seeding "deleted-old" must still be silently rejected.
        let isNew = try db.upsertIfNew(NotificationRecord(
            id: "deleted-old", kind: "failure", title: "Should not resurrect",
            detail: "", timestamp: "00:00"
        ))
        XCTAssertFalse(isNew, "A tombstone written before the v3 migration must still block upsertIfNew")
        XCTAssertEqual(try db.fetchAll().count, 2, "The tombstoned id must not have been inserted")
    }

    // MARK: - Fresh (no file) — sanity baseline the other tests are compared against

    func testFreshDatabase_hasAllColumnsFromScratch() throws {
        let url = makeFixtureURL()
        let db = try NotificationsDatabase(url: url)
        try db.upsertIfNew(NotificationRecord(
            id: "fresh-1", kind: "failure", title: "t", detail: "d", timestamp: "00:00"
        ))
        let row = try XCTUnwrap(try db.fetchAll().first)
        XCTAssertFalse(row.isResolved)
        XCTAssertNil(row.episodeGuid)
        XCTAssertNil(row.showSlug)
    }
}
