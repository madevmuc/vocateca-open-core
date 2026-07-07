import XCTest
@testable import VocatecaCore

// MARK: - MediaURLResolverTests

final class MediaURLResolverTests: XCTestCase {

    // MARK: - Single-item JSON parsing

    func testParse_singleVideo() throws {
        let json = """
        {
            "_type": "video",
            "id": "abc123",
            "title": "Great Talk with Alice",
            "uploader": "Alice Podcast",
            "webpage_url": "https://soundcloud.com/alice/great-talk"
        }
        """
        let result = try MediaURLResolver.parse(json: json)
        XCTAssertEqual(result.title,      "Great Talk with Alice")
        XCTAssertEqual(result.uploader,   "Alice Podcast")
        XCTAssertEqual(result.webpageURL, "https://soundcloud.com/alice/great-talk")
        XCTAssertFalse(result.isPlaylist)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testParse_upladerFallbackToChannel() throws {
        let json = """
        {
            "title": "Episode 1",
            "channel": "My Channel",
            "webpage_url": "https://vimeo.com/123"
        }
        """
        let result = try MediaURLResolver.parse(json: json)
        XCTAssertEqual(result.uploader, "My Channel")
    }

    func testParse_uploaderFallbackToCreator() throws {
        let json = """
        {
            "title": "Track",
            "creator": "DJ X",
            "webpage_url": "https://bandcamp.com/djx/track"
        }
        """
        let result = try MediaURLResolver.parse(json: json)
        XCTAssertEqual(result.uploader, "DJ X")
    }

    // MARK: - Playlist / channel JSON parsing

    func testParse_playlist() throws {
        let json = """
        {
            "_type": "playlist",
            "title": "Alice Podcast Playlist",
            "uploader": "Alice",
            "webpage_url": "https://soundcloud.com/alice",
            "entries": [
                {"id": "e1", "title": "Episode 1", "url": "https://soundcloud.com/alice/ep1"},
                {"id": "e2", "title": "Episode 2", "url": "https://soundcloud.com/alice/ep2"}
            ]
        }
        """
        let result = try MediaURLResolver.parse(json: json)
        XCTAssertTrue(result.isPlaylist)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].id,    "e1")
        XCTAssertEqual(result.entries[0].title, "Episode 1")
        XCTAssertEqual(result.entries[0].url,   "https://soundcloud.com/alice/ep1")
        XCTAssertEqual(result.entries[1].id,    "e2")
    }

    func testParse_playlistEntries_missingIdSkipped() throws {
        let json = """
        {
            "_type": "playlist",
            "title": "Playlist",
            "uploader": "X",
            "webpage_url": "https://example.com",
            "entries": [
                {"title": "No ID Entry"},
                {"id": "valid-id", "title": "Valid", "url": "https://example.com/valid"}
            ]
        }
        """
        let result = try MediaURLResolver.parse(json: json)
        XCTAssertEqual(result.entries.count, 1, "Entry without ID must be skipped")
        XCTAssertEqual(result.entries[0].id, "valid-id")
    }

    // MARK: - Invalid JSON

    func testParse_invalidJSON_throws() {
        XCTAssertThrowsError(try MediaURLResolver.parse(json: "not json at all")) { error in
            guard case MediaURLResolverError.invalidJSON = error else {
                XCTFail("Expected invalidJSON error, got \(error)")
                return
            }
        }
    }

    func testParse_emptyString_throws() {
        XCTAssertThrowsError(try MediaURLResolver.parse(json: ""))
    }

    // MARK: - parseEnumerateOutput (NDJSON)

    func testParseEnumerateOutput_twoLines() {
        let ndjson = """
        {"id":"v1","title":"Video 1","url":"https://sc.com/v1"}
        {"id":"v2","title":"Video 2","url":"https://sc.com/v2"}
        """
        let entries = MediaURLResolver.parseEnumerateOutput(ndjson)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id,  "v1")
        XCTAssertEqual(entries[1].title, "Video 2")
    }

    func testParseEnumerateOutput_emptyLines_skipped() {
        let ndjson = "\n\n{\"id\":\"v1\",\"title\":\"T1\",\"url\":\"u1\"}\n\n"
        let entries = MediaURLResolver.parseEnumerateOutput(ndjson)
        XCTAssertEqual(entries.count, 1)
    }

    func testParseEnumerateOutput_missingId_skipped() {
        let ndjson = """
        {"title":"No ID","url":"https://example.com"}
        {"id":"has-id","title":"Has ID","url":"https://example.com/ok"}
        """
        let entries = MediaURLResolver.parseEnumerateOutput(ndjson)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "has-id")
    }

    func testParseEnumerateOutput_urlFallbackToWebpageURL() {
        let ndjson = """
        {"id":"v1","title":"V","webpage_url":"https://vimeo.com/123"}
        """
        let entries = MediaURLResolver.parseEnumerateOutput(ndjson)
        XCTAssertEqual(entries[0].url, "https://vimeo.com/123")
    }

    // MARK: - Live network tests (env-gated)

    func testResolve_soundcloud_live() async throws {
        guard ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Live network test — set VOCATECA_RUN_NETWORK_TESTS=1 to enable")
        }
        let resolver = MediaURLResolver()
        let result = try await resolver.resolve("https://soundcloud.com/moby/go")
        XCTAssertFalse(result.title.isEmpty)
        XCTAssertFalse(result.webpageURL.isEmpty)
    }
}
