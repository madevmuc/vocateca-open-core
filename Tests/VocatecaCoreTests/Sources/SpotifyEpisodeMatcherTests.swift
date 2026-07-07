import XCTest
@testable import VocatecaCore

/// Pure-logic tests for lining a Spotify episode up with a public RSS feed item.
final class SpotifyEpisodeMatcherTests: XCTestCase {

    private func entry(_ title: String, mp3: String = "https://cdn.example/a.mp3") -> ManifestEntry {
        ManifestEntry(guid: title, title: title, pubDate: "2026-01-01T00:00:00",
                      duration: "00:00:00", episodeNumber: "0000", mp3URL: mp3,
                      description: "", url: "")
    }

    // MARK: normalize

    func testNormalizeFoldsCasePunctuationDiacritics() {
        XCTAssertEqual(
            SpotifyEpisodeMatcher.normalize("Folge #193, Sascha Firtina, Co-Founder von gocomo"),
            "folge 193 sascha firtina co founder von gocomo")
        XCTAssertEqual(SpotifyEpisodeMatcher.normalize("  Über   Änderungen! "), "uber anderungen")
        XCTAssertEqual(SpotifyEpisodeMatcher.normalize("—:—"), "")
    }

    // MARK: bestMatch

    func testExactTitleMatchWins() {
        let title = "Folge #193, Sascha Firtina, Co-Founder von gocomo"
        let entries = [entry("Ganz andere Folge"), entry(title), entry("Noch eine")]
        let m = SpotifyEpisodeMatcher.bestMatch(episodeTitle: title, in: entries)
        XCTAssertEqual(m?.title, title)
    }

    func testMatchesDespitePunctuationAndCaseDifferences() {
        // Spotify title vs a feed title that differs only in punctuation/case.
        let spotify = "Folge #193, Sascha Firtina, Co-Founder von gocomo"
        let feed    = "Folge 193 – Sascha Firtina, Co Founder von Gocomo"
        let entries = [entry("Intro-Folge"), entry(feed)]
        let m = SpotifyEpisodeMatcher.bestMatch(episodeTitle: spotify, in: entries)
        XCTAssertEqual(m?.title, feed)
    }

    func testUnrelatedEpisodeDoesNotMatch() {
        let spotify = "Folge #193, Sascha Firtina, Co-Founder von gocomo"
        let entries = [entry("Folge #12, ein völlig anderes Thema"),
                       entry("Willkommen zur ersten Ausgabe")]
        XCTAssertNil(SpotifyEpisodeMatcher.bestMatch(episodeTitle: spotify, in: entries))
    }

    func testEmptyEntriesReturnNil() {
        XCTAssertNil(SpotifyEpisodeMatcher.bestMatch(episodeTitle: "Anything", in: []))
    }

    func testSkipsEntriesWithoutAudio() {
        let title = "Folge #193, Sascha Firtina, Co-Founder von gocomo"
        // Even an exact-title item is useless without an enclosure → not returned.
        let entries = [entry("Folge #193, Sascha Firtina, Co-Founder von gocomo", mp3: "")]
        XCTAssertNil(SpotifyEpisodeMatcher.bestMatch(episodeTitle: title, in: entries))
    }

    // MARK: bestShow

    func testBestShowPrefersExactTitle() {
        let results = [
            PodcastSearchResult(title: "What's Next", author: "x", feedURL: "https://a/f", artworkURL: nil, collectionID: nil),
            PodcastSearchResult(title: "What's Next, Agencies?", author: "Kim", feedURL: "https://b/feed", artworkURL: nil, collectionID: nil),
        ]
        let s = SpotifyEpisodeMatcher.bestShow(named: "What's Next, Agencies?", in: results)
        XCTAssertEqual(s?.feedURL, "https://b/feed")
    }

    func testBestShowReturnsNilWhenNothingClose() {
        let results = [
            PodcastSearchResult(title: "Completely Different Podcast", author: "x", feedURL: "https://a/f", artworkURL: nil, collectionID: nil),
        ]
        XCTAssertNil(SpotifyEpisodeMatcher.bestShow(named: "What's Next, Agencies?", in: results))
    }
}
