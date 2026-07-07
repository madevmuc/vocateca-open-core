import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - FeedIngestorYtDlpTests

final class FeedIngestorYtDlpTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() throws -> StateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedIngestorYtDlpTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try StateStore(databaseURL: dir.appendingPathComponent("state.sqlite"))
    }

    // MARK: - Non-pollable guard: "local" source throws unsupportedSource

    func testPollLocalShow_throwsUnsupportedSource() async throws {
        let store = try makeTempStore()
        let ingestor = FeedIngestor()

        let localShow = Show(
            slug:   "local-files",
            title:  "Local files",
            rss:    "",
            source: "local"
        )

        do {
            _ = try await ingestor.poll(show: localShow, store: store)
            XCTFail("Expected unsupportedSource error for source=local")
        } catch FeedIngestorError.unsupportedSource(let src) {
            XCTAssertEqual(src, "local")
        }
    }

    // MARK: - parseEnumerateOutput (via MediaURLResolver) - shared fixture tests

    func testEnumerateOutput_twoEntries() {
        let ndjson = """
        {"id":"sc1","title":"Track One","url":"https://soundcloud.com/a/one"}
        {"id":"sc2","title":"Track Two","url":"https://soundcloud.com/a/two"}
        """
        let entries = MediaURLResolver.parseEnumerateOutput(ndjson)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, "sc1")
        XCTAssertEqual(entries[1].title, "Track Two")
    }

    // MARK: - ytdlp source: empty rss URL throws

    func testPollYtDlpShow_emptyRSS_throwsUnsupportedSource() async throws {
        let store = try makeTempStore()
        let ingestor = FeedIngestor()

        let show = Show(
            slug:   "my-channel",
            title:  "My Channel",
            rss:    "",       // empty — no URL to enumerate
            source: "ytdlp"
        )

        do {
            _ = try await ingestor.poll(show: show, store: store)
            XCTFail("Expected error for empty rss URL")
        } catch FeedIngestorError.unsupportedSource(_) {
            // expected: the ytdlp branch checks for empty URL
        } catch FeedIngestorError.fetchFailed(_) {
            // also acceptable if the branch propagates fetch failure
        }
    }

    // MARK: - Live network test (env-gated)

    func testPollYtDlpShow_soundcloud_live() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Live network test — set VOCATECA_RUN_NETWORK_TESTS=1 to enable")
        }
        let store = try makeTempStore()
        let ingestor = FeedIngestor(youtubeLimit: 3)

        let show = Show(
            slug:   "test-soundcloud",
            title:  "Test SoundCloud",
            rss:    "https://soundcloud.com/moby",
            source: "ytdlp"
        )

        let newEps = try await ingestor.poll(show: show, store: store).episodes
        XCTAssertFalse(newEps.isEmpty, "Expected at least one episode from live SoundCloud poll")
    }
}
