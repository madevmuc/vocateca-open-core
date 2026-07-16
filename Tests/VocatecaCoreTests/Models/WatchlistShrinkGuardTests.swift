import XCTest
@testable import VocatecaCore

/// Guards the "partial in-memory watchlist silently overwrites the full file"
/// data-loss (2026-07-16: 18 shows → 1, the rest became artwork-less orphans).
final class WatchlistShrinkGuardTests: XCTestCase {

    func testIsDrasticShrink() {
        XCTAssertTrue(Watchlist.isDrasticShrink(onDisk: 18, new: 1))   // the real loss
        XCTAssertTrue(Watchlist.isDrasticShrink(onDisk: 4, new: 1))
        XCTAssertTrue(Watchlist.isDrasticShrink(onDisk: 10, new: 4))
        // Not drastic: normal edits / small lists.
        XCTAssertFalse(Watchlist.isDrasticShrink(onDisk: 18, new: 17)) // single delete
        XCTAssertFalse(Watchlist.isDrasticShrink(onDisk: 10, new: 6))  // keeps >half
        XCTAssertFalse(Watchlist.isDrasticShrink(onDisk: 3, new: 1))   // trivial list
        XCTAssertFalse(Watchlist.isDrasticShrink(onDisk: 5, new: 8))   // grew
        XCTAssertFalse(Watchlist.isDrasticShrink(onDisk: 0, new: 0))
    }

    /// Saving a 1-show watchlist over an 18-show file snapshots the fuller file
    /// to a `.pre-shrink-*.bak` sibling (recoverable + visible), then writes.
    func testDrasticShrinkSaveBacksUpPreviousFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-shrink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let full = Watchlist(shows: (0..<18).map {
            Show(slug: "show-\($0)", title: "Show \($0)", rss: "https://x/\($0)", source: "podcast")
        })
        try full.save(to: url)

        let shrunk = Watchlist(shows: [Show(slug: "show-0", title: "Show 0", rss: "https://x/0", source: "podcast")])
        try shrunk.save(to: url)

        // The new (1-show) file is written…
        XCTAssertEqual(try Watchlist.load(from: url).shows.count, 1)
        // …and a pre-shrink backup holding the full 18 shows exists.
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("pre-shrink") }
        XCTAssertEqual(backups.count, 1, "expected one .pre-shrink backup")
        if let b = backups.first {
            XCTAssertEqual(try Watchlist.load(from: dir.appendingPathComponent(b)).shows.count, 18)
        }
    }

    /// A normal single delete (18 → 17) does NOT create a backup.
    func testNormalDeleteDoesNotBackUp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-normal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let full = Watchlist(shows: (0..<18).map {
            Show(slug: "show-\($0)", title: "Show \($0)", rss: "https://x/\($0)", source: "podcast")
        })
        try full.save(to: url)
        let oneLess = Watchlist(shows: Array(full.shows.dropLast()))
        try oneLess.save(to: url)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("pre-shrink") }
        XCTAssertTrue(backups.isEmpty, "a single delete must not trigger the shrink guard")
    }
}
