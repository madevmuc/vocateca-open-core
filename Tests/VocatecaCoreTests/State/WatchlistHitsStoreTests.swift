import XCTest
import Foundation
@testable import VocatecaCore

/// Watchlist (#5) 5b — `watchlist_hits` schema + store CRUD.
final class WatchlistHitsStoreTests: XCTestCase {

    private func row(_ id: String, term: String = "t1", guid: String = "g1", read: Bool = false) -> WatchlistHitRow {
        WatchlistHitRow(id: id, termID: term, showSlug: "show", episodeGuid: guid,
                        snippet: "…\(term)…", matchedAt: "2026-07-01T12:00:00Z", read: read)
    }

    func testInsertFetchAndUnreadCount() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.insertWatchlistHit(row("h1"))
        try store.insertWatchlistHit(row("h2", term: "t2", guid: "g2"))

        XCTAssertEqual(try store.fetchWatchlistHits().count, 2)
        XCTAssertEqual(try store.unreadWatchlistHitCount(), 2)

        try store.markWatchlistHitRead(id: "h1")
        XCTAssertEqual(try store.unreadWatchlistHitCount(), 1)
        XCTAssertEqual(try store.fetchWatchlistHits(unreadOnly: true).map(\.id), ["h2"])
    }

    func testExistenceGuardForBackfillIdempotency() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(try store.watchlistHitExists(termID: "t1", episodeGuid: "g1"))
        try store.insertWatchlistHit(row("h1"))
        XCTAssertTrue(try store.watchlistHitExists(termID: "t1", episodeGuid: "g1"))
    }

    func testDeleteByTerm() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.insertWatchlistHit(row("h1", term: "t1"))
        try store.insertWatchlistHit(row("h2", term: "t2", guid: "g2"))
        try store.deleteWatchlistHits(termID: "t1")

        XCTAssertEqual(try store.fetchWatchlistHits().map(\.id), ["h2"])
    }

    func testMarkAllRead() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.insertWatchlistHit(row("h1"))
        try store.insertWatchlistHit(row("h2", guid: "g2"))
        try store.markAllWatchlistHitsRead()
        XCTAssertEqual(try store.unreadWatchlistHitCount(), 0)
    }
}
