import XCTest
@testable import VocatecaCore

final class ShowAddedAtTests: XCTestCase {

    func testMemberwiseDefaultIsSentinel() {
        let s = Show(slug: "s", title: "T", rss: "r")
        XCTAssertEqual(s.addedAt, Show.defaultAddedAt)
    }

    func testDecodeAbsentKeyUsesSentinel() throws {
        let json = Data(#"{"slug":"s","title":"T","rss":"r"}"#.utf8)
        let show = try JSONDecoder().decode(Show.self, from: json)
        XCTAssertEqual(show.addedAt, Show.defaultAddedAt)
    }

    func testDecodePresentKeyPreserved() throws {
        let json = Data(#"{"slug":"s","title":"T","rss":"r","added_at":"2026-06-15"}"#.utf8)
        let show = try JSONDecoder().decode(Show.self, from: json)
        XCTAssertEqual(show.addedAt, "2026-06-15")
    }

    func testAddStampsNewShow() {
        let store = WatchlistStore()
        _ = store.add(Show(slug: "new-one", title: "New", rss: "https://feed/new"))
        let stored = store.watchlist.shows.first { $0.slug == "new-one" }
        XCTAssertNotNil(stored)
        XCTAssertNotEqual(stored?.addedAt, Show.defaultAddedAt, "a freshly added show is stamped with today's date")
    }

    func testAddUpdatePreservesOriginalAddedAt() {
        let store = WatchlistStore()
        _ = store.add(Show(slug: "dup", title: "First", rss: "https://feed/dup"))
        let original = store.watchlist.shows.first { $0.slug == "dup" }?.addedAt
        XCTAssertNotEqual(original, Show.defaultAddedAt)
        // Re-add same slug (e.g. metadata refresh) with a sentinel addedAt — must NOT reset.
        _ = store.add(Show(slug: "dup", title: "Updated", rss: "https://feed/dup"))
        let after = store.watchlist.shows.first { $0.slug == "dup" }
        XCTAssertEqual(after?.title, "Updated")
        XCTAssertEqual(after?.addedAt, original, "update must preserve the original subscription date")
    }
}
