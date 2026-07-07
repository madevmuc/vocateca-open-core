import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - ClaimOrderingTests

/// Tests for `StateStore.claimNextPending(queueOrder:)` ordering.
///
/// Verifies that the claim order for each `queueOrder` value exactly matches
/// the Python `_QUEUE_ORDERS` map in `core/state.py`.
final class ClaimOrderingTests: XCTestCase {

    // MARK: - oldest_first

    /// Seed episodes with varied pub_dates; assert oldest pub_date is claimed first.
    func testOldestFirst() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep1 = Episode.makePodcast(guid: "ep-2024", pubDate: "2024-01-01")
        let ep2 = Episode.makePodcast(guid: "ep-2023", pubDate: "2023-01-01")
        let ep3 = Episode.makePodcast(guid: "ep-2025", pubDate: "2025-01-01")
        try store.upsert(ep1)
        try store.upsert(ep2)
        try store.upsert(ep3)

        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "oldest_first"))
        XCTAssertEqual(first.guid, "ep-2023", "oldest_first must return the episode with the earliest pub_date")
    }

    // MARK: - newest_first

    func testNewestFirst() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep1 = Episode.makePodcast(guid: "ep-2024", pubDate: "2024-06-01")
        let ep2 = Episode.makePodcast(guid: "ep-2023", pubDate: "2023-06-01")
        let ep3 = Episode.makePodcast(guid: "ep-2025", pubDate: "2025-06-01")
        try store.upsert(ep1)
        try store.upsert(ep2)
        try store.upsert(ep3)

        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "newest_first"))
        XCTAssertEqual(first.guid, "ep-2025", "newest_first must return the episode with the latest pub_date")
    }

    // MARK: - shortest_first

    func testShortestFirst() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep1 = Episode.makePodcast(guid: "ep-long",   durationSec: 3600)
        let ep2 = Episode.makePodcast(guid: "ep-short",  durationSec: 300)
        let ep3 = Episode.makePodcast(guid: "ep-medium", durationSec: 1800)
        let ep4 = Episode.makePodcast(guid: "ep-null")   // duration_sec IS NULL → sorted last
        try store.upsert(ep1)
        try store.upsert(ep2)
        try store.upsert(ep3)
        try store.upsert(ep4)

        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "shortest_first"))
        XCTAssertEqual(first.guid, "ep-short", "shortest_first must return the episode with the smallest duration_sec")
    }

    // MARK: - NULL duration is sorted last in shortest_first

    func testShortestFirstNullIsLast() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only NULL-duration episodes.
        let epNull1 = Episode.makePodcast(guid: "null-a", pubDate: "2024-01-01")
        let epNull2 = Episode.makePodcast(guid: "null-b", pubDate: "2024-06-01")
        // One known-duration episode.
        let epKnown = Episode.makePodcast(guid: "known",  durationSec: 100)
        try store.upsert(epNull1)
        try store.upsert(epNull2)
        try store.upsert(epKnown)

        // Known-duration episode must be preferred over NULL-duration ones.
        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "shortest_first"))
        XCTAssertEqual(first.guid, "known", "NULL duration must sort after any known duration")
    }

    // MARK: - priority DESC always wins over pub_date ordering

    func testPriorityWins() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ep-low has oldest pub_date but low priority.
        // ep-high has newest pub_date but high priority.
        // With oldest_first, date ordering would pick ep-low — but priority must override.
        let epLow  = Episode.makePodcast(guid: "ep-low",  pubDate: "2020-01-01", priority: 0)
        let epHigh = Episode.makePodcast(guid: "ep-high", pubDate: "2025-01-01", priority: 10)
        try store.upsert(epLow)
        try store.upsert(epHigh)

        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "oldest_first"))
        XCTAssertEqual(first.guid, "ep-high",
                       "Higher priority must win over pub_date ordering (priority DESC always leads)")
    }

    // MARK: - Unknown queueOrder falls back to oldest_first

    func testUnknownQueueOrderFallsBack() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep1 = Episode.makePodcast(guid: "ep-old", pubDate: "2020-01-01")
        let ep2 = Episode.makePodcast(guid: "ep-new", pubDate: "2024-01-01")
        try store.upsert(ep1)
        try store.upsert(ep2)

        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "bogus_order"))
        XCTAssertEqual(first.guid, "ep-old", "Unknown queue_order must fall back to oldest_first")
    }

    // MARK: - Empty queue returns nil

    func testEmptyQueueReturnsNil() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try store.claimNextPending(queueOrder: "oldest_first")
        XCTAssertNil(result, "Empty queue must return nil")
    }

    // MARK: - claimOrderByFragment SQL

    func testClaimOrderByFragmentSQL() {
        XCTAssertEqual(StateStore.claimOrderByFragment("oldest_first"),
                       "priority DESC, pub_date ASC")
        XCTAssertEqual(StateStore.claimOrderByFragment("newest_first"),
                       "priority DESC, pub_date DESC")
        XCTAssertEqual(StateStore.claimOrderByFragment("shortest_first"),
                       "priority DESC, (duration_sec IS NULL), duration_sec ASC")
        // Unknown → oldest_first
        XCTAssertEqual(StateStore.claimOrderByFragment("foo"),
                       "priority DESC, pub_date ASC")
    }
}
