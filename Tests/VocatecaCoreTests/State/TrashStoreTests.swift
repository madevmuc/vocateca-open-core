import XCTest
import GRDB
@testable import VocatecaCore

/// Unit tests for the „Zuletzt gelöscht" trash (`TrashStore`): put→restore
/// round-trips for transcripts and shows, the 30-day purge threshold,
/// `deleteNow`, and the deferred-media finalize sweep. Everything runs against an
/// in-memory `StateStore` + a temp trash directory — no live DB / user files.
final class TrashStoreTests: XCTestCase {

    // MARK: - Harness

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a transcript `.md` + `.srt` pair under `<root>/<slug>/<stem>.*` and
    /// returns the two URLs (the layout the writer/delete path use).
    private func writeTranscriptFiles(root: URL, slug: String, stem: String,
                                      md: String, srt: String) throws -> [URL] {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mdURL = dir.appendingPathComponent("\(stem).md")
        let srtURL = dir.appendingPathComponent("\(stem).srt")
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        try srt.write(to: srtURL, atomically: true, encoding: .utf8)
        return [mdURL, srtURL]
    }

    // MARK: - Transcript round-trip

    func testPutTranscriptMovesFilesAndRestoreBringsThemBack() throws {
        let store = try StateStore.inMemory()
        let libRoot = try makeTempDir()
        let trashDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: libRoot); try? FileManager.default.removeItem(at: trashDir) }
        let trash = TrashStore(store: store, trashDir: trashDir)

        // Seed a done episode + its FTS row + transcript files on disk.
        let ep = Episode(guid: "g1", showSlug: "finance", title: "Steuern sparen",
                         pubDate: "2026-01-01", mp3Url: "http://x/a.mp3", status: "done",
                         transcriptPath: nil, completedAt: "2026-01-01T00:00:00+00:00")
        let files = try writeTranscriptFiles(root: libRoot, slug: "finance", stem: "g1",
                                             md: "# Steuern", srt: "1\n00:00 --> 00:01\nSteuererklärung\n")
        let epWithPath = { var e = ep; e.transcriptPath = files[0].path; return e }()
        try store.upsert(epWithPath)
        try store.indexTranscript(guid: "g1", showSlug: "finance", title: "Steuern sparen",
                                  content: "Steuererklärung und Bären")

        // PUT: files move into trash; DB transcript cleared by the caller-equivalent.
        let id = try trash.putTranscript(episode: epWithPath, files: files, priorStatus: "done",
                                         plainText: "Steuererklärung und Bären", mediaPath: nil)
        _ = try store.clearTranscriptAndSkip(guid: "g1")

        // Files are GONE from the library and PRESENT in the trash dir.
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path))
        let parked = trashDir.appendingPathComponent(id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.appendingPathComponent("g1.md").path))
        // FTS row dropped by clearTranscriptAndSkip; status is skipped.
        XCTAssertTrue(try store.searchTranscripts("Steuererklärung").isEmpty)
        XCTAssertEqual(try store.episode(guid: "g1")?.status, "skipped")
        XCTAssertEqual(try trash.count(), 1)

        // RESTORE: files come back, DB row returns to done with its path, FTS re-indexed.
        let restored = try trash.restore(id: id, watchlistURL: libRoot.appendingPathComponent("watchlist.yaml"))
        XCTAssertEqual(restored?.kind, .transcript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path), "md restored to original location")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].path), "srt restored to original location")
        let after = try XCTUnwrap(try store.episode(guid: "g1"))
        XCTAssertEqual(after.status, "done")
        XCTAssertEqual(after.transcriptPath, files[0].path)
        XCTAssertEqual(try store.searchTranscripts("Steuererklärung").map(\.guid), ["g1"],
                       "restored transcript is searchable again")
        XCTAssertEqual(try trash.count(), 0, "trash row removed after restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path), "parked dir removed after restore")
    }

    // MARK: - Deferred media

    func testPendingMediaFinalizesAfterWindowButUndoCancelsIt() throws {
        let store = try StateStore.inMemory()
        let libRoot = try makeTempDir()
        let trashDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: libRoot); try? FileManager.default.removeItem(at: trashDir) }
        let trash = TrashStore(store: store, trashDir: trashDir)

        // A media file on disk to be scheduled for deferred deletion.
        let mediaURL = libRoot.appendingPathComponent("a.mp3")
        try Data("audio".utf8).write(to: mediaURL)
        let ep = Episode(guid: "m1", showSlug: "s", title: "T", pubDate: "2026-01-01",
                         mp3Url: "http://x/a.mp3", status: "done", mp3Path: mediaURL.path)
        try store.upsert(ep)
        let files = try writeTranscriptFiles(root: libRoot, slug: "s", stem: "m1", md: "# a", srt: "srt")

        let past = Event.nowISO()  // window of 0s → ready immediately relative to a later now
        let id = try trash.putTranscript(episode: ep, files: files, priorStatus: "done",
                                         plainText: "body", mediaPath: mediaURL.path,
                                         undoWindowSeconds: 0, nowISO: past)

        // Finalize with a now AFTER ready → media erased, mp3_path cleared.
        let later = Event.iso(from: Event.date(fromISO: past).addingTimeInterval(5))
        let finalized = try trash.finalizePendingMedia(nowISO: later)
        XCTAssertEqual(finalized, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path), "media erased after window")
        XCTAssertNil(try store.episode(guid: "m1")?.mp3Path, "mp3_path cleared")

        // A second finalize is a no-op (row already gone).
        XCTAssertEqual(try trash.finalizePendingMedia(nowISO: later), 0)

        // Undo cancels a still-pending media delete: re-schedule then restore.
        try Data("audio".utf8).write(to: mediaURL)
        let ep2 = Episode(guid: "m2", showSlug: "s", title: "T2", pubDate: "2026-01-02",
                          mp3Url: "http://x/b.mp3", status: "done", mp3Path: mediaURL.path)
        try store.upsert(ep2)
        let files2 = try writeTranscriptFiles(root: libRoot, slug: "s", stem: "m2", md: "# b", srt: "srt")
        let id2 = try trash.putTranscript(episode: ep2, files: files2, priorStatus: "done",
                                          plainText: "body2", mediaPath: mediaURL.path,
                                          undoWindowSeconds: 6, nowISO: past)
        _ = try trash.restore(id: id2, watchlistURL: libRoot.appendingPathComponent("watchlist.yaml"))
        // After restore, a later finalize must NOT erase the media (row cancelled).
        XCTAssertEqual(try trash.finalizePendingMedia(nowISO: later), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path), "undo cancelled the media delete")
        XCTAssertNotEqual(id, id2)
    }

    // MARK: - Show round-trip

    func testPutAndRestoreShowRecreatesWatchlistEntryAndEpisodes() throws {
        let store = try StateStore.inMemory()
        let libRoot = try makeTempDir()
        let trashDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: libRoot); try? FileManager.default.removeItem(at: trashDir) }
        let trash = TrashStore(store: store, trashDir: trashDir)
        let watchlistURL = libRoot.appendingPathComponent("watchlist.yaml")

        let show = Show(slug: "podA", title: "Podcast A", rss: "http://x/feed", source: "podcast")
        let ep = Episode(guid: "e1", showSlug: "podA", title: "Ep 1", pubDate: "2026-01-01",
                         mp3Url: "http://x/1.mp3", status: "done")
        let files = try writeTranscriptFiles(root: libRoot, slug: "podA", stem: "e1", md: "# ep1", srt: "srt")

        let id = try trash.putShow(show: show, episodes: [ep], files: files,
                                   plainTextByGuid: ["e1": "einzigartiges Suchwort"])
        // Files parked; nothing in the watchlist yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        let wlBefore = (try? WatchlistStore.load(from: watchlistURL))
        XCTAssertEqual(wlBefore?.watchlist.shows.count ?? 0, 0)

        // RESTORE: watchlist entry re-added, episode row re-inserted, FTS re-indexed, files back.
        _ = try trash.restore(id: id, watchlistURL: watchlistURL)
        let wl = try WatchlistStore.load(from: watchlistURL)
        XCTAssertEqual(wl.watchlist.shows.map(\.slug), ["podA"])
        XCTAssertEqual(try store.episode(guid: "e1")?.title, "Ep 1")
        XCTAssertEqual(try store.searchTranscripts("Suchwort").map(\.guid), ["e1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertEqual(try trash.count(), 0)
    }

    // MARK: - Purge + deleteNow

    func testPurgeRemovesOnlyItemsOlderThanThreshold() throws {
        let store = try StateStore.inMemory()
        let libRoot = try makeTempDir()
        let trashDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: libRoot); try? FileManager.default.removeItem(at: trashDir) }
        let trash = TrashStore(store: store, trashDir: trashDir)

        let now = Event.nowISO()
        let old = Event.iso(from: Event.date(fromISO: now).addingTimeInterval(-40 * 86_400))  // 40 days ago
        let recent = Event.iso(from: Event.date(fromISO: now).addingTimeInterval(-5 * 86_400)) // 5 days ago

        let epOld = Episode(guid: "old", showSlug: "s", title: "Old", pubDate: "2026-01-01",
                            mp3Url: "http://x/o.mp3", status: "done")
        let epNew = Episode(guid: "new", showSlug: "s", title: "New", pubDate: "2026-01-01",
                            mp3Url: "http://x/n.mp3", status: "done")
        let fOld = try writeTranscriptFiles(root: libRoot, slug: "s", stem: "old", md: "o", srt: "o")
        let fNew = try writeTranscriptFiles(root: libRoot, slug: "s", stem: "new", md: "n", srt: "n")
        let idOld = try trash.putTranscript(episode: epOld, files: fOld, priorStatus: "done",
                                            plainText: "o", mediaPath: nil, nowISO: old)
        _ = try trash.putTranscript(episode: epNew, files: fNew, priorStatus: "done",
                                    plainText: "n", mediaPath: nil, nowISO: recent)
        XCTAssertEqual(try trash.count(), 2)

        let purged = try trash.purge(olderThanDays: 30, nowISO: now)
        XCTAssertEqual(purged, 1, "only the 40-day-old item is purged")
        XCTAssertEqual(try trash.items().map(\.guid), ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashDir.appendingPathComponent(idOld).path),
                       "purged item's parked dir removed")
    }

    func testDeleteNowRemovesItemAndFiles() throws {
        let store = try StateStore.inMemory()
        let libRoot = try makeTempDir()
        let trashDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: libRoot); try? FileManager.default.removeItem(at: trashDir) }
        let trash = TrashStore(store: store, trashDir: trashDir)

        let ep = Episode(guid: "g", showSlug: "s", title: "T", pubDate: "2026-01-01",
                         mp3Url: "http://x/a.mp3", status: "done")
        let files = try writeTranscriptFiles(root: libRoot, slug: "s", stem: "g", md: "m", srt: "s")
        let id = try trash.putTranscript(episode: ep, files: files, priorStatus: "done",
                                         plainText: "x", mediaPath: nil)
        XCTAssertEqual(try trash.count(), 1)

        try trash.deleteNow(id: id)
        XCTAssertEqual(try trash.count(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashDir.appendingPathComponent(id).path))
    }

    // MARK: - Schema lesson: trash tables present on a PRE-EXISTING DB

    /// Mirrors `TranscriptFTSTests.testFTSTablePresentWhenMigratorSkippedOnExistingDB`:
    /// on a DB that already has `episodes` (the Python-owned production case) the
    /// GRDB migrator is SKIPPED, so the `v6_trash` migration never runs. This
    /// proves `trash_items` is still created there via `ensureAdditiveTables`.
    func testTrashTablePresentWhenMigratorSkippedOnExistingDB() throws {
        let dir = try makeTempDir()
        let trashDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: trashDir) }
        let dbURL = dir.appendingPathComponent("state.sqlite")

        do {
            let seedQueue = try DatabaseQueue(path: dbURL.path)
            try seedQueue.write { db in
                try db.execute(sql: "CREATE TABLE episodes (guid TEXT PRIMARY KEY, show_slug TEXT, title TEXT);")
            }
        }
        let store = try StateStore(databaseURL: dbURL)
        let trash = TrashStore(store: store, trashDir: trashDir)

        // A put must succeed end-to-end (would throw "no such table" without the
        // ensureAdditiveTables entry).
        let ep = Episode(guid: "gp", showSlug: "s", title: "T", pubDate: "2026-01-01",
                         mp3Url: "http://x/a.mp3", status: "done")
        let files = try writeTranscriptFiles(root: dir, slug: "s", stem: "gp", md: "m", srt: "s")
        _ = try trash.putTranscript(episode: ep, files: files, priorStatus: "done",
                                    plainText: "x", mediaPath: nil)
        XCTAssertEqual(try trash.count(), 1,
                       "trash_items must be created by ensureAdditiveTables when the migrator is skipped")
    }
}
