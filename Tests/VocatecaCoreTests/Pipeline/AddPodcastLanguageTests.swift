import XCTest
@testable import VocatecaCore

/// Covers the language a newly subscribed podcast is stored with. The add flow
/// takes it from the feed's `<language>` (or the user's confirmation) — never
/// from a guessed default, which is what left 17 of 20 shows pinned to `de`.
final class AddPodcastLanguageTests: XCTestCase {

    private func makeTempWatchlist() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-addlang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("watchlist.yaml"))
    }

    /// The ASR engines take "de", not "de-DE", and feeds routinely declare a region.
    func testAddPodcastStoresPrimarySubtagOnly() throws {
        let (dir, url) = try makeTempWatchlist()
        defer { try? FileManager.default.removeItem(at: dir) }

        try WatchlistStore().addPodcast(feedURL: "https://x/f.xml", title: "Show A", author: "",
                                        language: "en-GB", to: url)
        XCTAssertEqual(try Watchlist.load(from: url).shows.first?.language, "en")
    }

    /// Adding without a language must leave auto-detect — never a guessed default.
    func testAddPodcastDefaultsToAutoDetect() throws {
        let (dir, url) = try makeTempWatchlist()
        defer { try? FileManager.default.removeItem(at: dir) }

        try WatchlistStore().addPodcast(feedURL: "https://x/f.xml", title: "Show B", author: "", to: url)
        let lang = try XCTUnwrap(Watchlist.load(from: url).shows.first?.language)
        XCTAssertTrue(Show.isAutoLanguage(lang))
    }

    func testAddPodcastNormalisesAutoSentinelToEmpty() throws {
        let (dir, url) = try makeTempWatchlist()
        defer { try? FileManager.default.removeItem(at: dir) }

        try WatchlistStore().addPodcast(feedURL: "https://x/f.xml", title: "Show C", author: "",
                                        language: "Auto", to: url)
        XCTAssertEqual(try Watchlist.load(from: url).shows.first?.language, Show.defaultLanguage)
    }
}
