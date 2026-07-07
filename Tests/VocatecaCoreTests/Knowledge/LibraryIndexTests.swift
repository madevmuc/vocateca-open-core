import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - LibraryIndexTests

/// Tests for ``LibraryIndex`` — episode/file joining and missing-file tolerance.
final class LibraryIndexTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a temporary directory and returns its URL. Caller must clean up.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a minimal transcript `.md` file with the given YAML frontmatter guid.
    private func writeTranscript(
        dir: URL,
        showSlug: String,
        filename: String,
        guid: String?
    ) throws -> URL {
        let showDir = dir.appendingPathComponent(showSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
        let fileURL = showDir.appendingPathComponent("\(filename).md")
        var content = ""
        if let g = guid {
            content = "---\nguid: \(g)\ntitle: Test\n---\n\nBody text here.\n"
        } else {
            content = "# Episode\n\nBody text here.\n"
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Makes a minimal `Episode` with the given guid and showSlug.
    private func makeEpisode(guid: String, showSlug: String, title: String = "Test Episode") -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: title,
            pubDate: "2026-01-01T00:00:00",
            mp3Url: "https://example.com/\(guid).mp3"
        )
    }

    // MARK: - Tests

    /// An episode whose slug matches an on-disk `.md` filename must have a non-nil `transcriptURL`.
    func testIndexJoinsEpisodeWithMatchingFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let ep = makeEpisode(guid: "abc123", showSlug: "my-show")
        // MarkdownLibraryWriter.makeSlug strips to alphanumeric + -_
        // For guid "abc123" the slug is "abc123".
        try writeTranscript(dir: root, showSlug: "my-show", filename: "abc123", guid: "abc123")

        let index = LibraryIndex(outputRoot: root, episodes: [ep])
        let results = index.indexedEpisodes()

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[0].transcriptURL,
            "Episode with matching .md file must have non-nil transcriptURL")
        XCTAssertEqual(results[0].episode.guid, "abc123")
    }

    /// An episode with no matching file must have `transcriptURL == nil` (not crash).
    func testIndexToleratesMissingFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let ep = makeEpisode(guid: "no-file-guid", showSlug: "show-x")
        // No .md file is written.

        let index = LibraryIndex(outputRoot: root, episodes: [ep])
        let results = index.indexedEpisodes()

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].transcriptURL,
            "Episode with no matching file must have nil transcriptURL")
    }

    /// A missing outputRoot directory must not crash and must return all episodes with nil transcriptURL.
    func testIndexToleratesMissingOutputRoot() throws {
        let nonexistentRoot = URL(fileURLWithPath: "/tmp/vocateca-does-not-exist-\(UUID().uuidString)")
        let ep = makeEpisode(guid: "g1", showSlug: "show-a")

        let index = LibraryIndex(outputRoot: nonexistentRoot, episodes: [ep])
        let results = index.indexedEpisodes()

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].transcriptURL)
    }

    /// Mixed set: some episodes have files, some don't. Both cases handled correctly.
    func testIndexMixedEpisodes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let epWithFile    = makeEpisode(guid: "has-file", showSlug: "show-a")
        let epWithoutFile = makeEpisode(guid: "no-file",  showSlug: "show-a")

        try writeTranscript(dir: root, showSlug: "show-a", filename: "has-file", guid: "has-file")
        // "no-file" has no .md file.

        let index = LibraryIndex(outputRoot: root, episodes: [epWithFile, epWithoutFile])
        let results = index.indexedEpisodes()

        XCTAssertEqual(results.count, 2)
        let withFile    = results.first { $0.episode.guid == "has-file" }
        let withoutFile = results.first { $0.episode.guid == "no-file" }

        XCTAssertNotNil(withFile?.transcriptURL, "Episode with file must have transcriptURL")
        XCTAssertNil(withoutFile?.transcriptURL, "Episode without file must have nil transcriptURL")
    }

    /// GUID-based fallback: transcript with a YAML frontmatter guid is matched even when
    /// the filename does not match the episode slug.
    func testIndexFallsBackToGUIDLookup() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let ep = makeEpisode(guid: "special-guid-xyz", showSlug: "show-b")
        // Write the file with a DIFFERENT filename (old-style) but embed the guid.
        try writeTranscript(dir: root, showSlug: "show-b", filename: "oldstyle-name", guid: "special-guid-xyz")

        let index = LibraryIndex(outputRoot: root, episodes: [ep])
        let results = index.indexedEpisodes()

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[0].transcriptURL,
            "GUID-based fallback must match the transcript file even with a different filename")
    }

    /// `episodesByShow()` groups episodes correctly.
    func testEpisodesByShowGroups() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let epA1 = makeEpisode(guid: "a1", showSlug: "show-a")
        let epA2 = makeEpisode(guid: "a2", showSlug: "show-a")
        let epB1 = makeEpisode(guid: "b1", showSlug: "show-b")

        let index = LibraryIndex(outputRoot: root, episodes: [epA1, epA2, epB1])
        let grouped = index.episodesByShow()

        XCTAssertEqual(grouped["show-a"]?.count, 2, "show-a must have 2 episodes")
        XCTAssertEqual(grouped["show-b"]?.count, 1, "show-b must have 1 episode")
        XCTAssertNil(grouped["show-c"], "Non-existent show must not appear")
    }

    /// Empty episode list produces an empty result.
    func testIndexEmptyEpisodesReturnsEmpty() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let index = LibraryIndex(outputRoot: root, episodes: [])
        XCTAssertTrue(index.indexedEpisodes().isEmpty)
    }

    /// `index.md` files are ignored (not matched as transcripts).
    func testIndexMdSkipped() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Write index.md only — it should be ignored.
        let showDir = root.appendingPathComponent("show-c", isDirectory: true)
        try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
        let indexMd = showDir.appendingPathComponent("index.md")
        try "# Index\n".write(to: indexMd, atomically: true, encoding: .utf8)

        // Episode whose slug is "index" (shouldn't match index.md).
        let ep = Episode(
            guid: "index",
            showSlug: "show-c",
            title: "Index Episode",
            pubDate: "2026-01-01T00:00:00",
            mp3Url: "https://example.com/index.mp3"
        )

        let index = LibraryIndex(outputRoot: root, episodes: [ep])
        let results = index.indexedEpisodes()

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].transcriptURL,
            "index.md must be skipped and must not match any episode")
    }
}
