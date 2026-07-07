import XCTest
@testable import VocatecaCore

final class PodcastSearchTests: XCTestCase {

    func testParseSkipsEntriesWithoutFeedURL() throws {
        let json = """
        {
          "resultCount": 2,
          "results": [
            {
              "collectionName": "Acquired",
              "artistName": "Ben Gilbert and David Rosenthal",
              "feedUrl": "https://feeds.transistor.fm/acquired",
              "artworkUrl600": "https://example.com/600.jpg",
              "artworkUrl100": "https://example.com/100.jpg",
              "collectionId": 1234567890
            },
            {
              "collectionName": "No Feed Podcast",
              "artistName": "Nobody"
            }
          ]
        }
        """.data(using: .utf8)!

        let results = PodcastSearch.parse(json)
        XCTAssertEqual(results.count, 1)
        let r = try XCTUnwrap(results.first)
        XCTAssertEqual(r.title, "Acquired")
        XCTAssertEqual(r.author, "Ben Gilbert and David Rosenthal")
        XCTAssertEqual(r.feedURL, "https://feeds.transistor.fm/acquired")
        XCTAssertEqual(r.artworkURL, "https://example.com/600.jpg")
        XCTAssertEqual(r.collectionID, 1234567890)
        XCTAssertEqual(r.id, r.feedURL)
    }

    func testParseArtworkFallsBackTo100() {
        let json = """
        { "results": [ {
            "collectionName": "X", "artistName": "Y",
            "feedUrl": "https://x/feed", "artworkUrl100": "https://x/100.jpg"
        } ] }
        """.data(using: .utf8)!
        XCTAssertEqual(PodcastSearch.parse(json).first?.artworkURL, "https://x/100.jpg")
    }

    func testParseEmptyOrMalformed() {
        XCTAssertTrue(PodcastSearch.parse(Data()).isEmpty)
        XCTAssertTrue(PodcastSearch.parse("{}".data(using: .utf8)!).isEmpty)
        XCTAssertTrue(PodcastSearch.parse("not json".data(using: .utf8)!).isEmpty)
    }

    func testSearchEmptyTermReturnsEmpty() async throws {
        let out = try await PodcastSearch.search(term: "   ")
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - country + explicit

    func testParseCountryAndExplicitFields() throws {
        let json = """
        { "results": [ {
            "collectionName": "Show", "artistName": "Host",
            "feedUrl": "https://x/feed",
            "country": "USA",
            "collectionExplicitness": "explicit",
            "trackExplicitness": "notExplicit"
        } ] }
        """.data(using: .utf8)!
        let r = try XCTUnwrap(PodcastSearch.parse(json).first)
        XCTAssertEqual(r.country, "USA")
        // collectionExplicitness takes precedence over trackExplicitness.
        XCTAssertEqual(r.explicit, true)
    }

    func testParseExplicitFallsBackToTrackExplicitness() throws {
        let json = """
        { "results": [ {
            "collectionName": "Clean Show", "artistName": "Host",
            "feedUrl": "https://x/feed",
            "trackExplicitness": "cleaned"
        } ] }
        """.data(using: .utf8)!
        let r = try XCTUnwrap(PodcastSearch.parse(json).first)
        XCTAssertNil(r.country)
        XCTAssertEqual(r.explicit, false)
    }

    func testExplicitnessMapping() {
        XCTAssertEqual(PodcastSearch.explicitness("explicit"), true)
        XCTAssertEqual(PodcastSearch.explicitness("EXPLICIT"), true)
        XCTAssertEqual(PodcastSearch.explicitness("cleaned"), false)
        XCTAssertEqual(PodcastSearch.explicitness("notExplicit"), false)
        XCTAssertNil(PodcastSearch.explicitness(nil))
        XCTAssertNil(PodcastSearch.explicitness("unknown"))
    }
}
