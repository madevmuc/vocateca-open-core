import XCTest
@testable import VocatecaCore

// MARK: - ShowDisplayHandleTests

/// Tests for ``Show/displayHandle``.
///
/// Covers the six cases from the spec:
///  1. YouTube /@handle URL → "@handle"
///  2. YouTube channel-id feed URL → nil (no author-@-prefix) / author passthrough
///  3. Instagram profile URL → "@handle"
///  4. Podcast source → nil
///  5. Empty rss → nil
///  6. Author already "@x" → no double-@
final class ShowDisplayHandleTests: XCTestCase {

    // MARK: - Helpers

    private func show(
        source: String,
        rss: String,
        author: String? = nil
    ) -> Show {
        Show(slug: "test", title: "Test Show", rss: rss, source: source, author: author)
    }

    // MARK: - YouTube /@handle URL

    func testYouTubeHandleURL() {
        let s = show(source: "youtube", rss: "https://www.youtube.com/@veritasium")
        XCTAssertEqual(s.displayHandle, "@veritasium")
    }

    func testYouTubeHandleURLWithTrailingSlash() {
        let s = show(source: "youtube", rss: "https://www.youtube.com/@mkbhd/")
        XCTAssertEqual(s.displayHandle, "@mkbhd")
    }

    func testYouTubeHandleURLWithSubpath() {
        let s = show(source: "youtube", rss: "https://www.youtube.com/@somechannel/videos")
        XCTAssertEqual(s.displayHandle, "@somechannel")
    }

    // MARK: - YouTube channel-id feed URL (not a /@handle URL)

    func testYouTubeChannelIDFeedURL_nilWhenNoAuthorHandle() {
        // channel_id feed URL does not parse to .handle → no derived handle
        // and author is nil → displayHandle should be nil
        let s = show(
            source: "youtube",
            rss: "https://www.youtube.com/feeds/videos.xml?channel_id=UCxxxxxxxxxxxxxxxxxxxxxx"
        )
        XCTAssertNil(s.displayHandle)
    }

    func testYouTubeChannelIDFeedURL_authorHandlePassthrough() {
        // channel_id feed URL → URL parse fails to produce .handle
        // but author starts with "@" → return author as displayHandle
        let s = show(
            source: "youtube",
            rss: "https://www.youtube.com/feeds/videos.xml?channel_id=UCxxxxxxxxxxxxxxxxxxxxxx",
            author: "@veritasium"
        )
        XCTAssertEqual(s.displayHandle, "@veritasium")
    }

    func testYouTubeChannelIDFeedURL_authorWithoutAt_returnsNil() {
        // author present but doesn't start with "@" → not a handle; return nil
        let s = show(
            source: "youtube",
            rss: "https://www.youtube.com/feeds/videos.xml?channel_id=UCxxxxxxxxxxxxxxxxxxxxxx",
            author: "Veritasium"
        )
        XCTAssertNil(s.displayHandle)
    }

    // MARK: - Instagram profile URL

    func testInstagramProfileURL() {
        let s = show(source: "instagram", rss: "https://www.instagram.com/mkbhd")
        XCTAssertEqual(s.displayHandle, "@mkbhd")
    }

    func testInstagramProfileURLWithAtHandle() {
        let s = show(source: "instagram", rss: "@mkbhd")
        XCTAssertEqual(s.displayHandle, "@mkbhd")
    }

    func testInstagramStoryURL() {
        let s = show(source: "instagram", rss: "https://www.instagram.com/stories/someuser/12345678/")
        XCTAssertEqual(s.displayHandle, "@someuser")
    }

    func testInstagramBareHandle() {
        let s = show(source: "instagram", rss: "mkbhd")
        XCTAssertEqual(s.displayHandle, "@mkbhd")
    }

    // MARK: - Podcast source → nil

    func testPodcastSourceReturnsNil() {
        let s = show(source: "podcast", rss: "https://feeds.example.com/podcast.rss")
        XCTAssertNil(s.displayHandle)
    }

    func testPodcastSourceWithAuthorReturnsNil() {
        let s = show(source: "podcast", rss: "https://feeds.example.com/podcast.rss", author: "Some Author")
        XCTAssertNil(s.displayHandle)
    }

    // MARK: - Empty rss → nil

    func testEmptyRssReturnsNil() {
        let s = show(source: "youtube", rss: "")
        XCTAssertNil(s.displayHandle)
    }

    func testEmptyRssInstagramReturnsNil() {
        let s = show(source: "instagram", rss: "")
        XCTAssertNil(s.displayHandle)
    }

    // MARK: - No double-@ (author already "@x")

    func testYouTubeHandleURLNeverDoublesAt() {
        // The rss is already a /@handle URL — derived handle should not have "@@"
        let s = show(source: "youtube", rss: "https://www.youtube.com/@mkbhd", author: "@mkbhd")
        XCTAssertEqual(s.displayHandle, "@mkbhd")
        XCTAssertFalse(s.displayHandle?.hasPrefix("@@") ?? false)
    }

    func testInstagramNeverDoublesAt() {
        // The rss is a @handle — displayHandle strips and re-prefixes
        let s = show(source: "instagram", rss: "@mkbhd")
        XCTAssertEqual(s.displayHandle, "@mkbhd")
        XCTAssertFalse(s.displayHandle?.hasPrefix("@@") ?? false)
    }

    func testAuthorAlreadyAtPassthroughNeverDoubles() {
        // channel_id feed, author already starts with "@"
        let s = show(
            source: "youtube",
            rss: "https://www.youtube.com/feeds/videos.xml?channel_id=UCxxxxxxxxxxxxxxxxxxxxxx",
            author: "@mkbhd"
        )
        XCTAssertEqual(s.displayHandle, "@mkbhd")
        XCTAssertFalse(s.displayHandle?.hasPrefix("@@") ?? false)
    }

    // MARK: - Unrecognised / garbage input → nil

    func testGarbageRssReturnsNil() {
        let s = show(source: "youtube", rss: "not-a-url-at-all!!!!")
        XCTAssertNil(s.displayHandle)
    }

    func testInstagramReelURLReturnsNil() {
        // Reel URLs are not profile/story → not a follow-able account handle
        let s = show(source: "instagram", rss: "https://www.instagram.com/reel/CxYzABCD/")
        XCTAssertNil(s.displayHandle)
    }
}
