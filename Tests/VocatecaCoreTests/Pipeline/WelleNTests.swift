import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - WelleNTests
//
// Tests for Welle N (new-episode notifications):
//   1. upsertEpisodeFromFeed returns NewEpisode on first insert, nil on conflict.
//   2. enqueueFront sets maximum priority so the episode is claimed first.

final class WelleNTests: XCTestCase {

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WelleNTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    // MARK: - A) New-episode surfacing

    /// First call with a new guid returns a NewEpisode with matching guid + title.
    func testUpsertReturnsNewEpisodeOnInsert() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try store.upsertEpisodeFromFeed(
            showSlug: "test-show",
            guid: "ep-new-001",
            title: "Brand New Episode",
            pubDate: "2026-06-28T08:00:00",
            mp3URL: "https://example.com/ep1.mp3",
            durationSec: 3600
        )

        let newEp = try XCTUnwrap(result, "First insert must return a NewEpisode")
        XCTAssertEqual(newEp.guid, "ep-new-001")
        XCTAssertEqual(newEp.title, "Brand New Episode")
    }

    /// Second call with the same guid (conflict) returns nil — not a new episode.
    func testUpsertReturnsNilOnConflict() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First insert.
        _ = try store.upsertEpisodeFromFeed(
            showSlug: "test-show",
            guid: "ep-conflict",
            title: "Episode",
            pubDate: "2026-06-28T08:00:00",
            mp3URL: "https://example.com/ep.mp3",
            durationSec: nil
        )

        // Re-poll: same guid — must return nil.
        let result = try store.upsertEpisodeFromFeed(
            showSlug: "test-show",
            guid: "ep-conflict",
            title: "Episode (Updated Title)",
            pubDate: "2026-06-28T08:00:00",
            mp3URL: "https://example.com/ep.mp3",
            durationSec: 1800
        )

        XCTAssertNil(result, "Second upsert of the same guid must return nil (not a new episode)")

        // Sanity: row should have updated title (conflict update still runs).
        let ep = try XCTUnwrap(store.episode(guid: "ep-conflict"))
        XCTAssertEqual(ep.title, "Episode (Updated Title)")
    }

    /// Multiple new guids in one poll each return a distinct NewEpisode.
    func testMultipleNewEpisodesAllReturned() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guids = ["a-ep", "b-ep", "c-ep"]
        var results: [NewEpisode] = []
        for guid in guids {
            if let new = try store.upsertEpisodeFromFeed(
                showSlug: "show",
                guid: guid,
                title: "Title-\(guid)",
                pubDate: "2026-06-28",
                mp3URL: "https://example.com/\(guid).mp3",
                durationSec: nil
            ) {
                results.append(new)
            }
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(results.map(\.guid)), Set(guids))
    }

    // MARK: - C) enqueueFront priority ordering

    /// enqueueFront sets the highest priority so the next claim picks that episode
    /// regardless of pub_date or other ordering criteria.
    func testEnqueueFrontIsClaimedFirst() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed three episodes; the oldest is normally picked first.
        let ep1 = Episode.makePodcast(guid: "ep-oldest", pubDate: "2020-01-01")
        let ep2 = Episode.makePodcast(guid: "ep-newest", pubDate: "2026-01-01")
        let epFront = Episode.makePodcast(guid: "ep-front", pubDate: "2023-06-15")
        try store.upsert(ep1)
        try store.upsert(ep2)
        try store.upsert(epFront)

        // Front-insert ep-front — should now be claimed ahead of ep-oldest.
        try store.enqueueFront(guid: "ep-front")

        let claimed = try XCTUnwrap(store.claimNextPending(queueOrder: "oldest_first"))
        XCTAssertEqual(claimed.guid, "ep-front",
                       "enqueueFront must elevate the episode above all other pending items")
    }

    /// enqueueFront sets priority = Int.max; a second enqueueFront call on a
    /// different episode should tie at the same priority (both Int.max) — in that
    /// case oldest pub_date wins. Both arriving at max-priority is rare in
    /// practice but must not crash.
    func testEnqueueFrontTwoEpisodesOrder() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let epA = Episode.makePodcast(guid: "ep-a", pubDate: "2025-01-01")
        let epB = Episode.makePodcast(guid: "ep-b", pubDate: "2024-01-01")
        try store.upsert(epA)
        try store.upsert(epB)

        try store.enqueueFront(guid: "ep-a")
        try store.enqueueFront(guid: "ep-b")

        // Both have max priority; oldest_first tiebreak → ep-b (2024) before ep-a (2025).
        let first = try XCTUnwrap(store.claimNextPending(queueOrder: "oldest_first"))
        XCTAssertEqual(first.guid, "ep-b",
                       "When two episodes share max priority, oldest pub_date wins")
    }

    /// enqueueFront on a terminal (done/failed) episode re-queues it.
    func testEnqueueFrontRequeuesTerminalEpisode() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ep = Episode.makePodcast(guid: "ep-done")
        ep.status = "done"
        try store.upsert(ep)

        // Should be claimable after enqueueFront.
        try store.enqueueFront(guid: "ep-done")

        let claimed = try store.claimNextPending(queueOrder: "oldest_first")
        XCTAssertEqual(claimed?.guid, "ep-done",
                       "enqueueFront must re-queue a terminal episode as pending")
    }

    // MARK: - Settings: dailySummary default

    func testDailySummaryDefaultIsTrue() {
        let s = Settings()
        XCTAssertTrue(s.dailySummary, "dailySummary must default to true")
    }

    func testDailySummaryDecodesFromYAML() throws {
        // Write a minimal settings YAML with daily_summary: false to a temp file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WelleNSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("settings.yaml")
        let yaml = "daily_summary: false\n"
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try SettingsStore.load(from: url, persistDefaultOnMissing: false)
        XCTAssertFalse(loaded.dailySummary,
                       "daily_summary: false in YAML must decode to false")
    }
}
