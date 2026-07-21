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

    private func tempWatchlistDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Hardened 2026-07-21: a drastic shrink is now REFUSED, not just backed up.
    /// The fuller file is snapshotted AND the write never lands — the on-disk
    /// file still holds all 18 shows. (The old behaviour backed up but let the
    /// clobber through, which is how a non-isolated test wiped the real
    /// watchlist.)
    func testDrasticShrinkIsRefusedAndOnDiskSurvives() throws {
        let dir = try tempWatchlistDir("shrink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let full = Watchlist(shows: (0..<18).map {
            Show(slug: "show-\($0)", title: "Show \($0)", rss: "https://x/\($0)", source: "podcast")
        })
        try full.save(to: url)

        let shrunk = Watchlist(shows: [Show(slug: "show-0", title: "Show 0", rss: "https://x/0", source: "podcast")])
        XCTAssertThrowsError(try shrunk.save(to: url)) { error in
            guard case Watchlist.WriteError.refusedDestructiveWrite(let reason, _) = error else {
                return XCTFail("expected refusedDestructiveWrite, got \(error)")
            }
            XCTAssertTrue(reason.contains("drastic shrink"), reason)
        }

        // The on-disk file is UNTOUCHED — still all 18 shows.
        XCTAssertEqual(try Watchlist.load(from: url).shows.count, 18)
        // …and a pre-shrink backup (also 18 shows) exists for recovery.
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("pre-shrink") }
        XCTAssertEqual(backups.count, 1, "expected one .pre-shrink backup")
    }

    /// The ONE legitimate whole-replace (an `.overwrite` import) opts in with
    /// `allowDrasticShrink: true` — it still backs up, but the write lands.
    func testDrasticShrinkProceedsWhenExplicitlyAllowed() throws {
        let dir = try tempWatchlistDir("allow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        try Watchlist(shows: (0..<18).map {
            Show(slug: "show-\($0)", title: "Show \($0)", rss: "https://x/\($0)", source: "podcast")
        }).save(to: url)

        let shrunk = Watchlist(shows: [Show(slug: "show-0", title: "Show 0", rss: "https://x/0", source: "podcast")])
        try shrunk.save(to: url, allowDrasticShrink: true)

        XCTAssertEqual(try Watchlist.load(from: url).shows.count, 1, "explicit opt-in lets the shrink land")
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("pre-shrink") }
        XCTAssertEqual(backups.count, 1, "still backs up even when allowed")
    }

    /// Artwork protection: blanking a SURVIVING show's populated artwork_url is
    /// refused even when the show count is unchanged — the exact loss the
    /// count-only guard missed (25→17-with-blanked-artwork dropped every
    /// thumbnail without a drastic count drop).
    func testBlankingSurvivingShowArtworkIsRefused() throws {
        let dir = try tempWatchlistDir("artwork")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchlist.yaml")

        let withArt = Watchlist(shows: (0..<6).map {
            Show(slug: "show-\($0)", title: "Show \($0)", rss: "https://x/\($0)",
                 artworkUrl: "https://img/\($0).jpg", source: "podcast")
        })
        try withArt.save(to: url)

        // Same 6 shows, artwork blanked — the clobber signature.
        let blanked = Watchlist(shows: (0..<6).map {
            Show(slug: "show-\($0)", title: "Show \($0)", rss: "https://x/\($0)",
                 artworkUrl: "", source: "podcast")
        })
        XCTAssertThrowsError(try blanked.save(to: url)) { error in
            guard case Watchlist.WriteError.refusedDestructiveWrite(let reason, _) = error else {
                return XCTFail("expected refusedDestructiveWrite, got \(error)")
            }
            XCTAssertTrue(reason.contains("artwork"), reason)
        }
        // On-disk artwork survives.
        XCTAssertEqual(try Watchlist.load(from: url).shows.first?.artworkUrl, "https://img/0.jpg")
    }

    func testArtworkBlankedSlugsPure() {
        let onDisk = [
            Show(slug: "a", title: "A", rss: "r", artworkUrl: "https://img/a.jpg", source: "podcast"),
            Show(slug: "b", title: "B", rss: "r", artworkUrl: "", source: "podcast"),
            Show(slug: "c", title: "C", rss: "r", artworkUrl: "https://img/c.jpg", source: "podcast"),
        ]
        // a: blanked (refuse). b: was already empty (fine). c: dropped entirely
        // (not a "surviving" show — count guard's job, not artwork's).
        let new = [
            Show(slug: "a", title: "A", rss: "r", artworkUrl: "", source: "podcast"),
            Show(slug: "b", title: "B", rss: "r", artworkUrl: "", source: "podcast"),
        ]
        XCTAssertEqual(Watchlist.artworkBlankedSlugs(onDisk: onDisk, new: new), ["a"])
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
