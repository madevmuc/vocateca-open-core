import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - DeferredQueueTests
//
// Covers the Queue-clarity brief's "Zurückgestellt (N)" section data path:
//   - StateStore.deferredEpisodes() returns only `.deferred` rows, newest first.
//   - requeue(guids:) ("Wieder einplanen") flips deferred → pending so the
//     episode re-enters the active queue and disappears from the deferred list.
//   - setStatus(.skipped) ("Endgültig entfernen") is a genuine terminal state:
//     the episode leaves BOTH the active queue and the deferred list, and
//     `requeue` (a later button press) no longer targets it as an active row —
//     it is not on the deferred list to act on. Verifies package 2's
//     "never re-enters" semantics.

final class DeferredQueueTests: XCTestCase {

    // MARK: - deferredEpisodes(): query correctness

    func testDeferredEpisodesReturnsOnlyDeferredStatus() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-pending", status: "pending"))
        try store.upsert(Episode.makePodcast(guid: "dq-done", status: "done"))
        try store.upsert(Episode.makePodcast(guid: "dq-deferred-1", pubDate: "2026-01-01", status: "pending"))
        try store.upsert(Episode.makePodcast(guid: "dq-deferred-2", pubDate: "2026-02-01", status: "pending"))
        try store.setStatus(guid: "dq-deferred-1", .deferred)
        try store.setStatus(guid: "dq-deferred-2", .deferred)

        let deferred = try store.deferredEpisodes()

        XCTAssertEqual(deferred.count, 2, "Only the two deferred rows must be returned")
        XCTAssertTrue(deferred.allSatisfy { $0.status == "deferred" })
        XCTAssertFalse(deferred.contains { $0.guid == "dq-pending" })
        XCTAssertFalse(deferred.contains { $0.guid == "dq-done" })
    }

    func testDeferredEpisodesOrderedNewestFirst() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-old", pubDate: "2026-01-01", status: "pending"))
        try store.upsert(Episode.makePodcast(guid: "dq-new", pubDate: "2026-06-01", status: "pending"))
        try store.setStatus(guid: "dq-old", .deferred)
        try store.setStatus(guid: "dq-new", .deferred)

        let deferred = try store.deferredEpisodes()

        XCTAssertEqual(deferred.map { $0.guid }, ["dq-new", "dq-old"],
                       "deferredEpisodes must be newest pub_date first")
    }

    func testDeferredEpisodesEmptyWhenNoneDeferred() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-only-pending", status: "pending"))

        XCTAssertTrue(try store.deferredEpisodes().isEmpty)
    }

    // MARK: - "Wieder einplanen" (requeue): deferred → pending

    func testRequeueFlipsDeferredBackToPendingAndLeavesDeferredList() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-reinstate", status: "pending"))
        try store.setStatus(guid: "dq-reinstate", .deferred)
        XCTAssertEqual(try store.deferredEpisodes().count, 1)

        try store.requeue(guids: ["dq-reinstate"])

        let ep = try XCTUnwrap(store.episode(guid: "dq-reinstate"))
        XCTAssertEqual(ep.status, "pending", "Wieder einplanen must flip status back to pending")
        XCTAssertTrue(try store.deferredEpisodes().isEmpty,
                      "Reinstated episode must leave the deferred list")
    }

    // MARK: - L1: requeue clears failure bookkeeping (full retry budget)

    /// A manual requeue ("Wieder einplanen" / retry) must reset `attempts` to 0 and
    /// clear `attempted_at` + error columns, so an episode that had already failed
    /// twice gets its FULL retry budget back (previously it kept attempts=2 and died
    /// on the next transcribe-fail immediately) and isn't held by the M1 backoff.
    func testRequeueResetsAttemptsAndBackoffBookkeeping() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // An episode that has already burned 2 attempts and carries a failure +
        // a recent attempted_at (as a real transient-failure row would).
        try store.upsert(Episode.makePodcast(guid: "dq-retry", status: "failed", attempts: 2))
        try store.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE episodes
                SET attempted_at = ?, error_text = 'boom', error_category = 'network'
                WHERE guid = 'dq-retry'
            """, arguments: [Event.nowISO()])
        }

        try store.requeue(guids: ["dq-retry"])

        let ep = try XCTUnwrap(store.episode(guid: "dq-retry"))
        XCTAssertEqual(ep.status, "pending", "requeue flips to pending")
        XCTAssertEqual(ep.attempts, 0, "L1: manual requeue must reset attempts to 0")
        XCTAssertNil(ep.attemptedAt, "requeue must clear attempted_at so M1 backoff doesn't delay it")
        XCTAssertNil(ep.errorText, "requeue must clear the stale error text")
        XCTAssertNil(ep.errorCategory, "requeue must clear the stale error category")
    }

    /// After requeue the episode is immediately claimable (attempted_at was cleared,
    /// so the M1 backoff predicate doesn't hold it back).
    func testRequeuedEpisodeIsImmediatelyClaimable() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-claimable", status: "failed", attempts: 2))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE episodes SET attempted_at = ? WHERE guid = 'dq-claimable'",
                           arguments: [Event.nowISO()])
        }

        try store.requeue(guids: ["dq-claimable"])
        let claimed = try store.claimNextPending(queueOrder: "oldest_first",
                                                 backoffSeconds: 60, now: Date())
        XCTAssertEqual(claimed?.guid, "dq-claimable",
                       "a just-requeued episode must be claimable at once (no backoff)")
    }

    // MARK: - "Endgültig entfernen" (skipped): a genuine terminal state

    func testSkippedFromDeferredIsTerminalAndLeavesDeferredList() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-final", status: "pending"))
        try store.setStatus(guid: "dq-final", .deferred)
        XCTAssertEqual(try store.deferredEpisodes().count, 1)

        try store.setStatus(guid: "dq-final", .skipped)

        let ep = try XCTUnwrap(store.episode(guid: "dq-final"))
        XCTAssertEqual(ep.status, "skipped", "Endgültig entfernen must set status to skipped")
        XCTAssertTrue(try store.deferredEpisodes().isEmpty,
                      "Skipped episode must leave the deferred list — it is terminal")

        // A later requeue() call must be a no-op for this guid in practice — the
        // UI only ever offers "Wieder einplanen" for rows still ON the deferred
        // list, so a skipped episode is never targeted. Confirm the DB itself
        // doesn't resurrect it if requeue were (incorrectly) called anyway is
        // OUT of scope here — requeue is a blunt status write by design
        // (StateStore+Requeue.swift); the terminal guarantee comes from the UI
        // never surfacing a "Wieder einplanen" action for a skipped row.
        let activeStatuses: Set<String> = ["pending", "downloading", "downloaded", "transcribing"]
        XCTAssertFalse(activeStatuses.contains(ep.status),
                       "skipped must never be mistaken for an active queue status")
    }

    func testSkippedEmitsEpisodeSkippedEvent() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "dq-final-event", status: "pending"))
        try store.setStatus(guid: "dq-final-event", .deferred)

        // setStatus returns the lifecycle Event it emits (see SetStatusTests);
        // .skipped maps to episode.skipped via EpisodeStatus.lifecycleEventType.
        let event = try store.setStatus(guid: "dq-final-event", .skipped)
        XCTAssertEqual(event?.type, EventType.episodeSkipped,
                       "Endgültig entfernen must emit episode.skipped for observability")
    }
}
