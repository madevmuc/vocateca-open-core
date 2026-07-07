import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - SetStatusTests

/// Unit tests for `StateStore.setStatus` and `StateStore.recordFailure`.
///
/// Verifies status column updates, lifecycle event emission, and
/// `recordFailure` retry vs permanent logic, all against temp DBs.
final class SetStatusTests: XCTestCase {

    // MARK: - setStatus: returns the lifecycle Event (for bus emission)

    func testSetStatusReturnsLifecycleEventOrNil() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "ret-001"))

        let dl = try store.setStatus(guid: "ret-001", .downloading)
        XCTAssertEqual(dl?.type, EventType.episodeDownloadStarted)
        XCTAssertEqual(dl?.guid, "ret-001")

        let done = try store.setStatus(guid: "ret-001", .done)
        XCTAssertEqual(done?.type, EventType.episodeTranscribed)

        // A non-lifecycle status (pending) returns nil.
        XCTAssertNil(try store.setStatus(guid: "ret-001", .pending))
    }

    // MARK: - setStatus: event emission

    func testSetStatusDownloadingEmitsEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-dl-001")
        try store.upsert(ep)

        try store.setStatus(guid: "ev-dl-001", .downloading)

        let saved = try XCTUnwrap(store.episode(guid: "ev-dl-001"))
        XCTAssertEqual(saved.status, "downloading")
        XCTAssertNotNil(saved.attemptedAt, "attempted_at must be set on downloading")

        let events = try store.queryEvents(guid: "ev-dl-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeDownloadStarted),
                      "episode.download_started event must be emitted")
    }

    func testSetStatusDownloadedEmitsEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-dld-001")
        try store.upsert(ep)

        try store.setStatus(guid: "ev-dld-001", .downloaded)

        let events = try store.queryEvents(guid: "ev-dld-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeDownloaded))
    }

    func testSetStatusTranscribingEmitsEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-tr-001")
        try store.upsert(ep)

        try store.setStatus(guid: "ev-tr-001", .transcribing)

        let saved = try XCTUnwrap(store.episode(guid: "ev-tr-001"))
        XCTAssertNotNil(saved.attemptedAt)

        let events = try store.queryEvents(guid: "ev-tr-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeTranscribeStarted))
    }

    func testSetStatusDoneEmitsEventAndClearsErrors() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ep = Episode.makePodcast(guid: "ev-done-001", attempts: 2)
        ep.errorText = "previous error"
        ep.errorCategory = "network"
        try store.upsert(ep)

        try store.setStatus(guid: "ev-done-001", .done)

        let saved = try XCTUnwrap(store.episode(guid: "ev-done-001"))
        XCTAssertEqual(saved.status, "done")
        XCTAssertNotNil(saved.completedAt)
        // Error fields must be cleared on DONE (mirrors Python set_status).
        XCTAssertNil(saved.errorText, "error_text must be cleared on DONE")
        XCTAssertNil(saved.errorCategory, "error_category must be cleared on DONE")
        XCTAssertEqual(saved.attempts, 0, "attempts must be reset to 0 on DONE")

        let events = try store.queryEvents(guid: "ev-done-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeTranscribed))
    }

    func testSetStatusFailedStoresErrorText() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-fail-001")
        try store.upsert(ep)

        try store.setStatus(guid: "ev-fail-001", .failed, errorText: "connection refused")

        let saved = try XCTUnwrap(store.episode(guid: "ev-fail-001"))
        XCTAssertEqual(saved.status, "failed")
        XCTAssertEqual(saved.errorText, "connection refused")

        let events = try store.queryEvents(guid: "ev-fail-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeFailed))
    }

    func testSetStatusSkippedEmitsEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-skip-001")
        try store.upsert(ep)

        try store.setStatus(guid: "ev-skip-001", .skipped)

        let saved = try XCTUnwrap(store.episode(guid: "ev-skip-001"))
        XCTAssertEqual(saved.status, "skipped")

        let events = try store.queryEvents(guid: "ev-skip-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeSkipped))
    }

    func testSetStatusDeferredEmitsEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-deferred-001")
        try store.upsert(ep)

        try store.setStatus(guid: "ev-deferred-001", .deferred)

        let events = try store.queryEvents(guid: "ev-deferred-001")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains(EventType.episodeDeferred))
    }

    // MARK: - setStatus: silent statuses emit no events

    func testSetStatusPendingEmitsNoEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "ev-pending-001")
        try store.upsert(ep)

        // Transition to a non-silent status first to ensure we can distinguish.
        try store.setStatus(guid: "ev-pending-001", .downloading)
        // Now flip back to pending.
        try store.setStatus(guid: "ev-pending-001", .pending)

        let events = try store.queryEvents(guid: "ev-pending-001")
        let types = events.compactMap { $0["type"] as? String }
        // Only download_started should be present; NOT a second event for pending.
        XCTAssertEqual(types.count, 1, "pending transition must not emit an event")
        XCTAssertFalse(types.contains("episode.pending"))
    }

    // MARK: - recordFailure

    func testRecordFailureRetryTrue() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "rf-retry-001", attempts: 0)
        try store.upsert(ep)

        let newAttempts = try store.recordFailure(
            guid: "rf-retry-001",
            errorText: "network timeout",
            errorCategory: "network",
            retry: true
        )

        XCTAssertEqual(newAttempts, 1)

        let saved = try XCTUnwrap(store.episode(guid: "rf-retry-001"))
        XCTAssertEqual(saved.status, "pending", "retry:true must set status back to pending")
        XCTAssertEqual(saved.attempts, 1)
        XCTAssertEqual(saved.errorCategory, "network")
    }

    func testRecordFailureRetryFalse() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "rf-perm-001", attempts: 2)
        try store.upsert(ep)

        let newAttempts = try store.recordFailure(
            guid: "rf-perm-001",
            errorText: "404 not found",
            errorCategory: "not_found",
            retry: false
        )

        XCTAssertEqual(newAttempts, 3)

        let saved = try XCTUnwrap(store.episode(guid: "rf-perm-001"))
        XCTAssertEqual(saved.status, "failed", "retry:false must set status to failed")
        XCTAssertEqual(saved.attempts, 3)
        XCTAssertEqual(saved.errorText, "404 not found")
        XCTAssertEqual(saved.errorCategory, "not_found")
    }
}
