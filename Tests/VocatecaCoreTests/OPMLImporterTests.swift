import XCTest
@testable import VocatecaCore

final class OPMLImporterTests: XCTestCase {
    private static func tempWatchlistURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OPMLImporterTests-\(UUID().uuidString)")
            .appendingPathComponent("watchlist.yaml")
    }

    func testImportsAllNewFeedsAsAdded() throws {
        let url = Self.tempWatchlistURL()
        let feeds = [OPMLFeed(title: "A", feedURL: "https://a/rss"),
                     OPMLFeed(title: "B", feedURL: "https://b/rss")]
        let r = OPMLImporter.importFeeds(feeds, into: url)
        XCTAssertEqual(r.added.count, 2)
        XCTAssertTrue(r.failed.isEmpty)
        // Persisted: both shows now in the watchlist file.
        let store = try WatchlistStore.load(from: url)
        XCTAssertEqual(store.watchlist.shows.filter { $0.source == "podcast" }.count, 2)
    }

    func testImportedShowsDefaultToOnlyNewBackfill() throws {
        // Safe bulk default: a mass import must NOT put every feed's entire
        // back-catalogue in scope (that would be an enqueue avalanche for a Pro
        // auto-download user). Back-catalogue is opt-in via --backfill instead.
        let url = Self.tempWatchlistURL()
        _ = OPMLImporter.importFeeds([OPMLFeed(title: "A", feedURL: "https://a/rss")], into: url)
        let store = try WatchlistStore.load(from: url)
        XCTAssertEqual(store.watchlist.shows.first?.backfillMode, BackfillMode.onlyNew.rawValue)
    }

    func testAlreadySubscribedFeedCountsAsSkipped() throws {
        let url = Self.tempWatchlistURL()
        let feeds = [OPMLFeed(title: "A", feedURL: "https://a/rss")]
        _ = OPMLImporter.importFeeds(feeds, into: url)          // first import
        let r = OPMLImporter.importFeeds(feeds, into: url)      // second: same slug → skipped
        XCTAssertTrue(r.added.isEmpty)
        XCTAssertEqual(r.skipped.count, 1)
    }

    func testOneBadFeedDoesNotAbortTheRest() throws {
        let url = Self.tempWatchlistURL()
        // An empty feedURL can't subscribe → failed; the good one still added.
        let feeds = [OPMLFeed(title: "bad", feedURL: ""),
                     OPMLFeed(title: "good", feedURL: "https://g/rss")]
        let r = OPMLImporter.importFeeds(feeds, into: url)
        XCTAssertEqual(r.added, ["good"]) // slug of "good" is "good"
        XCTAssertEqual(r.failed.count, 1)
    }
}
