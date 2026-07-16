import XCTest
@testable import VocatecaCore

/// Guards local imports against the remote-fetch SSRF guard: every `Add → Local
/// & folder` import failed permanently with `refusedScheme("file")` because it
/// was routed through the network downloader (2026-07-16).
final class LocalMediaIngestTests: XCTestCase {

    private func makeEpisode(guid: String, mp3Url: String) -> Episode {
        Episode(guid: guid, showSlug: "s", title: "t", pubDate: "2026-07-16", mp3Url: mp3Url)
    }

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A user-imported file is used in place — no download, no safety refusal.
    func testLocalGuidWithExistingFileIsUsedInPlace() throws {
        let dir = try makeTempDir("local")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.mp3")
        try Data([0x00, 0x01]).write(to: file)

        let ep = makeEpisode(guid: "local:abc123", mp3Url: file.absoluteString)
        XCTAssertEqual(try URLSessionDownloader.localMediaURL(for: ep)?.path, file.path)
    }

    /// SECURITY: a feed-sourced episode must never name a local path — otherwise a
    /// hostile feed could point an enclosure at any readable file on the machine
    /// and have it transcribed into the library.
    func testFeedGuidWithFileURLIsNotTreatedAsLocal() throws {
        let dir = try makeTempDir("local2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.mp3")
        try Data([0x00]).write(to: file)

        let ep = makeEpisode(guid: "flightcast:01ABC", mp3Url: file.absoluteString)
        // nil → falls through to the normal path, where `safeURL` refuses file://.
        XCTAssertNil(try URLSessionDownloader.localMediaURL(for: ep))
    }

    func testRemoteURLIsNotTreatedAsLocal() throws {
        let ep = makeEpisode(guid: "local:abc123", mp3Url: "https://example.com/a.mp3")
        XCTAssertNil(try URLSessionDownloader.localMediaURL(for: ep))
    }

    /// The user moved or deleted the import — permanent, not a retry loop.
    func testLocalGuidWithMissingFileThrowsPermanent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).mp3")
        let ep = makeEpisode(guid: "local:abc123", mp3Url: missing.absoluteString)
        XCTAssertThrowsError(try URLSessionDownloader.localMediaURL(for: ep)) { error in
            guard case PipelineError.permanent = error else {
                return XCTFail("expected .permanent, got \(error)")
            }
        }
    }

    func testLocalGuidPointingAtADirectoryThrowsPermanent() throws {
        let dir = try makeTempDir("dir")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = makeEpisode(guid: "local:abc123", mp3Url: dir.absoluteString)
        XCTAssertThrowsError(try URLSessionDownloader.localMediaURL(for: ep))
    }
}
