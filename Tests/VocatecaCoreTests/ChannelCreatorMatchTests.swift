import XCTest
@testable import VocatecaCore

// MARK: - ChannelCreatorMatchTests

/// Pure unit tests for ``CreatorAggregator/matchingShows(forChannelName:in:)``
/// — the "link a YouTube channel to an existing library show" auto-merge
/// detection. No DB, no filesystem, no network.
final class ChannelCreatorMatchTests: XCTestCase {

    // MARK: - Helpers

    private func show(
        slug: String,
        title: String,
        source: String = "podcast",
        author: String? = nil,
        creator: String? = nil
    ) -> Show {
        Show(slug: slug, title: title, rss: "", source: source, author: author, creator: creator)
    }

    // MARK: - Exact name match → 1

    func testExactNameMatchIsUnambiguous() {
        let podcast = show(slug: "diary-podcast", title: "The Diary Of A CEO", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [podcast])

        XCTAssertEqual(matches.count, 1, "Exact-name podcast/channel pair must be an unambiguous match")
        XCTAssertEqual(matches.first?.slug, "diary-podcast")
    }

    func testExactAuthorMatchIsUnambiguous() {
        let podcast = show(slug: "diary-podcast", title: "The Diary Of A CEO Podcast",
                            source: "podcast", author: "The Diary Of A CEO")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [podcast])

        XCTAssertEqual(matches.count, 1, "Author field match must count the same as a title match")
    }

    // MARK: - Whole-word-prefix match (the real-world shape)

    /// The motivating case: podcast "The Diary Of A CEO with Steven
    /// Bartlett" (no author) vs. channel "The Diary Of A CEO". The channel
    /// key is a whole-word prefix of the podcast key, so they match even
    /// though exact-key-equality (what grouping uses) never would.
    func testWholeWordPrefixMatchIsUnambiguous() {
        let podcast = show(slug: "diary-podcast",
                           title: "The Diary Of A CEO with Steven Bartlett", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [podcast])

        XCTAssertEqual(matches.count, 1,
            "A channel name that is a whole-word prefix of the podcast title must match")
        XCTAssertEqual(matches.first?.slug, "diary-podcast")
    }

    /// Prefix works in the other direction too: a longer channel name whose
    /// leading words are an existing shorter show name.
    func testWholeWordPrefixMatchReversedDirection() {
        let podcast = show(slug: "diary-podcast", title: "The Diary Of A CEO", source: "podcast")

        let matches = CreatorAggregator.matchingShows(
            forChannelName: "The Diary Of A CEO with Steven Bartlett", in: [podcast])

        XCTAssertEqual(matches.count, 1,
            "A longer channel name whose leading words match a shorter show must still match")
    }

    /// A short prefix shared by several unrelated shows must stay AMBIGUOUS
    /// (count > 1) so it never auto-links: channel "The Daily" vs. shows
    /// "The Daily Show" + "The Daily Wire".
    func testSharedShortPrefixIsAmbiguous() {
        let a = show(slug: "daily-show", title: "The Daily Show", source: "podcast")
        let b = show(slug: "daily-wire", title: "The Daily Wire", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Daily", in: [a, b])

        XCTAssertEqual(matches.count, 2,
            "A short prefix shared by two unrelated shows must be ambiguous (must NOT auto-link)")
    }

    /// A partial LAST word is not a whole-word prefix: "The Dail" must not
    /// match "The Daily Show".
    func testPartialLastWordIsNotAPrefixMatch() {
        let podcast = show(slug: "daily-show", title: "The Daily Show", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Dail", in: [podcast])

        XCTAssertTrue(matches.isEmpty, "A partial final word must not count as a whole-word prefix")
    }

    // MARK: - Case / whitespace / diacritics differences still match

    func testCaseWhitespaceDiacriticsStillMatch() {
        let podcast = show(slug: "cafe-podcast", title: "  Café   Society  ", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "CAFE SOCIETY", in: [podcast])

        XCTAssertEqual(matches.count, 1,
            "Case/whitespace/diacritics differences must not prevent a match")
    }

    func testTrailingSourceSuffixIsStrippedBeforeMatching() {
        let podcast = show(slug: "diary-podcast", title: "The Diary Of A CEO Podcast", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [podcast])

        XCTAssertEqual(matches.count, 1,
            "A trailing 'Podcast' suffix on the existing show's title must be stripped before comparing")
    }

    // MARK: - Differently-named podcast → 0 matches

    func testDifferentlyNamedPodcastYieldsNoMatch() {
        let podcast = show(slug: "other-show", title: "Some Other Show", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [podcast])

        XCTAssertTrue(matches.isEmpty, "A differently-named show must not match")
    }

    func testEmptyChannelNameYieldsNoMatch() {
        let podcast = show(slug: "diary-podcast", title: "The Diary Of A CEO", source: "podcast")

        let matches = CreatorAggregator.matchingShows(forChannelName: "   ", in: [podcast])

        XCTAssertTrue(matches.isEmpty, "A blank channel name must never match anything")
    }

    // MARK: - Two same-named shows → 2 (ambiguous)

    func testTwoSameNamedShowsAreAmbiguous() {
        let a = show(slug: "diary-a", title: "The Diary Of A CEO", source: "podcast")
        let b = show(slug: "diary-b", title: "The Diary Of A CEO", source: "other")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [a, b])

        XCTAssertEqual(matches.count, 2, "Two shows with the same normalised key must both be returned (ambiguous)")
    }

    // MARK: - YouTube-source shows are excluded

    func testYouTubeSourceShowsAreExcluded() {
        let yt = show(slug: "youtube-abc123", title: "The Diary Of A CEO", source: "youtube")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [yt])

        XCTAssertTrue(matches.isEmpty,
            "A YouTube-source show (e.g. the very show being created) must never match itself")
    }

    func testYouTubeSourceIsCaseInsensitiveExclusion() {
        let yt = show(slug: "youtube-abc123", title: "The Diary Of A CEO", source: "YouTube")

        let matches = CreatorAggregator.matchingShows(forChannelName: "The Diary Of A CEO", in: [yt])

        XCTAssertTrue(matches.isEmpty, "Source exclusion must be case-insensitive")
    }
}
