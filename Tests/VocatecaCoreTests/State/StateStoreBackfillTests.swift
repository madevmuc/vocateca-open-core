import XCTest
import Foundation
@testable import VocatecaCore

/// Tests for `StateStore.backfillPreview` / `StateStore.applyBackfill` — the
/// DB-facing counterpart to the pure `BackfillPolicy.inScopeGuids` logic.
final class StateStoreBackfillTests: XCTestCase {

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateStoreBackfillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    @discardableResult
    private func makeEpisode(
        _ store: StateStore,
        guid: String,
        show: String = "show-a",
        pubDate: String,
        status: String
    ) throws -> Episode {
        let ep = Episode(
            guid: guid,
            showSlug: show,
            title: "Episode \(guid)",
            pubDate: pubDate,
            mp3Url: "https://example.com/\(guid).mp3",
            status: status,
            priority: 0,
            attempts: 0
        )
        try store.upsert(ep)
        return ep
    }

    // MARK: - applyBackfill: lastN queues newest deferred, defers older pending

    func testApplyBackfillLastNQueuesNewestAndDefersRest() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 3 episodes, all currently pending (as if 'all' had queued everything).
        try makeEpisode(store, guid: "e1", pubDate: "2026-01-01", status: "pending")
        try makeEpisode(store, guid: "e2", pubDate: "2026-02-01", status: "pending")
        try makeEpisode(store, guid: "e3", pubDate: "2026-03-01", status: "pending")

        let policy = BackfillPolicy(mode: .lastN, n: 1, sinceDate: "", subscribedAt: "2000-01-01")

        let preview = try store.backfillPreview(showSlug: "show-a", policy: policy)
        XCTAssertEqual(preview.willQueue, 0, "nothing is currently deferred")
        XCTAssertEqual(preview.willDefer, 2, "e1 and e2 fall out of scope (only newest 1 stays)")

        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)
        XCTAssertEqual(result.queued, 0)
        XCTAssertEqual(result.deferred, 2)

        XCTAssertEqual(try store.episode(guid: "e1")?.status, "deferred")
        XCTAssertEqual(try store.episode(guid: "e2")?.status, "deferred")
        XCTAssertEqual(try store.episode(guid: "e3")?.status, "pending", "e3 is the newest — stays in scope")
    }

    // MARK: - applyBackfill: widening scope re-queues previously deferred rows

    func testApplyBackfillWideningScopeQueuesDeferred() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try makeEpisode(store, guid: "e1", pubDate: "2026-01-01", status: "deferred")
        try makeEpisode(store, guid: "e2", pubDate: "2026-02-01", status: "deferred")
        try makeEpisode(store, guid: "e3", pubDate: "2026-03-01", status: "pending")

        // Switch to 'all' — everything should now be in scope.
        let policy = BackfillPolicy(mode: .all, n: 10, sinceDate: "", subscribedAt: "2000-01-01")

        let preview = try store.backfillPreview(showSlug: "show-a", policy: policy)
        XCTAssertEqual(preview.willQueue, 2)
        XCTAssertEqual(preview.willDefer, 0)

        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)
        XCTAssertEqual(result.queued, 2)
        XCTAssertEqual(result.deferred, 0)

        XCTAssertEqual(try store.episode(guid: "e1")?.status, "pending")
        XCTAssertEqual(try store.episode(guid: "e2")?.status, "pending")
        XCTAssertEqual(try store.episode(guid: "e3")?.status, "pending")
    }

    // MARK: - Terminal / in-flight statuses are never touched

    func testApplyBackfillNeverTouchesDoneFailedOrInFlightRows() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // All old (out of scope under lastN=1), but in various non-pending/deferred states.
        try makeEpisode(store, guid: "done1", pubDate: "2020-01-01", status: "done")
        try makeEpisode(store, guid: "failed1", pubDate: "2020-01-01", status: "failed")
        try makeEpisode(store, guid: "downloading1", pubDate: "2020-01-01", status: "downloading")
        try makeEpisode(store, guid: "transcribing1", pubDate: "2020-01-01", status: "transcribing")
        try makeEpisode(store, guid: "skipped1", pubDate: "2020-01-01", status: "skipped")
        try makeEpisode(store, guid: "newest", pubDate: "2026-06-01", status: "pending")

        let policy = BackfillPolicy(mode: .lastN, n: 1, sinceDate: "", subscribedAt: "2000-01-01")

        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)
        // Only "newest" is pending and in-scope already; nothing to transition.
        XCTAssertEqual(result.queued, 0)
        XCTAssertEqual(result.deferred, 0)

        XCTAssertEqual(try store.episode(guid: "done1")?.status, "done")
        XCTAssertEqual(try store.episode(guid: "failed1")?.status, "failed")
        XCTAssertEqual(try store.episode(guid: "downloading1")?.status, "downloading")
        XCTAssertEqual(try store.episode(guid: "transcribing1")?.status, "transcribing")
        XCTAssertEqual(try store.episode(guid: "skipped1")?.status, "skipped")
        XCTAssertEqual(try store.episode(guid: "newest")?.status, "pending")
    }

    // MARK: - Scoping is per-show — other shows are unaffected

    func testApplyBackfillOnlyAffectsTargetShow() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try makeEpisode(store, guid: "a1", show: "show-a", pubDate: "2020-01-01", status: "pending")
        try makeEpisode(store, guid: "b1", show: "show-b", pubDate: "2020-01-01", status: "pending")

        let policy = BackfillPolicy(mode: .lastN, n: 0, sinceDate: "", subscribedAt: "2000-01-01")
        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)

        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(try store.episode(guid: "a1")?.status, "deferred")
        XCTAssertEqual(try store.episode(guid: "b1")?.status, "pending", "show-b must be untouched")
    }

    // MARK: - sinceDate / onlyNew apply paths

    func testApplyBackfillSinceDateBoundary() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try makeEpisode(store, guid: "before", pubDate: "2026-02-28", status: "pending")
        try makeEpisode(store, guid: "onBoundary", pubDate: "2026-03-01", status: "pending")
        try makeEpisode(store, guid: "after", pubDate: "2026-03-02", status: "pending")

        let policy = BackfillPolicy(mode: .sinceDate, n: 10, sinceDate: "2026-03-01", subscribedAt: "2000-01-01")
        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)

        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(try store.episode(guid: "before")?.status, "deferred")
        XCTAssertEqual(try store.episode(guid: "onBoundary")?.status, "pending")
        XCTAssertEqual(try store.episode(guid: "after")?.status, "pending")
    }

    func testApplyBackfillOnlyNewDefersEverythingUpToSubscription() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try makeEpisode(store, guid: "old", pubDate: "2026-01-01", status: "pending")
        try makeEpisode(store, guid: "onSubscribeDay", pubDate: "2026-06-01", status: "pending")
        try makeEpisode(store, guid: "new", pubDate: "2026-06-02", status: "pending")

        let policy = BackfillPolicy(mode: .onlyNew, n: 10, sinceDate: "", subscribedAt: "2026-06-01")
        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)

        XCTAssertEqual(result.deferred, 2, "old + onSubscribeDay are both out of scope (strictly-after semantics)")
        XCTAssertEqual(try store.episode(guid: "old")?.status, "deferred")
        XCTAssertEqual(try store.episode(guid: "onSubscribeDay")?.status, "deferred")
        XCTAssertEqual(try store.episode(guid: "new")?.status, "pending")
    }

    // MARK: - No-op policy produces zero transitions

    func testApplyBackfillNoOpWhenAlreadyInDesiredState() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try makeEpisode(store, guid: "e1", pubDate: "2026-01-01", status: "pending")
        try makeEpisode(store, guid: "e2", pubDate: "2026-02-01", status: "pending")

        let policy = BackfillPolicy(mode: .all, n: 10, sinceDate: "", subscribedAt: "2000-01-01")
        let preview = try store.backfillPreview(showSlug: "show-a", policy: policy)
        XCTAssertEqual(preview.willQueue, 0)
        XCTAssertEqual(preview.willDefer, 0)

        let result = try store.applyBackfill(showSlug: "show-a", policy: policy)
        XCTAssertEqual(result.queued, 0)
        XCTAssertEqual(result.deferred, 0)
    }
}
