import XCTest
@testable import VocatecaCore

final class StateStoreUpNextTests: XCTestCase {
    /// Create N pending episodes (priority 0) for one show; returns their guids.
    private func seed(_ store: StateStore, _ guids: [String]) throws {
        for g in guids {
            _ = try store.upsertEpisodeFromFeed(showSlug: "s", guid: g, title: g,
                                                pubDate: "2026-01-01", mp3URL: "http://x/\(g).mp3",
                                                durationSec: nil)
        }
    }
    private func priority(_ store: StateStore, _ guid: String) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT priority FROM episodes WHERE guid = ?", arguments: [guid]) ?? -999
        }
    }

    func testMoveToUpNextTopThenComingUpUntouched() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b", "c"])                 // all pending, priority 0 (Coming up)
        try store.moveToUpNext(guids: ["b"], position: .top)
        XCTAssertEqual(try store.upNextGuidsOrdered(), ["b"])
        XCTAssertGreaterThan(try priority(store, "b"), 0)
        XCTAssertEqual(try priority(store, "a"), 0)      // Coming-up rows untouched
        XCTAssertEqual(try priority(store, "c"), 0)
    }

    func testTopAndBottomOrdering() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b", "c"])
        try store.moveToUpNext(guids: ["a"], position: .top)      // Up Next: [a]
        try store.moveToUpNext(guids: ["c"], position: .bottom)   // Up Next: [a, c]
        try store.moveToUpNext(guids: ["b"], position: .top)      // Up Next: [b, a, c]
        XCTAssertEqual(try store.upNextGuidsOrdered(), ["b", "a", "c"])
    }

    func testReorderRewritesOrder() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b", "c"])
        try store.moveToUpNext(guids: ["a", "b", "c"], position: .top) // some order
        try store.reorderUpNext(orderedGuids: ["c", "a", "b"])
        XCTAssertEqual(try store.upNextGuidsOrdered(), ["c", "a", "b"])
    }

    func testRemoveFromUpNextDropsToComingUp() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b"])
        try store.moveToUpNext(guids: ["a", "b"], position: .top)
        try store.removeFromUpNext(guids: ["a"])
        XCTAssertEqual(try priority(store, "a"), 0)
        XCTAssertEqual(try store.upNextGuidsOrdered(), ["b"])
    }

    func testAddingDeferredFlipsToPending() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a"])
        _ = try store.setStatus(guid: "a", .deferred)
        try store.moveToUpNext(guids: ["a"], position: .top)
        XCTAssertEqual(try store.upNextGuidsOrdered(), ["a"])   // now pending + in Up Next
    }

    func testInFlightNotReorderable() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a"])
        _ = try store.setStatus(guid: "a", .transcribing)
        try store.moveToUpNext(guids: ["a"], position: .top)    // no-op (in-flight)
        XCTAssertEqual(try store.upNextGuidsOrdered(), [])
    }

    func testClaimReturnsUpNextBeforeComingUp() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b"])                               // both Coming up
        try store.moveToUpNext(guids: ["b"], position: .top)      // b → Up Next
        let claimed = try store.claimNextPending(queueOrder: "oldest_first", restrictToSlugs: nil)
        XCTAssertEqual(claimed?.guid, "b")                        // Up Next drains first
    }

    // MARK: - Durable audit events (T2-1 follow-up)

    private func eventCount(_ store: StateStore, _ type: String) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE type = ?", arguments: [type]) ?? 0
        }
    }

    func testAddEmitsAuditEvent() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b"])
        try store.moveToUpNext(guids: ["a", "b"], position: .bottom)
        // One batch event, not one per guid.
        XCTAssertEqual(try eventCount(store, EventType.queueUpNextAdded), 1)
    }

    func testAddNoOpEmitsNoEvent() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a"])
        _ = try store.setStatus(guid: "a", .transcribing)         // in-flight → ineligible
        try store.moveToUpNext(guids: ["a"], position: .top)      // no-op
        XCTAssertEqual(try eventCount(store, EventType.queueUpNextAdded), 0)
    }

    func testRemoveEmitsEventOnlyForRealRemovals() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b"])
        try store.moveToUpNext(guids: ["a"], position: .top)      // only a is in Up Next
        try store.removeFromUpNext(guids: ["a", "b"])            // b was never in Up Next
        XCTAssertEqual(try eventCount(store, EventType.queueUpNextRemoved), 1)
    }

    func testReorderEmitsEvent() throws {
        let store = try StateStore.inMemory()
        try seed(store, ["a", "b"])
        try store.moveToUpNext(guids: ["a", "b"], position: .top)
        try store.reorderUpNext(orderedGuids: ["b", "a"])
        XCTAssertEqual(try eventCount(store, EventType.queueUpNextReordered), 1)
    }

    func testReorderEmptyEmitsNoEvent() throws {
        let store = try StateStore.inMemory()
        try store.reorderUpNext(orderedGuids: [])
        XCTAssertEqual(try eventCount(store, EventType.queueUpNextReordered), 0)
    }
}
