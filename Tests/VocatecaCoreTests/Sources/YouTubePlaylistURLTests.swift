import XCTest
@testable import VocatecaCore

/// Tests for ``YouTubePlaylistURL/playlistID(from:)``.
final class YouTubePlaylistURLTests: XCTestCase {

    func testPlaylistURL() {
        XCTAssertEqual(
            YouTubePlaylistURL.playlistID(from: "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"),
            "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"
        )
    }

    func testWatchURLWithListParam() {
        XCTAssertEqual(
            YouTubePlaylistURL.playlistID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123"),
            "PLabc123"
        )
    }

    func testShortWatchURLWithListParam() {
        XCTAssertEqual(
            YouTubePlaylistURL.playlistID(from: "https://youtu.be/dQw4w9WgXcQ?list=PLabc123"),
            "PLabc123"
        )
    }

    func testBareWatchURLNoList() {
        XCTAssertNil(YouTubePlaylistURL.playlistID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testNonYouTubeHost() {
        XCTAssertNil(YouTubePlaylistURL.playlistID(from: "https://vimeo.com/123?list=PLabc123"))
    }

    func testEmptyListParam() {
        XCTAssertNil(YouTubePlaylistURL.playlistID(from: "https://www.youtube.com/playlist?list="))
    }

    func testGarbageInput() {
        XCTAssertNil(YouTubePlaylistURL.playlistID(from: ""))
        XCTAssertNil(YouTubePlaylistURL.playlistID(from: "not a url"))
    }
}
