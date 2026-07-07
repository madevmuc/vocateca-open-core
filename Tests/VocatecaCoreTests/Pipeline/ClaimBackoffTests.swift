import XCTest
import GRDB
@testable import VocatecaCore

// MARK: - ClaimBackoffTests
//
// M1 — no retry-backoff. On a transient failure the pipeline resets the row to
// `pending` with a RECENT `attempted_at` (set on every downloading/transcribing
// transition). Without a backoff `claimNextPending` re-picks it the same second
// and burns all 3 attempts in a few seconds, so a 30 s network blip fails the
// whole queue. The claim now skips rows attempted within `retryBackoffSeconds`;
// the predicate is time-based so it can NEVER wedge the drain — once the window
// elapses the row is claimable again.

final class ClaimBackoffTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaimBackoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(databaseURL: dir.appendingPathComponent("t.sqlite")), dir)
    }

    /// Seed a pending row with an explicit `attempted_at`.
    private func seedPending(_ store: StateStore, guid: String, attemptedAt: String?) throws {
        try store.upsert(Episode(guid: guid, showSlug: "s", title: guid,
                                 pubDate: "2026-01-01", mp3Url: "https://e/\(guid).mp3",
                                 status: "pending"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE episodes SET attempted_at = ? WHERE guid = ?",
                           arguments: [attemptedAt, guid])
        }
    }

    // MARK: - Hot row is skipped, cold row is claimed

    /// A row attempted 10 s ago is INSIDE a 60 s backoff window → NOT claimed.
    func testRecentlyAttemptedRowIsSkipped() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        try seedPending(store, guid: "hot", attemptedAt: Event.iso(from: now.addingTimeInterval(-10)))

        let claimed = try store.claimNextPending(queueOrder: "oldest_first",
                                                 backoffSeconds: 60, now: now)
        XCTAssertNil(claimed, "a row attempted within the backoff window must not be claimed")
        XCTAssertEqual(try store.episode(guid: "hot")?.status, "pending",
                       "the skipped row stays pending")
    }

    /// A never-attempted row (`attempted_at IS NULL`) is always eligible.
    func testNeverAttemptedRowIsClaimed() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try seedPending(store, guid: "fresh", attemptedAt: nil)
        let claimed = try store.claimNextPending(queueOrder: "oldest_first",
                                                 backoffSeconds: 60, now: Date())
        XCTAssertEqual(claimed?.guid, "fresh", "a never-attempted row must be claimable")
    }

    /// A row attempted 120 s ago is OUTSIDE a 60 s window → claimed. Proves the
    /// backoff is a temporary hold, not a permanent exclusion (no deadlock).
    func testRowBecomesClaimableAfterWindow() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        try seedPending(store, guid: "cooled", attemptedAt: Event.iso(from: now.addingTimeInterval(-120)))

        let claimed = try store.claimNextPending(queueOrder: "oldest_first",
                                                 backoffSeconds: 60, now: now)
        XCTAssertEqual(claimed?.guid, "cooled",
                       "once the backoff window elapses the row must be claimable again")
        XCTAssertEqual(try store.episode(guid: "cooled")?.status, "downloading",
                       "claiming flips it to downloading as usual")
    }

    // MARK: - Backoff doesn't starve OTHER ready work

    /// A hot (recently-attempted) row must not block a different, cold row: the
    /// claim skips the hot one and returns the eligible one. This is what stops a
    /// single failing episode from stalling the entire queue.
    func testHotRowDoesNotBlockColdRow() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // "hot" is older by pub_date (would normally be claimed first) but was just
        // attempted; "cold" is newer but eligible.
        try store.upsert(Episode(guid: "hot", showSlug: "s", title: "hot",
                                 pubDate: "2020-01-01", mp3Url: "https://e/hot.mp3",
                                 status: "pending"))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE episodes SET attempted_at = ? WHERE guid = 'hot'",
                           arguments: [Event.iso(from: now.addingTimeInterval(-5))])
        }
        try seedPending(store, guid: "cold", attemptedAt: nil)   // newer + eligible

        let claimed = try store.claimNextPending(queueOrder: "oldest_first",
                                                 backoffSeconds: 60, now: now)
        XCTAssertEqual(claimed?.guid, "cold",
                       "the backed-off row must be skipped so ready work still drains")
        XCTAssertEqual(try store.episode(guid: "hot")?.status, "pending")
    }

    // MARK: - Ordering preserved among eligible rows

    /// Among rows OUTSIDE the window, ordering (oldest_first) still applies — the
    /// backoff is an extra predicate, not a sort change.
    func testOrderingPreservedAmongEligibleRows() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let old = Event.iso(from: now.addingTimeInterval(-300))
        try seedPending(store, guid: "eligible-old", attemptedAt: old)      // pub 2020
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE episodes SET pub_date = '2020-01-01' WHERE guid = 'eligible-old'")
        }
        try seedPending(store, guid: "eligible-new", attemptedAt: old)      // pub 2025
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE episodes SET pub_date = '2025-01-01' WHERE guid = 'eligible-new'")
        }

        let first = try store.claimNextPending(queueOrder: "oldest_first",
                                               backoffSeconds: 60, now: now)
        XCTAssertEqual(first?.guid, "eligible-old",
                       "oldest_first still orders the eligible set")
    }
}
