import XCTest
import Foundation
@testable import VocatecaCore

/// Tests for `StateStore.upsertEpisodeFromFeed` — the targeted feed-refresh
/// upsert that preserves pipeline state on conflict.
final class FeedUpsertTests: XCTestCase {

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedUpsertTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    // MARK: - Insert (no conflict)

    func testInsertNewEpisode() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsertEpisodeFromFeed(
            showSlug: "my-show",
            guid: "ep-001",
            title: "Episode One",
            pubDate: "2024-01-15T10:00:00",
            mp3URL: "https://example.com/ep1.mp3",
            durationSec: 3600
        )

        let ep = try XCTUnwrap(store.episode(guid: "ep-001"),
                               "Episode should exist after insert")
        XCTAssertEqual(ep.status, "pending",
                       "New episodes must be inserted with status=pending")
        XCTAssertEqual(ep.title, "Episode One")
        XCTAssertEqual(ep.mp3Url, "https://example.com/ep1.mp3")
        XCTAssertEqual(ep.durationSec, 3600)
        XCTAssertEqual(ep.attempts, 0)
    }

    // MARK: - L4: Defer-TOCTOU — insert lands the FINAL status directly

    /// With `initialStatus: .deferred` a freshly-inserted episode is born
    /// `deferred`, never a transient `pending` — closing the window in which a
    /// concurrent drain could claim an auto-download-OFF episode. The row must
    /// therefore never be visible to `claimNextPending`.
    func testInsertWithDeferredStatusLandsDirectly() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let new = try store.upsertEpisodeFromFeed(
            showSlug: "auto-off-show",
            guid: "ep-deferred",
            title: "Deferred Episode",
            pubDate: "2024-02-01T10:00:00",
            mp3URL: "https://example.com/deferred.mp3",
            durationSec: 1200,
            initialStatus: .deferred)

        XCTAssertNotNil(new, "a brand-new row is still reported as newly inserted")
        let ep = try XCTUnwrap(store.episode(guid: "ep-deferred"))
        XCTAssertEqual(ep.status, "deferred",
                       "L4: the row must be inserted DIRECTLY as deferred (no transient pending)")

        // The whole point: a concurrent drain must not be able to claim it.
        let claimed = try store.claimNextPending(queueOrder: "oldest_first")
        XCTAssertNil(claimed, "a deferred-at-insert episode must be invisible to the claim loop")
    }

    /// The default (`initialStatus` omitted) is still `pending` — unchanged for
    /// every existing caller / test.
    func testInsertDefaultsToPending() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsertEpisodeFromFeed(
            showSlug: "auto-on-show",
            guid: "ep-default",
            title: "Default Episode",
            pubDate: "2024-02-02T10:00:00",
            mp3URL: "https://example.com/default.mp3",
            durationSec: nil)

        XCTAssertEqual(try store.episode(guid: "ep-default")?.status, "pending",
                       "default initialStatus must remain pending (backward-compatible)")
    }

    /// On CONFLICT (existing row) `initialStatus` is IGNORED — an in-flight row's
    /// status is never disturbed even if a later poll passes `.deferred`.
    func testInitialStatusIgnoredOnConflict() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode(guid: "ep-conflict", showSlug: "s", title: "t",
                                 pubDate: "2024-01-01", mp3Url: "https://e/x.mp3",
                                 status: "transcribing", attempts: 1))
        // Re-poll passes .deferred — must NOT clobber the in-flight status.
        let new = try store.upsertEpisodeFromFeed(
            showSlug: "s", guid: "ep-conflict", title: "t2",
            pubDate: "2024-01-02", mp3URL: "https://e/y.mp3",
            durationSec: nil, initialStatus: .deferred)
        XCTAssertNil(new, "an existing row is an update, not a new insert")
        XCTAssertEqual(try store.episode(guid: "ep-conflict")?.status, "transcribing",
                       "initialStatus must not touch an existing (in-flight) row")
    }

    // MARK: - Conflict: preserves pipeline state

    /// The core correctness requirement: when a feed is re-polled while an
    /// episode is in flight, the upsert must NOT wipe its status or attempts.
    func testConflictPreservesInFlightStatus() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Insert via full upsert (simulating what the pipeline sets).
        var ep = Episode(
            guid: "ep-inflight",
            showSlug: "my-show",
            title: "Episode In-Flight",
            pubDate: "2024-01-20T10:00:00",
            mp3Url: "https://example.com/old.mp3",
            status: "downloading",
            durationSec: 1800,
            attempts: 1
        )
        try store.upsert(ep)

        // Sanity-check the in-flight state is persisted.
        let before = try XCTUnwrap(store.episode(guid: "ep-inflight"))
        XCTAssertEqual(before.status, "downloading")
        XCTAssertEqual(before.attempts, 1)

        // 2. Now the feed poll upserts the same guid with new metadata.
        try store.upsertEpisodeFromFeed(
            showSlug: "my-show",
            guid: "ep-inflight",
            title: "Episode In-Flight (Updated Title)",
            pubDate: "2024-01-20T10:00:00",
            mp3URL: "https://example.com/new.mp3",
            durationSec: nil   // feed doesn't have duration this time
        )

        // 3. Status, attempts, and existing duration_sec must be PRESERVED.
        let after = try XCTUnwrap(store.episode(guid: "ep-inflight"))
        XCTAssertEqual(after.status, "downloading",
                       "status must NOT be reset to pending on conflict")
        XCTAssertEqual(after.attempts, 1,
                       "attempts must NOT be reset on conflict")
        XCTAssertEqual(after.durationSec, 1800,
                       "duration_sec must be COALESCEd: keep existing when new value is nil")

        // 4. But mutable feed metadata IS updated.
        XCTAssertEqual(after.title, "Episode In-Flight (Updated Title)",
                       "title must be updated on conflict")
        XCTAssertEqual(after.mp3Url, "https://example.com/new.mp3",
                       "mp3_url must be updated on conflict")
    }

    /// If the new feed value has a non-nil duration, it should overwrite the old one.
    func testConflictUpdatesDurationWhenProvided() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Insert initial row.
        try store.upsertEpisodeFromFeed(
            showSlug: "s",
            guid: "guid-dur",
            title: "T",
            pubDate: "2024-01-01",
            mp3URL: "https://example.com/a.mp3",
            durationSec: 100
        )

        // Re-upsert with new duration.
        try store.upsertEpisodeFromFeed(
            showSlug: "s",
            guid: "guid-dur",
            title: "T updated",
            pubDate: "2024-01-01",
            mp3URL: "https://example.com/a.mp3",
            durationSec: 200
        )

        let ep = try XCTUnwrap(store.episode(guid: "guid-dur"))
        XCTAssertEqual(ep.durationSec, 200,
                       "duration_sec should be updated when the new value is non-nil")
    }

    /// COALESCE behaviour: existing non-nil duration preserved when new is nil.
    func testConflictPreservesDurationWhenNewIsNil() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsertEpisodeFromFeed(
            showSlug: "s",
            guid: "guid-dur-nil",
            title: "T",
            pubDate: "2024-01-01",
            mp3URL: "https://example.com/a.mp3",
            durationSec: 999
        )

        try store.upsertEpisodeFromFeed(
            showSlug: "s",
            guid: "guid-dur-nil",
            title: "T updated",
            pubDate: "2024-01-01",
            mp3URL: "https://example.com/a.mp3",
            durationSec: nil
        )

        let ep = try XCTUnwrap(store.episode(guid: "guid-dur-nil"))
        XCTAssertEqual(ep.durationSec, 999,
                       "COALESCE must preserve the existing duration when new value is nil")
    }

    /// Idempotent: calling twice with same values must not duplicate rows.
    func testUpsertIsIdempotent() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        for _ in 0..<3 {
            try store.upsertEpisodeFromFeed(
                showSlug: "s",
                guid: "idem-guid",
                title: "Same Title",
                pubDate: "2024-02-01",
                mp3URL: "https://example.com/b.mp3",
                durationSec: 60
            )
        }

        XCTAssertEqual(try store.episodeCount(), 1,
                       "Repeated upserts must not create duplicate rows")
    }

    /// Preserves transcript_path (completed episodes must not lose their path).
    func testConflictPreservesTranscriptPath() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Insert a "done" episode with a transcript path.
        var ep = Episode(
            guid: "ep-done",
            showSlug: "s",
            title: "Done",
            pubDate: "2024-01-01",
            mp3Url: "https://example.com/done.mp3",
            status: "done",
            transcriptPath: "/tmp/done.md"
        )
        try store.upsert(ep)

        // Feed re-polls and upserts the same guid.
        try store.upsertEpisodeFromFeed(
            showSlug: "s",
            guid: "ep-done",
            title: "Done (title may change)",
            pubDate: "2024-01-01",
            mp3URL: "https://example.com/done.mp3",
            durationSec: nil
        )

        let after = try XCTUnwrap(store.episode(guid: "ep-done"))
        XCTAssertEqual(after.status, "done",
                       "Completed episode status must not be reset to pending")
        XCTAssertEqual(after.transcriptPath, "/tmp/done.md",
                       "transcript_path must not be cleared by feed upsert")
    }
}
