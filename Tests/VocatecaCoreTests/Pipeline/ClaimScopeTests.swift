import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - ClaimScopeTests
//
// Tests for the `restrictToSlugs` parameter added to
// `StateStore.claimNextPending(queueOrder:restrictToSlugs:)`.
//
// Convention:
//   - `restrictToSlugs: nil`   → claim any pending (unchanged legacy behaviour)
//   - `restrictToSlugs: []`    → also claims any pending (empty == nil, behaves like no filter)
//   - `restrictToSlugs: ["a"]` → claim only pending episodes whose show_slug is in the set
//
// This "nil/[] == all" convention keeps the call sites simple: when no slugs
// are opted-in the daemon simply passes nil and no episodes are claimed
// (guarded by the earlier `guard !enabled.isEmpty` in the daemon).
// An empty array arriving here is also treated as "no restriction" rather than
// "claim nothing", because an empty IN-clause would silently return nil and
// surprise callers — explicit emptiness is handled at the call site guard.

final class ClaimScopeTests: XCTestCase {

    // MARK: - Scoped to one show: only returns that show's episodes

    /// Seed pending episodes across showA and showB; assert that
    /// `restrictToSlugs: ["showA"]` only ever returns showA episodes.
    func testClaimScopeRestrictsToNamedShow() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = Episode.makePodcast(guid: "a-1", showSlug: "showA", pubDate: "2024-01-01")
        let a2 = Episode.makePodcast(guid: "a-2", showSlug: "showA", pubDate: "2024-06-01")
        let b1 = Episode.makePodcast(guid: "b-1", showSlug: "showB", pubDate: "2024-01-01")
        let b2 = Episode.makePodcast(guid: "b-2", showSlug: "showB", pubDate: "2024-06-01")
        try store.upsert(a1)
        try store.upsert(a2)
        try store.upsert(b1)
        try store.upsert(b2)

        // Drain all available claims scoped to showA only.
        var claimedGuids: [String] = []
        while let ep = try store.claimNextPending(queueOrder: "oldest_first",
                                                   restrictToSlugs: ["showA"]) {
            claimedGuids.append(ep.guid)
            // Safety guard: should claim exactly 2 showA episodes then stop.
            if claimedGuids.count > 10 { XCTFail("claimNextPending looped unexpectedly"); break }
        }

        XCTAssertEqual(Set(claimedGuids), Set(["a-1", "a-2"]),
                       "restrictToSlugs:[showA] must return only showA episodes")
        XCTAssertFalse(claimedGuids.contains("b-1"), "showB episode must not be claimed")
        XCTAssertFalse(claimedGuids.contains("b-2"), "showB episode must not be claimed")
    }

    /// When restrictToSlugs limits to showA and showA has no pending episodes,
    /// claimNextPending must return nil — even though showB has pending episodes.
    func testClaimScopeReturnsNilWhenScopedShowHasNoEpisodes() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let b1 = Episode.makePodcast(guid: "b-1", showSlug: "showB")
        try store.upsert(b1)

        let result = try store.claimNextPending(queueOrder: "oldest_first",
                                                 restrictToSlugs: ["showA"])
        XCTAssertNil(result,
                     "restrictToSlugs:[showA] must return nil when showA has no pending episodes")
    }

    // MARK: - nil / empty array == claim all (legacy behaviour)

    /// `restrictToSlugs: nil` must claim across all shows — unchanged legacy behaviour.
    func testClaimScopeNilClaimsAll() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = Episode.makePodcast(guid: "a-1", showSlug: "showA", pubDate: "2024-01-01")
        let b1 = Episode.makePodcast(guid: "b-1", showSlug: "showB", pubDate: "2024-03-01")
        try store.upsert(a1)
        try store.upsert(b1)

        var claimedGuids: [String] = []
        while let ep = try store.claimNextPending(queueOrder: "oldest_first",
                                                   restrictToSlugs: nil) {
            claimedGuids.append(ep.guid)
            if claimedGuids.count > 10 { XCTFail("unexpected loop"); break }
        }
        XCTAssertEqual(Set(claimedGuids), Set(["a-1", "b-1"]),
                       "restrictToSlugs:nil must claim pending episodes from all shows")
    }

    /// `restrictToSlugs: []` (empty array) must also claim across all shows,
    /// identical to nil — the empty-list edge case does NOT mean "claim nothing".
    func testClaimScopeEmptyArrayClaimsAll() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = Episode.makePodcast(guid: "a-1", showSlug: "showA", pubDate: "2024-01-01")
        let b1 = Episode.makePodcast(guid: "b-1", showSlug: "showB", pubDate: "2024-03-01")
        try store.upsert(a1)
        try store.upsert(b1)

        var claimedGuids: [String] = []
        while let ep = try store.claimNextPending(queueOrder: "oldest_first",
                                                   restrictToSlugs: []) {
            claimedGuids.append(ep.guid)
            if claimedGuids.count > 10 { XCTFail("unexpected loop"); break }
        }
        XCTAssertEqual(Set(claimedGuids), Set(["a-1", "b-1"]),
                       "restrictToSlugs:[] must behave identically to nil (claim all)")
    }

    // MARK: - Scoped to multiple shows

    /// When restrictToSlugs contains two shows, episodes from both are claimed
    /// but a third show is excluded.
    func testClaimScopeMultipleShowsIncludesAll() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = Episode.makePodcast(guid: "a-1", showSlug: "showA")
        let b1 = Episode.makePodcast(guid: "b-1", showSlug: "showB")
        let c1 = Episode.makePodcast(guid: "c-1", showSlug: "showC")
        try store.upsert(a1)
        try store.upsert(b1)
        try store.upsert(c1)

        var claimedGuids: [String] = []
        while let ep = try store.claimNextPending(queueOrder: "oldest_first",
                                                   restrictToSlugs: ["showA", "showB"]) {
            claimedGuids.append(ep.guid)
            if claimedGuids.count > 10 { XCTFail("unexpected loop"); break }
        }
        XCTAssertEqual(Set(claimedGuids), Set(["a-1", "b-1"]),
                       "restrictToSlugs:[showA, showB] must include both but exclude showC")
        XCTAssertFalse(claimedGuids.contains("c-1"), "showC must not be claimed")
    }

    // MARK: - Ordering is preserved within a scoped claim

    /// The ORDER BY (oldest_first → pub_date ASC) must still apply within the
    /// scoped set — the restriction is an additional WHERE predicate, not a sort change.
    func testClaimScopePreservesOrdering() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // showA has two episodes with different pub_dates.
        let aOld = Episode.makePodcast(guid: "a-old", showSlug: "showA", pubDate: "2022-01-01")
        let aNew = Episode.makePodcast(guid: "a-new", showSlug: "showA", pubDate: "2025-01-01")
        // showB has an older-still episode that must NOT be claimed.
        let bVeryOld = Episode.makePodcast(guid: "b-veryold", showSlug: "showB", pubDate: "2010-01-01")
        try store.upsert(aOld)
        try store.upsert(aNew)
        try store.upsert(bVeryOld)

        // First claim scoped to showA: must return the oldest showA episode.
        let first = try XCTUnwrap(
            store.claimNextPending(queueOrder: "oldest_first", restrictToSlugs: ["showA"])
        )
        XCTAssertEqual(first.guid, "a-old",
                       "Within the scope, ordering must still be oldest_first")

        // Second claim scoped to showA: must return the newer showA episode.
        let second = try XCTUnwrap(
            store.claimNextPending(queueOrder: "oldest_first", restrictToSlugs: ["showA"])
        )
        XCTAssertEqual(second.guid, "a-new",
                       "Second scoped claim must return next oldest showA episode")

        // Third claim scoped to showA: showA is now empty → nil.
        let third = try store.claimNextPending(queueOrder: "oldest_first",
                                                restrictToSlugs: ["showA"])
        XCTAssertNil(third, "showA exhausted — scoped claim must return nil")

        // showB episode is still pending (never claimed by the scoped drain).
        let any = try XCTUnwrap(store.claimNextPending(queueOrder: "oldest_first",
                                                        restrictToSlugs: nil))
        XCTAssertEqual(any.guid, "b-veryold", "Unscoped claim must still find showB episode")
    }

    // MARK: - Default parameter value: start() with no args still claims all

    /// Calling `claimNextPending(queueOrder:)` WITHOUT the `restrictToSlugs`
    /// argument (the old call site, default = nil) must behave identically
    /// to passing `nil` explicitly — claim across all shows.
    func testClaimScopeDefaultParameterClaimsAll() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = Episode.makePodcast(guid: "a-1", showSlug: "showA", pubDate: "2024-01-01")
        let b1 = Episode.makePodcast(guid: "b-1", showSlug: "showB", pubDate: "2024-06-01")
        try store.upsert(a1)
        try store.upsert(b1)

        // Call WITHOUT restrictToSlugs — exercises the default parameter.
        var claimedGuids: [String] = []
        while let ep = try store.claimNextPending(queueOrder: "oldest_first") {
            claimedGuids.append(ep.guid)
            if claimedGuids.count > 10 { XCTFail("unexpected loop"); break }
        }
        XCTAssertEqual(Set(claimedGuids), Set(["a-1", "b-1"]),
                       "Default (no restrictToSlugs arg) must claim across all shows — legacy behaviour unchanged")
    }
}
