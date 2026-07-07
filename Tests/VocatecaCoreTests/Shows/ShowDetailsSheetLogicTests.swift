import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - ShowDetailsSheet logic tests (pure, no UI)

/// Tests the pure filtering, date filtering, and sort comparators that live on
/// `ShowDetailsSheet`, plus the `StateStore.requeue(guids:)` path.
///
/// All tests that touch `StateStore` use a temp SQLite file to avoid touching
/// any production database.
final class ShowDetailsSheetLogicTests: XCTestCase {

    // MARK: - Episode factory helpers

    /// Make a minimal Episode for logic tests.
    private func ep(
        guid: String,
        title: String = "Episode",
        description: String? = nil,
        pubDate: String = "2024-01-01",
        durationSec: Int? = nil,
        status: String = "pending"
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: "test-show",
            title: title,
            pubDate: pubDate,
            mp3Url: "https://example.com/\(guid).mp3",
            status: status,
            durationSec: durationSec,
            description: description
        )
    }

    // MARK: - Text search: title match

    func testFilterMatchesTitle() {
        let episodes: [Episode] = [
            ep(guid: "a", title: "Swift Concurrency Deep Dive"),
            ep(guid: "b", title: "Python Tips and Tricks"),
            ep(guid: "c", title: "SwiftUI Layout"),
        ]
        let results = EpisodeFilterLogic.filter(episodes, query: "swift", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.map(\.guid).sorted(), ["a", "c"])
    }

    func testFilterIsCaseInsensitive() {
        let episodes: [Episode] = [
            ep(guid: "a", title: "SWIFT Power"),
            ep(guid: "b", title: "Python"),
        ]
        let results = EpisodeFilterLogic.filter(episodes, query: "swift", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.map(\.guid), ["a"])
    }

    // MARK: - Text search: description match

    func testFilterMatchesDescription() {
        let episodes: [Episode] = [
            ep(guid: "a", title: "Episode 1", description: "Discusses async/await in Swift"),
            ep(guid: "b", title: "Episode 2", description: "All about Python decorators"),
        ]
        let results = EpisodeFilterLogic.filter(episodes, query: "async", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.map(\.guid), ["a"])
    }

    func testFilterMatchesTitleOrDescription() {
        let episodes: [Episode] = [
            ep(guid: "a", title: "Actors in Swift",  description: "Covers structured concurrency"),
            ep(guid: "b", title: "Episode B",        description: "Coroutines in Kotlin"),
            ep(guid: "c", title: "Coroutines Guide", description: "Classic threading patterns"),
        ]
        let results = EpisodeFilterLogic.filter(episodes, query: "coroutines", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.map(\.guid).sorted(), ["b", "c"])
    }

    func testFilterEmptyQueryReturnsAll() {
        let episodes: [Episode] = [ep(guid: "a"), ep(guid: "b"), ep(guid: "c")]
        let results = EpisodeFilterLogic.filter(episodes, query: "", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.count, 3)
    }

    func testFilterWhitespaceOnlyQueryReturnsAll() {
        let episodes: [Episode] = [ep(guid: "a"), ep(guid: "b")]
        let results = EpisodeFilterLogic.filter(episodes, query: "   ", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Date filter

    func testDateFilterFromOnly() {
        let episodes: [Episode] = [
            ep(guid: "old",   pubDate: "2023-01-15"),
            ep(guid: "exact", pubDate: "2024-03-01"),
            ep(guid: "new",   pubDate: "2024-06-10"),
        ]
        let from = date("2024-03-01")
        let results = EpisodeFilterLogic.filter(episodes, query: "", dateFrom: from, dateTo: nil)
        XCTAssertEqual(results.map(\.guid).sorted(), ["exact", "new"])
    }

    func testDateFilterToOnly() {
        let episodes: [Episode] = [
            ep(guid: "old",   pubDate: "2023-01-15"),
            ep(guid: "mid",   pubDate: "2024-03-01"),
            ep(guid: "new",   pubDate: "2024-12-31"),
        ]
        let to = date("2024-06-30")
        let results = EpisodeFilterLogic.filter(episodes, query: "", dateFrom: nil, dateTo: to)
        XCTAssertEqual(results.map(\.guid).sorted(), ["mid", "old"])
    }

    func testDateFilterRange() {
        let episodes: [Episode] = [
            ep(guid: "before",  pubDate: "2023-12-31"),
            ep(guid: "start",   pubDate: "2024-01-01"),
            ep(guid: "middle",  pubDate: "2024-06-15"),
            ep(guid: "end",     pubDate: "2024-12-31"),
            ep(guid: "after",   pubDate: "2025-01-01"),
        ]
        let from = date("2024-01-01")
        let to   = date("2024-12-31")
        let results = EpisodeFilterLogic.filter(episodes, query: "", dateFrom: from, dateTo: to)
        XCTAssertEqual(results.map(\.guid).sorted(), ["end", "middle", "start"])
    }

    func testDateFilterAndTextCombined() {
        let episodes: [Episode] = [
            ep(guid: "a", title: "Swift Actors", pubDate: "2024-03-01"),
            ep(guid: "b", title: "Swift Memory", pubDate: "2023-01-01"),
            ep(guid: "c", title: "Python",       pubDate: "2024-06-01"),
        ]
        let from = date("2024-01-01")
        let results = EpisodeFilterLogic.filter(episodes, query: "swift", dateFrom: from, dateTo: nil)
        XCTAssertEqual(results.map(\.guid), ["a"])
    }

    // MARK: - Sort comparators

    func testSortByTitleAscending() {
        let episodes: [Episode] = [
            ep(guid: "z", title: "Zebra"),
            ep(guid: "a", title: "Apple"),
            ep(guid: "m", title: "Mango"),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .title, ascending: true)
        XCTAssertEqual(sorted.map(\.guid), ["a", "m", "z"])
    }

    func testSortByTitleDescending() {
        let episodes: [Episode] = [
            ep(guid: "a", title: "Apple"),
            ep(guid: "z", title: "Zebra"),
            ep(guid: "m", title: "Mango"),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .title, ascending: false)
        XCTAssertEqual(sorted.map(\.guid), ["z", "m", "a"])
    }

    func testSortByDateAscending() {
        let episodes: [Episode] = [
            ep(guid: "c", pubDate: "2024-06-01"),
            ep(guid: "a", pubDate: "2024-01-01"),
            ep(guid: "b", pubDate: "2024-03-15"),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .date, ascending: true)
        XCTAssertEqual(sorted.map(\.guid), ["a", "b", "c"])
    }

    func testSortByDateDescending() {
        let episodes: [Episode] = [
            ep(guid: "a", pubDate: "2024-01-01"),
            ep(guid: "c", pubDate: "2024-06-01"),
            ep(guid: "b", pubDate: "2024-03-15"),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .date, ascending: false)
        XCTAssertEqual(sorted.map(\.guid), ["c", "b", "a"])
    }

    func testSortByDurationAscending() {
        let episodes: [Episode] = [
            ep(guid: "long",  durationSec: 3600),
            ep(guid: "short", durationSec: 120),
            ep(guid: "mid",   durationSec: 900),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .duration, ascending: true)
        XCTAssertEqual(sorted.map(\.guid), ["short", "mid", "long"])
    }

    func testSortByDurationDescending() {
        let episodes: [Episode] = [
            ep(guid: "short", durationSec: 120),
            ep(guid: "long",  durationSec: 3600),
            ep(guid: "mid",   durationSec: 900),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .duration, ascending: false)
        XCTAssertEqual(sorted.map(\.guid), ["long", "mid", "short"])
    }

    func testSortByDurationNilTreatedAsZero() {
        // Episodes with no duration (nil) should sort as 0 seconds
        let episodes: [Episode] = [
            ep(guid: "has-dur",  durationSec: 300),
            ep(guid: "no-dur",   durationSec: nil),
        ]
        let sorted = EpisodeFilterLogic.sort(episodes, by: .duration, ascending: true)
        XCTAssertEqual(sorted.map(\.guid), ["no-dur", "has-dur"])
    }

    // MARK: - StateStore.requeue(guids:)

    func testRequeueSetsStatusToPending() throws {
        let (store, dir) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep1 = Episode.makePodcast(guid: "rq-1", status: "done")
        let ep2 = Episode.makePodcast(guid: "rq-2", status: "failed")
        let ep3 = Episode.makePodcast(guid: "rq-3", status: "done")  // not requeued
        try store.upsert(ep1)
        try store.upsert(ep2)
        try store.upsert(ep3)

        try store.requeue(guids: ["rq-1", "rq-2"])

        let saved1 = try XCTUnwrap(store.episode(guid: "rq-1"))
        let saved2 = try XCTUnwrap(store.episode(guid: "rq-2"))
        let saved3 = try XCTUnwrap(store.episode(guid: "rq-3"))

        XCTAssertEqual(saved1.status, "pending", "rq-1 should be re-queued to pending")
        XCTAssertEqual(saved2.status, "pending", "rq-2 should be re-queued to pending")
        XCTAssertEqual(saved3.status, "done",    "rq-3 must remain done (not in requeue list)")
    }

    func testRequeueEmptyListIsNoOp() throws {
        let (store, dir) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "rq-noop", status: "done")
        try store.upsert(ep)

        // Should not throw and should not change anything
        XCTAssertNoThrow(try store.requeue(guids: []))

        let saved = try XCTUnwrap(store.episode(guid: "rq-noop"))
        XCTAssertEqual(saved.status, "done")
    }

    func testRequeueMissingGuidIsIgnored() throws {
        let (store, dir) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "rq-real", status: "done")
        try store.upsert(ep)

        // Including a non-existent guid should not crash or throw
        XCTAssertNoThrow(try store.requeue(guids: ["rq-real", "no-such-guid"]))

        let saved = try XCTUnwrap(store.episode(guid: "rq-real"))
        XCTAssertEqual(saved.status, "pending")
    }

    // MARK: - WatchlistStore.updateLanguage

    func testUpdateLanguagePersistsToYAML() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let show = Show(slug: "lang-test", title: "Lang Test", rss: "", language: "de")
        let wlStore = WatchlistStore()
        wlStore.add(show)
        try wlStore.save(to: url)

        // Update language to "en"
        try wlStore.updateLanguage(slug: "lang-test", language: "en", to: url)

        // Reload from disk and verify
        let reloaded = try WatchlistStore.load(from: url)
        let savedShow = try XCTUnwrap(reloaded.watchlist.shows.first { $0.slug == "lang-test" })
        XCTAssertEqual(savedShow.language, "en")
    }

    func testUpdateLanguageUnknownSlugIsNoOp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let wlStore = WatchlistStore()
        try wlStore.save(to: url)

        // Should not throw when slug not found
        XCTAssertNoThrow(try wlStore.updateLanguage(slug: "no-such-slug", language: "en", to: url))
    }

    func testUpdateEnabledPersistsToYAML() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let show = Show(slug: "enabled-test", title: "Enabled Test", rss: "", enabled: true)
        let wlStore = WatchlistStore()
        wlStore.add(show)
        try wlStore.save(to: url)

        try wlStore.updateEnabled(slug: "enabled-test", enabled: false, to: url)

        let reloaded = try WatchlistStore.load(from: url)
        let savedShow = try XCTUnwrap(reloaded.watchlist.shows.first { $0.slug == "enabled-test" })
        XCTAssertFalse(savedShow.enabled)
    }

    // MARK: - Private helpers

    private func makeTemp() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShowDetailsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShowDetailsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: ymd)!
    }
}
