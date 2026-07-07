import XCTest
import Foundation
@testable import VocatecaCore

/// Unit tests for ``ShowDeletion/deleteShowFully(slug:store:watchlistURL:outputRoot:mediaDir:)``.
///
/// Verifies that deleting a show removes ALL traces: DB episode rows, the
/// `watchlist.yaml` entry, the transcript directory, and the media directory —
/// and that a show with nothing on disk does not throw.
final class ShowDeletionTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh `StateStore` backed by a temp SQLite file, matching the
    /// pattern from `StateStoreTests.makeTempStore`.
    private func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShowDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir)
    }

    private func makeShow(slug: String) -> Show {
        Show(slug: slug, title: "Test Show \(slug)", rss: "https://example.com/\(slug).xml")
    }

    private func makeEpisode(showSlug: String, guid: String) -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: "Episode",
            pubDate: "2024-01-15",
            mp3Url: "https://example.com/\(guid).mp3",
            status: "done",
            durationSec: 1200,
            priority: 0,
            attempts: 0
        )
    }

    // MARK: - Full deletion

    func testDeleteShowFullyRemovesEverything() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let slug = "my-show"

        // Seed an episode row.
        try store.upsert(makeEpisode(showSlug: slug, guid: "guid-1"))
        XCTAssertEqual(try store.episodes(showSlug: slug).count, 1)

        // Seed a watchlist entry.
        let watchlistURL = dir.appendingPathComponent("watchlist.yaml")
        let wlStore = WatchlistStore()
        wlStore.add(makeShow(slug: slug))
        try wlStore.save(to: watchlistURL)

        // Seed on-disk transcript + media files.
        let outputRoot = dir.appendingPathComponent("transcripts", isDirectory: true)
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)
        let dirSlug = TextNormalization.slugify(slug)

        let showTranscriptDir = outputRoot.appendingPathComponent(dirSlug, isDirectory: true)
        let showMediaDir = mediaDir.appendingPathComponent(dirSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: showTranscriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: showMediaDir, withIntermediateDirectories: true)
        try "transcript".write(to: showTranscriptDir.appendingPathComponent("x.md"),
                                atomically: true, encoding: .utf8)
        try "audio".write(to: showMediaDir.appendingPathComponent("x.mp3"),
                           atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: showTranscriptDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: showMediaDir.path))

        // Act.
        try ShowDeletion.deleteShowFully(
            slug: slug,
            store: store,
            watchlistURL: watchlistURL,
            outputRoot: outputRoot,
            mediaDir: mediaDir
        )

        // Assert: DB rows gone.
        XCTAssertEqual(try store.episodes(showSlug: slug).count, 0,
            "episode rows for the deleted show must be gone")

        // Assert: watchlist entry gone.
        let reloaded = try WatchlistStore.load(from: watchlistURL)
        XCTAssertFalse(reloaded.watchlist.shows.contains { $0.slug == slug },
            "watchlist entry for the deleted show must be gone")

        // Assert: directories gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: showTranscriptDir.path),
            "transcript directory must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: showMediaDir.path),
            "media directory must be removed")
    }

    // MARK: - No files on disk

    func testDeleteShowFullyWithNoFilesOnDiskDoesNotThrow() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let slug = "no-files-show"

        try store.upsert(makeEpisode(showSlug: slug, guid: "guid-2"))

        let watchlistURL = dir.appendingPathComponent("watchlist.yaml")
        let wlStore = WatchlistStore()
        wlStore.add(makeShow(slug: slug))
        try wlStore.save(to: watchlistURL)

        // outputRoot/mediaDir exist as roots but the per-show subdirectories do not.
        let outputRoot = dir.appendingPathComponent("transcripts", isDirectory: true)
        let mediaDir = dir.appendingPathComponent("media", isDirectory: true)

        XCTAssertNoThrow(try ShowDeletion.deleteShowFully(
            slug: slug,
            store: store,
            watchlistURL: watchlistURL,
            outputRoot: outputRoot,
            mediaDir: mediaDir
        ))

        XCTAssertEqual(try store.episodes(showSlug: slug).count, 0)
        let reloaded = try WatchlistStore.load(from: watchlistURL)
        XCTAssertFalse(reloaded.watchlist.shows.contains { $0.slug == slug })
    }
}
