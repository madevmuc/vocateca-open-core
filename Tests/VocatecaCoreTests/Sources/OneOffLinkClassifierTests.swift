import XCTest
@testable import VocatecaCore

final class OneOffLinkClassifierTests: XCTestCase {
    func testYouTubeVideo()   { XCTAssertEqual(OneOffLinkClassifier.classify("https://youtu.be/5XXa41BYRbo"), .youtube) }
    func testYouTubeChannel() { XCTAssertEqual(OneOffLinkClassifier.classify("https://youtube.com/@mkbhd"), .youtube) }
    func testInstagramPost()  { XCTAssertEqual(OneOffLinkClassifier.classify("https://instagram.com/p/Cabc123/"), .instagram) }
    func testInstagramHandle(){ XCTAssertEqual(OneOffLinkClassifier.classify("@natgeo"), .instagram) }
    func testPodcastFeed()    { XCTAssertEqual(OneOffLinkClassifier.classify("https://feeds.example.com/show.xml"), .podcast) }
    func testGeneric()        { XCTAssertEqual(OneOffLinkClassifier.classify("https://soundcloud.com/foo/bar"), .generic) }
    func testEmptyIsGeneric() { XCTAssertEqual(OneOffLinkClassifier.classify("   "), .generic) }

    func testGenericNoSubscribeFork() {
        XCTAssertFalse(OneOffLinkClassifier.classify("https://soundcloud.com/foo/bar").offersSubscribe)
    }
    func testYouTubeOffersSubscribe() {
        XCTAssertTrue(OneOffLinkClassifier.classify("https://youtu.be/5XXa41BYRbo").offersSubscribe)
    }

    func testSpotifyEpisode() {
        XCTAssertEqual(OneOffLinkClassifier.classify("https://open.spotify.com/episode/4cSHMKyfybiDBieC3uyze0"), .spotify)
    }
    func testSpotifyShow() {
        XCTAssertEqual(OneOffLinkClassifier.classify("https://open.spotify.com/show/abc123"), .spotify)
    }
    func testSpotifyNoGenericFork() {
        // Spotify is handled specially (podcast-directory route), not the generic fork.
        XCTAssertFalse(OneOffLinkClassifier.classify("https://open.spotify.com/episode/4cSHMKyfybiDBieC3uyze0").offersSubscribe)
    }
}
