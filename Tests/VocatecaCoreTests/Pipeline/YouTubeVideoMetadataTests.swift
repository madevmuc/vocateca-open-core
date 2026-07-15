import XCTest
@testable import VocatecaCore

// MARK: - YouTubeVideoMetadataTests
//
// Task E.2 — protocol seam over a yt-dlp `--print` metadata probe, so
// ExtractedTranscript (Task E.3) can populate title/channelID/channelHandle
// testably via a fake instead of hitting the network.

final class YouTubeVideoMetadataTests: XCTestCase {

    // MARK: - parseMetaLine (pure, no I/O)

    func testParseMetaLine_fullFields() {
        let line = "dQw4w9WgXcQ|Never Gonna Give You Up|UCuAXFkgsw1L7xaCfnd5JJOw|@RickAstleyYT"
        let meta = YtDlpVideoMetadataFetcher.parseMetaLine(line)

        XCTAssertEqual(meta, YouTubeVideoMeta(
            videoID: "dQw4w9WgXcQ",
            title: "Never Gonna Give You Up",
            channelID: "UCuAXFkgsw1L7xaCfnd5JJOw",
            channelHandle: "@RickAstleyYT"
        ))
    }

    func testParseMetaLine_missingChannelFields() {
        let line = "dQw4w9WgXcQ|Never Gonna Give You Up|NA|NA"
        let meta = YtDlpVideoMetadataFetcher.parseMetaLine(line)

        XCTAssertEqual(meta?.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(meta?.title, "Never Gonna Give You Up")
        XCTAssertNil(meta?.channelID)
        XCTAssertNil(meta?.channelHandle)
    }

    func testParseMetaLine_malformed() {
        XCTAssertNil(YtDlpVideoMetadataFetcher.parseMetaLine("dQw4w9WgXcQ|Never Gonna Give You Up"))
        XCTAssertNil(YtDlpVideoMetadataFetcher.parseMetaLine(""))
    }

    // MARK: - language field (5th `--print` column)

    func testParseMetaLine_withLanguage() {
        let line = "dQw4w9WgXcQ|Never Gonna Give You Up|UCuAXFkgsw1L7xaCfnd5JJOw|@RickAstleyYT|en"
        let meta = YtDlpVideoMetadataFetcher.parseMetaLine(line)

        XCTAssertEqual(meta?.language, "en")
    }

    func testParseMetaLine_languageNAOrEmpty_isNil() {
        let na = YtDlpVideoMetadataFetcher.parseMetaLine("dQw4w9WgXcQ|Title|NA|NA|NA")
        let empty = YtDlpVideoMetadataFetcher.parseMetaLine("dQw4w9WgXcQ|Title|NA|NA|")

        XCTAssertNil(na?.language)
        XCTAssertNil(empty?.language)
    }

    /// Lines from before the `language` field was added (only 4 columns)
    /// must still parse, with `language == nil` — additive, not a breaking
    /// change to the `--print` contract.
    func testParseMetaLine_missingLanguageColumn_isNil() {
        let line = "dQw4w9WgXcQ|Never Gonna Give You Up|UCuAXFkgsw1L7xaCfnd5JJOw|@RickAstleyYT"
        let meta = YtDlpVideoMetadataFetcher.parseMetaLine(line)

        XCTAssertNil(meta?.language)
    }

    // MARK: - FakeVideoMetadataFetcher self-test

    func testFakeVideoMetadataFetcherReturnsScriptedMeta() async {
        let meta = YouTubeVideoMeta(videoID: "abc123", title: "A Title", channelID: "UCabc", channelHandle: "@handle")
        let fake = FakeVideoMetadataFetcher(script: ["https://youtu.be/abc123": meta])

        let result = await fake.fetchMeta(videoURL: "https://youtu.be/abc123")
        let miss = await fake.fetchMeta(videoURL: "https://youtu.be/unscripted")

        XCTAssertEqual(result, meta)
        XCTAssertNil(miss)
        XCTAssertEqual(fake.calls, ["https://youtu.be/abc123", "https://youtu.be/unscripted"])
    }

    // MARK: - YtDlpVideoMetadataFetcher unsafe-URL guard

    /// `"not-a-url"` is rejected by `URLSafety.safeURL` before any network
    /// access, so this stays a same-process unit test — no
    /// `VOCATECA_RUN_NETWORK_TESTS` gate needed.
    func testFetchMeta_rejectsUnsafeURL() async {
        let sut = YtDlpVideoMetadataFetcher()
        let result = await sut.fetchMeta(videoURL: "not-a-url")
        XCTAssertNil(result)
    }

    // MARK: - Live network (gated)

    func testFetchMeta_liveKnownVideo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOCATECA_RUN_NETWORK_TESTS"] == "1",
                           "network-gated: set VOCATECA_RUN_NETWORK_TESTS=1 to run")
        try XCTSkipUnless(BinaryManager().isInstalled(.ytDlp), "yt-dlp not installed")

        let sut = YtDlpVideoMetadataFetcher()
        let meta = await sut.fetchMeta(videoURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        XCTAssertNotNil(meta?.title)
    }
}
