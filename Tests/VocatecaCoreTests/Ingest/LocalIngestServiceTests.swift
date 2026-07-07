import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - LocalIngestServiceTests

final class LocalIngestServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() throws -> StateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalIngestServiceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try StateStore(databaseURL: dir.appendingPathComponent("state.sqlite"))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalIngestTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Slug rules

    func testSlugForFolderName_basic() {
        XCTAssertEqual(LocalIngestService.slugForFolderName("My Podcast"), "my-podcast")
    }

    func testSlugForFolderName_empty_fallsBackToBucket() {
        XCTAssertEqual(LocalIngestService.slugForFolderName(""), LocalIngestService.localFilesBucketSlug)
    }

    func testSlugForWatch_fileAtRoot_returnsBucketSlug() throws {
        let root = URL(fileURLWithPath: "/tmp/watchroot")
        let file = URL(fileURLWithPath: "/tmp/watchroot/episode.mp3")
        XCTAssertEqual(
            LocalIngestService.slugForWatch(fileURL: file, root: root),
            LocalIngestService.localFilesBucketSlug
        )
    }

    func testSlugForWatch_fileInSubfolder_returnsSubfolderSlug() throws {
        let root = URL(fileURLWithPath: "/tmp/watchroot")
        let file = URL(fileURLWithPath: "/tmp/watchroot/My Show/episode.mp3")
        XCTAssertEqual(
            LocalIngestService.slugForWatch(fileURL: file, root: root),
            "my-show"
        )
    }

    // MARK: - FNV-1a hash (dedup GUID)

    func testFnv1aHex_sameInputSameOutput() {
        let h1 = LocalIngestService.fnv1aHex("/tmp/test.mp3")
        let h2 = LocalIngestService.fnv1aHex("/tmp/test.mp3")
        XCTAssertEqual(h1, h2)
    }

    func testFnv1aHex_differentInputsDifferentOutput() {
        let h1 = LocalIngestService.fnv1aHex("/tmp/a.mp3")
        let h2 = LocalIngestService.fnv1aHex("/tmp/b.mp3")
        XCTAssertNotEqual(h1, h2)
    }

    func testFnv1aHex_format_16HexChars() {
        let h = LocalIngestService.fnv1aHex("hello")
        XCTAssertEqual(h.count, 16, "Expected 16 hex chars (64-bit hash)")
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit }, "Expected all hex chars")
    }

    // MARK: - import(fileURLs:) — video extension gate

    func testImportFileURLs_mp3_isRegistered() throws {
        let dir   = try makeTempDir()
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp3 = dir.appendingPathComponent("test.mp3")
        try Data(repeating: 0xFF, count: 16).write(to: mp3)

        let service = LocalIngestService(store: store, watchlistURL: nil)
        let results = try service.import(fileURLs: [mp3])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isNew)
        XCTAssertEqual(results[0].showSlug, LocalIngestService.localFilesBucketSlug)
        XCTAssertTrue(results[0].guid.hasPrefix("local:"))
    }

    func testImportFileURLs_mp4_video_isRegistered() throws {
        let dir   = try makeTempDir()
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp4 = dir.appendingPathComponent("video.mp4")
        try Data(repeating: 0x00, count: 16).write(to: mp4)

        let service = LocalIngestService(store: store, watchlistURL: nil)
        let results = try service.import(fileURLs: [mp4])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].showSlug, LocalIngestService.localFilesBucketSlug)
    }

    func testImportFileURLs_pdf_isSkipped() throws {
        let dir   = try makeTempDir()
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdf = dir.appendingPathComponent("doc.pdf")
        try "not audio".data(using: .utf8)!.write(to: pdf)

        let service = LocalIngestService(store: store, watchlistURL: nil)
        let results = try service.import(fileURLs: [pdf])

        XCTAssertTrue(results.isEmpty, "PDF must be skipped (not ingestable)")
        let episodes = try store.allEpisodes()
        XCTAssertTrue(episodes.isEmpty, "No episodes should be registered for a PDF")
    }

    // MARK: - Dedup

    func testImportSameFileTwice_secondIsNotNew() throws {
        let dir   = try makeTempDir()
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp3 = dir.appendingPathComponent("ep.mp3")
        try Data(repeating: 0xAB, count: 16).write(to: mp3)

        let service = LocalIngestService(store: store, watchlistURL: nil)
        let r1 = try service.import(fileURLs: [mp3])
        let r2 = try service.import(fileURLs: [mp3])

        XCTAssertEqual(r1.count, 1)
        XCTAssertEqual(r2.count, 1)
        XCTAssertTrue(r1[0].isNew,  "First import: should be new")
        XCTAssertFalse(r2[0].isNew, "Second import: should be duplicate (not new)")

        let episodes = try store.allEpisodes()
        XCTAssertEqual(episodes.count, 1, "Only one episode row should exist after two imports")
    }

    // MARK: - importFolder

    func testImportFolder_filesLandInFolderSlug() throws {
        let dir   = try makeTempDir()
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let folderName = "My Interview Series"
        let folder = dir.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 16).write(to: folder.appendingPathComponent("ep1.mp3"))
        try Data(repeating: 0xFF, count: 16).write(to: folder.appendingPathComponent("ep2.wav"))

        let service = LocalIngestService(store: store, watchlistURL: nil)
        let results = try service.importFolder(folder)

        XCTAssertEqual(results.count, 2)
        let slug = LocalIngestService.slugForFolderName(folderName)
        XCTAssertTrue(results.allSatisfy { $0.showSlug == slug })
    }

    func testImportFolder_nonMediaFilesSkipped() throws {
        let dir   = try makeTempDir()
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "txt".data(using: .utf8)!.write(to: folder.appendingPathComponent("readme.txt"))
        try Data(repeating: 0xFF, count: 16).write(to: folder.appendingPathComponent("audio.mp3"))

        let service = LocalIngestService(store: store, watchlistURL: nil)
        let results = try service.importFolder(folder)

        XCTAssertEqual(results.count, 1, "Only .mp3 should be registered; .txt skipped")
    }

    // MARK: - importURL

    func testImportURL_registersEpisode() throws {
        let store   = try makeTempStore()
        let service = LocalIngestService(store: store, watchlistURL: nil)

        let result = try service.importURL(
            title:      "SoundCloud Track",
            webpageURL: "https://soundcloud.com/artist/track",
            showSlug:   "artist",
            showTitle:  "Artist"
        )

        XCTAssertTrue(result.isNew)
        XCTAssertEqual(result.showSlug, "artist")
        XCTAssertTrue(result.guid.hasPrefix("local:"))
    }

    func testImportURL_dedup_byWebpageURL() throws {
        let store   = try makeTempStore()
        let service = LocalIngestService(store: store, watchlistURL: nil)
        let url = "https://soundcloud.com/artist/track"

        let r1 = try service.importURL(title: "Title", webpageURL: url, showSlug: "s", showTitle: "S")
        let r2 = try service.importURL(title: "Title", webpageURL: url, showSlug: "s", showTitle: "S")

        XCTAssertTrue(r1.isNew)
        XCTAssertFalse(r2.isNew, "Re-importing same URL should be a no-op")
    }

    // MARK: - isoDate

    func testIsoDateFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 29
        comps.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!
        XCTAssertEqual(LocalIngestService.isoDate(from: date), "2026-06-29")
    }
}
