import XCTest
@testable import VocatecaCore

final class YouTubePlaylistResolverTests: XCTestCase {
    func testMapsResolvedEntriesToPlaylistEntries() {
        let input = [
            ResolvedEntry(id: "abc123", title: "First video", url: "https://youtu.be/abc123"),
            ResolvedEntry(id: "def456", title: "Second video", url: "https://youtu.be/def456"),
        ]
        let mapped = YouTubePlaylistResolver.map(input)
        XCTAssertEqual(mapped, [
            PlaylistEntry(videoID: "abc123", title: "First video", url: "https://youtu.be/abc123"),
            PlaylistEntry(videoID: "def456", title: "Second video", url: "https://youtu.be/def456"),
        ])
    }

    func testMapsEmptyArray() {
        XCTAssertEqual(YouTubePlaylistResolver.map([]), [])
    }
}
