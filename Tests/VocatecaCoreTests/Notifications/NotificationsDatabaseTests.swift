import XCTest
@testable import VocatecaCore

/// Unit tests for `NotificationsDatabase`.
///
/// All tests use an in-memory database so they run in full isolation with no
/// file-system side-effects and no dependency on the production DB.
final class NotificationsDatabaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> NotificationsDatabase {
        try NotificationsDatabase.inMemory()
    }

    private func makeRecord(
        id: String = UUID().uuidString,
        kind: String = "failure",
        title: String = "Test notification",
        detail: String = "Detail text",
        timestamp: String = "12:00",
        isUnread: Bool = true,
        actionLabel: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) -> NotificationRecord {
        NotificationRecord(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            timestamp: timestamp,
            isUnread: isUnread,
            actionLabel: actionLabel,
            createdAt: createdAt
        )
    }

    // MARK: - fetchAll

    func testFetchAll_emptyDatabase_returnsEmpty() throws {
        let db = try makeDB()
        let results = try db.fetchAll()
        XCTAssertTrue(results.isEmpty)
    }

    func testFetchAll_sortedNewestFirst() throws {
        let db = try makeDB()
        let older = makeRecord(id: "old", createdAt: 1_000_000)
        let newer = makeRecord(id: "new", createdAt: 2_000_000)
        try db.upsertIfNew(older)
        try db.upsertIfNew(newer)

        let results = try db.fetchAll()
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "new", "Newest item must come first")
        XCTAssertEqual(results[1].id, "old")
    }

    func testFetchAll_sameCreatedAt_breaksTieOnIdDescending() throws {
        // Same-second batch seeding (e.g. seedFromFailures) gives identical
        // createdAt; the fetch must impose a deterministic order (id DESC), not
        // leave same-second rows in SQLite's arbitrary rowid order.
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "a", createdAt: 1_000_000))
        try db.upsertIfNew(makeRecord(id: "c", createdAt: 1_000_000))
        try db.upsertIfNew(makeRecord(id: "b", createdAt: 1_000_000))

        let ids = try db.fetchAll().map(\.id)
        XCTAssertEqual(ids, ["c", "b", "a"],
                       "Same-createdAt rows must be ordered by id DESC (stable tiebreak)")
    }

    // MARK: - upsertIfNew (de-duplication)

    func testUpsertIfNew_insertsNewRecord() throws {
        let db = try makeDB()
        let record = makeRecord(id: "notif-001")
        try db.upsertIfNew(record)
        let results = try db.fetchAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "notif-001")
    }

    func testUpsertIfNew_doesNotDuplicateExistingId() throws {
        let db = try makeDB()
        let first = makeRecord(id: "notif-002", title: "Original title", isUnread: true)
        try db.upsertIfNew(first)

        // Attempt to insert a second record with the same id — must be ignored.
        let second = makeRecord(id: "notif-002", title: "Updated title", isUnread: false)
        try db.upsertIfNew(second)

        let results = try db.fetchAll()
        XCTAssertEqual(results.count, 1, "Duplicate id must not create a second row")
        XCTAssertEqual(results[0].title, "Original title", "Existing row must be preserved unchanged")
        XCTAssertTrue(results[0].isUnread, "Original read-state must be preserved")
    }

    func testUpsertIfNew_preservesReadStateAfterReseed() throws {
        let db = try makeDB()
        // User reads the notification.
        try db.upsertIfNew(makeRecord(id: "failure-ep001", isUnread: true))
        try db.setRead(id: "failure-ep001", read: true)

        // Re-seed (same id) — must not resurrect as unread.
        try db.upsertIfNew(makeRecord(id: "failure-ep001", isUnread: true))

        let result = try db.fetchAll().first
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.isUnread, "Re-seed must not override user's read state")
    }

    func testUpsertIfNew_preservesDeletedRecord() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "failure-ep002"))
        try db.delete(id: "failure-ep002")

        // Re-seed the same id — deleted row must stay gone.
        try db.upsertIfNew(makeRecord(id: "failure-ep002", isUnread: true))

        let results = try db.fetchAll()
        XCTAssertTrue(results.isEmpty, "Re-seed of a user-deleted record must not re-insert it")
    }

    // MARK: - setRead / markAllRead

    func testSetRead_marksRecordRead() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "r-01", isUnread: true))
        try db.setRead(id: "r-01", read: true)

        let result = try db.fetchAll().first!
        XCTAssertFalse(result.isUnread)
    }

    func testSetRead_marksRecordUnread() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "r-02", isUnread: false))
        try db.setRead(id: "r-02", read: false)

        let result = try db.fetchAll().first!
        XCTAssertTrue(result.isUnread)
    }

    func testMarkAllRead_clearsAllUnread() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "a-01", isUnread: true))
        try db.upsertIfNew(makeRecord(id: "a-02", isUnread: true))
        try db.upsertIfNew(makeRecord(id: "a-03", isUnread: false))

        try db.markAllRead()

        let results = try db.fetchAll()
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.isUnread }, "All records must be marked read")
    }

    // MARK: - delete / deleteAll

    func testDelete_removesSpecificRecord() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "d-01"))
        try db.upsertIfNew(makeRecord(id: "d-02"))
        try db.delete(id: "d-01")

        let results = try db.fetchAll()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "d-02")
    }

    func testDeleteAll_removesEveryRecord() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "x-01"))
        try db.upsertIfNew(makeRecord(id: "x-02"))
        try db.upsertIfNew(makeRecord(id: "x-03"))
        try db.deleteAll()

        let results = try db.fetchAll()
        XCTAssertTrue(results.isEmpty, "deleteAll must leave zero records")
    }

    // MARK: - Round-trip field persistence

    func testRoundTrip_allFieldsPreserved() throws {
        let db = try makeDB()
        let record = NotificationRecord(
            id: "rt-01",
            kind: "keywordHit",
            title: "Keyword match",
            detail: "2 new results for \"Zinswende\"",
            timestamp: "14:20",
            isUnread: true,
            actionLabel: "View",
            createdAt: 9_999_999.5
        )
        try db.upsertIfNew(record)
        let fetched = try db.fetchAll().first!

        XCTAssertEqual(fetched.id,          record.id)
        XCTAssertEqual(fetched.kind,         record.kind)
        XCTAssertEqual(fetched.title,        record.title)
        XCTAssertEqual(fetched.detail,       record.detail)
        XCTAssertEqual(fetched.timestamp,    record.timestamp)
        XCTAssertEqual(fetched.isUnread,     record.isUnread)
        XCTAssertEqual(fetched.actionLabel,  record.actionLabel)
        XCTAssertEqual(fetched.createdAt,    record.createdAt, accuracy: 0.001)
    }

    func testRoundTrip_nilActionLabel() throws {
        let db = try makeDB()
        let record = makeRecord(id: "nil-action", actionLabel: nil)
        try db.upsertIfNew(record)
        let fetched = try db.fetchAll().first!
        XCTAssertNil(fetched.actionLabel)
    }

    // MARK: - Triage resolved flag (v3)

    func testResolved_defaultsToFalse() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "res-default"))
        let fetched = try db.fetchAll().first!
        XCTAssertFalse(fetched.isResolved, "New records default to unresolved")
    }

    func testMarkResolved_persistsFlag() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "res-1"))
        try db.markResolved(id: "res-1")
        let fetched = try db.fetchAll().first { $0.id == "res-1" }!
        XCTAssertTrue(fetched.isResolved, "markResolved must persist isResolved = true")
    }

    func testMarkResolved_isIdempotent() throws {
        let db = try makeDB()
        try db.upsertIfNew(makeRecord(id: "res-2"))
        try db.markResolved(id: "res-2")
        try db.markResolved(id: "res-2")
        let fetched = try db.fetchAll().first { $0.id == "res-2" }!
        XCTAssertTrue(fetched.isResolved)
    }

    // MARK: - inMemory factory

    func testInMemory_isolatedBetweenInstances() throws {
        let db1 = try NotificationsDatabase.inMemory()
        let db2 = try NotificationsDatabase.inMemory()
        try db1.upsertIfNew(makeRecord(id: "isolated"))
        let resultsDB2 = try db2.fetchAll()
        XCTAssertTrue(resultsDB2.isEmpty, "In-memory instances must be isolated from each other")
    }
}
