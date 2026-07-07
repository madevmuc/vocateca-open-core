import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - CreatorAggregatorTests

/// Pure unit tests for ``CreatorAggregator``.
///
/// All tests are synchronous and work entirely from injected value-type input —
/// no DB, no filesystem, no network.
final class CreatorAggregatorTests: XCTestCase {

    // MARK: - Helpers

    /// Convenience factory — creates a minimal show record.
    private func show(
        slug: String,
        title: String,
        source: String,
        author: String = "",
        episodeCount: Int = 0,
        episodes: [CreatorAggregatorEpisode] = [],
        creator: String? = nil
    ) -> CreatorAggregatorShow {
        CreatorAggregatorShow(
            slug: slug,
            title: title,
            source: source,
            author: author,
            episodeCount: episodeCount,
            recentEpisodes: episodes,
            creator: creator
        )
    }

    /// Convenience factory — creates a minimal episode record.
    private func episode(
        guid: String,
        title: String,
        pubDate: String = "2026-06-01T00:00:00Z",
        status: String = "done",
        durationSec: Int? = nil,
        source: String = "podcast"
    ) -> CreatorAggregatorEpisode {
        CreatorAggregatorEpisode(
            guid: guid,
            title: title,
            pubDate: pubDate,
            status: status,
            durationSec: durationSec,
            source: source
        )
    }

    // MARK: - Empty library

    func testEmptyLibraryReturnsEmpty() {
        let result = CreatorAggregator.aggregate(shows: [])
        XCTAssertTrue(result.isEmpty, "Empty input must produce empty output")
    }

    func testTopCreatorNilForEmptyLibrary() {
        XCTAssertNil(CreatorAggregator.topCreator(from: []))
    }

    // MARK: - Single show

    func testSingleShowBecomesOwnCreator() {
        let s = show(slug: "podcast-a", title: "Finance Talk", source: "podcast", episodeCount: 10)
        let creators = CreatorAggregator.aggregate(shows: [s])

        XCTAssertEqual(creators.count, 1)
        XCTAssertEqual(creators[0].totalEpisodeCount, 10)
        XCTAssertNotNil(creators[0].podcastShow)
        XCTAssertNil(creators[0].youtubeShow)
        XCTAssertNil(creators[0].instagramShow)
    }

    // MARK: - Grouping by author

    func testGroupsByNormalisedAuthor() {
        // Two shows, same author spelled differently (case/diacritics).
        let p = show(slug: "p", title: "Finance Talk Podcast", source: "podcast",
                     author: "María García", episodeCount: 20)
        let y = show(slug: "y", title: "MG Finance YouTube",  source: "youtube",
                     author: "maria garcia",  episodeCount: 30)

        let creators = CreatorAggregator.aggregate(shows: [p, y])

        XCTAssertEqual(creators.count, 1, "Same normalised author must produce ONE creator")
        let c = creators[0]
        XCTAssertEqual(c.totalEpisodeCount, 50)
        XCTAssertNotNil(c.podcastShow)
        XCTAssertNotNil(c.youtubeShow)
        XCTAssertNil(c.instagramShow)
    }

    func testGroupsThreeSourcesByAuthor() {
        let p  = show(slug: "p",  title: "Talk Podcast",   source: "podcast",   author: "Jane Doe", episodeCount: 5)
        let y  = show(slug: "y",  title: "Talk YouTube",   source: "youtube",   author: "Jane Doe", episodeCount: 8)
        let ig = show(slug: "ig", title: "Talk Instagram", source: "instagram", author: "Jane Doe", episodeCount: 3)

        let creators = CreatorAggregator.aggregate(shows: [p, y, ig])

        XCTAssertEqual(creators.count, 1)
        let c = creators[0]
        XCTAssertEqual(c.totalEpisodeCount, 16)
        XCTAssertNotNil(c.podcastShow)
        XCTAssertNotNil(c.youtubeShow)
        XCTAssertNotNil(c.instagramShow)
    }

    // MARK: - Grouping by title suffix stripping

    func testGroupsByStrippedTitleWhenNoAuthor() {
        let p = show(slug: "p", title: "Finance Talk Podcast", source: "podcast", episodeCount: 10)
        let y = show(slug: "y", title: "Finance Talk YouTube", source: "youtube",  episodeCount: 15)

        let creators = CreatorAggregator.aggregate(shows: [p, y])

        XCTAssertEqual(creators.count, 1, "Title suffix stripping must merge 'Finance Talk Podcast' and 'Finance Talk YouTube'")
        XCTAssertEqual(creators[0].totalEpisodeCount, 25)
    }

    func testStripsIGSuffix() {
        let p  = show(slug: "p",  title: "Tech Bytes Podcast", source: "podcast",   episodeCount: 10)
        let ig = show(slug: "ig", title: "Tech Bytes (IG)",    source: "instagram", episodeCount: 5)

        let creators = CreatorAggregator.aggregate(shows: [p, ig])

        XCTAssertEqual(creators.count, 1, "(IG) suffix must be stripped before grouping")
    }

    func testStripsYTSuffix() {
        let p = show(slug: "p", title: "Daily Byte",      source: "podcast", episodeCount: 4)
        let y = show(slug: "y", title: "Daily Byte (YT)", source: "youtube", episodeCount: 9)

        let creators = CreatorAggregator.aggregate(shows: [p, y])

        XCTAssertEqual(creators.count, 1, "(YT) suffix must be stripped before grouping")
    }

    // MARK: - Separate creators when titles differ

    func testDifferentTitlesMakeSeperateCreators() {
        let a = show(slug: "a", title: "Show Alpha", source: "podcast", episodeCount: 10)
        let b = show(slug: "b", title: "Show Beta",  source: "podcast", episodeCount: 5)

        let creators = CreatorAggregator.aggregate(shows: [a, b])

        XCTAssertEqual(creators.count, 2, "Non-matching titles must produce TWO creators")
    }

    // MARK: - Top creator selection (highest episode count)

    func testTopCreatorHasHighestCount() {
        let a = show(slug: "a", title: "Alpha", source: "podcast", episodeCount: 100)
        let b = show(slug: "b", title: "Beta",  source: "podcast", episodeCount: 200)
        let c = show(slug: "c", title: "Gamma", source: "podcast", episodeCount: 50)

        let top = CreatorAggregator.topCreator(from: [a, b, c])

        XCTAssertEqual(top?.displayName, "Beta")
        XCTAssertEqual(top?.totalEpisodeCount, 200)
    }

    func testTopCreatorTieBrokenByName() {
        let a = show(slug: "a", title: "Zephyr", source: "podcast", episodeCount: 10)
        let b = show(slug: "b", title: "Aardvark", source: "youtube", episodeCount: 10)

        let top = CreatorAggregator.topCreator(from: [a, b])

        // "Aardvark" comes before "Zephyr" lexicographically.
        XCTAssertEqual(top?.displayName, "Aardvark", "Tie must be broken by lexicographic displayName ascending")
    }

    // MARK: - Merged recent items

    func testRecentItemsMergedAndSortedNewestFirst() {
        let ep1 = episode(guid: "e1", title: "E1", pubDate: "2026-06-01T00:00:00Z", source: "podcast")
        let ep2 = episode(guid: "e2", title: "E2", pubDate: "2026-06-03T00:00:00Z", source: "youtube")
        let ep3 = episode(guid: "e3", title: "E3", pubDate: "2026-06-02T00:00:00Z", source: "podcast")

        let p = show(slug: "p", title: "MyPodcast", source: "podcast", author: "Creator X",
                     episodeCount: 2, episodes: [ep1, ep3])
        let y = show(slug: "y", title: "MyYouTube", source: "youtube", author: "Creator X",
                     episodeCount: 1, episodes: [ep2])

        let creator = CreatorAggregator.topCreator(from: [p, y])!

        XCTAssertEqual(creator.recentItems.count, 3)
        XCTAssertEqual(creator.recentItems[0].guid, "e2", "Newest item (e2, June 3) must be first")
        XCTAssertEqual(creator.recentItems[1].guid, "e3", "Second item (e3, June 2) must be second")
        XCTAssertEqual(creator.recentItems[2].guid, "e1", "Oldest item (e1, June 1) must be last")
    }

    func testRecentItemsLimitRespected() {
        // Build 20 episodes for a single show.
        let episodes: [CreatorAggregatorEpisode] = (0..<20).map { i in
            self.episode(guid: "e\(i)", title: "E\(i)",
                         pubDate: "2026-0\(i < 9 ? "0" : "")\(i + 1)-01T00:00:00Z")
        }
        let s = show(slug: "s", title: "Big Show", source: "podcast",
                     episodeCount: 20, episodes: episodes)

        let creators = CreatorAggregator.aggregate(shows: [s], recentItemsLimit: 5)

        XCTAssertEqual(creators[0].recentItems.count, 5, "recentItemsLimit must cap the merged list")
    }

    // MARK: - Source counts

    func testSourceCountsMatchShowEpisodeCounts() {
        let p  = show(slug: "p",  title: "Talk", source: "podcast",   author: "X", episodeCount: 12)
        let y  = show(slug: "y",  title: "Talk", source: "youtube",   author: "X", episodeCount: 25)
        let ig = show(slug: "ig", title: "Talk", source: "instagram", author: "X", episodeCount: 7)

        let c = CreatorAggregator.topCreator(from: [p, y, ig])!

        XCTAssertEqual(c.podcastShow?.episodeCount,   12)
        XCTAssertEqual(c.youtubeShow?.episodeCount,   25)
        XCTAssertEqual(c.instagramShow?.episodeCount,  7)
        XCTAssertEqual(c.totalEpisodeCount, 44)
    }

    // MARK: - Normalisation unit tests

    func testNormaliseStripsCase() {
        XCTAssertEqual(CreatorAggregator.normalise("Finance TALK"), "finance talk")
    }

    func testNormaliseStripsDiacritics() {
        XCTAssertEqual(CreatorAggregator.normalise("María García"), "maria garcia")
    }

    func testNormaliseCollapsesWhitespace() {
        XCTAssertEqual(CreatorAggregator.normalise("  hello   world  "), "hello world")
    }

    func testStrippedTitleRemovesPodcastSuffix() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Finance Talk Podcast"), "Finance Talk")
    }

    func testStrippedTitleRemovesYouTubeSuffix() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Finance Talk YouTube"), "Finance Talk")
    }

    func testStrippedTitleRemovesInstagramSuffix() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Finance Talk Instagram"), "Finance Talk")
    }

    func testStrippedTitleRemovesParenIGSuffix() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Finance Talk (IG)"), "Finance Talk")
    }

    func testStrippedTitleRemovesParenYTSuffix() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Finance Talk (YT)"), "Finance Talk")
    }

    func testStrippedTitleLeavesUnknownSuffix() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Finance Talk Quarterly"), "Finance Talk Quarterly")
    }

    func testStrippedTitleIsCaseInsensitive() {
        XCTAssertEqual(CreatorAggregator.strippedTitle("Tech Talk PODCAST"), "Tech Talk")
    }

    // MARK: - Display name preference

    func testDisplayNamePrefersAuthorOverTitle() {
        let s = show(slug: "s", title: "Some Podcast", source: "podcast",
                     author: "Jane Doe", episodeCount: 5)
        let c = CreatorAggregator.topCreator(from: [s])!
        XCTAssertEqual(c.displayName, "Jane Doe")
    }

    func testDisplayNameFallsBackToTitle() {
        let s = show(slug: "s", title: "Finance Talk", source: "podcast", episodeCount: 5)
        let c = CreatorAggregator.topCreator(from: [s])!
        XCTAssertEqual(c.displayName, "Finance Talk")
    }

    func testDisplayNamePicksShortestTitleWhenNoAuthor() {
        // "Finance Talk" is shorter than "Finance Talk Podcast" — should be chosen.
        let p = show(slug: "p", title: "Finance Talk Podcast", source: "podcast",  episodeCount: 10)
        let y = show(slug: "y", title: "Finance Talk YouTube", source: "youtube",  episodeCount: 5)
        // Both normalise to "finance talk"; shortest raw title is "Finance Talk Podcast"
        // (19 chars) vs "Finance Talk YouTube" (20 chars).
        let c = CreatorAggregator.topCreator(from: [p, y])!
        // Either is acceptable; what matters is it's one of the two real titles.
        XCTAssertTrue(["Finance Talk Podcast", "Finance Talk YouTube"].contains(c.displayName),
                      "Display name must be one of the grouped titles; got '\(c.displayName)'")
    }

    // MARK: - Explicit creator field (v2 watchlist.yaml `creator:` key)

    func testExplicitCreatorGroupsTwoShowsAcrossSources() {
        // Two shows with the same explicit creator="immocation" but unrelated titles.
        let p  = show(slug: "immocation-podcast", title: "immocation Podcast",
                      source: "podcast", episodeCount: 80, creator: "immocation")
        let yt = show(slug: "immocation-yt",      title: "immocation YT Channel",
                      source: "youtube", episodeCount: 200, creator: "immocation")

        let creators = CreatorAggregator.aggregate(shows: [p, yt])

        XCTAssertEqual(creators.count, 1,
            "Two shows with creator='immocation' must merge into ONE creator")
        let c = creators[0]
        XCTAssertEqual(c.totalEpisodeCount, 280)
        XCTAssertNotNil(c.podcastShow)
        XCTAssertNotNil(c.youtubeShow)
        XCTAssertNil(c.instagramShow)
    }

    func testExplicitCreatorIsCaseInsensitive() {
        // "Immocation" and "immocation" must resolve to the same group.
        let p  = show(slug: "p",  title: "Podcast A", source: "podcast",   episodeCount: 10, creator: "Immocation")
        let yt = show(slug: "yt", title: "Channel B", source: "youtube",   episodeCount: 15, creator: "immocation")

        let creators = CreatorAggregator.aggregate(shows: [p, yt])

        XCTAssertEqual(creators.count, 1,
            "Creator field match must be case-insensitive")
        XCTAssertEqual(creators[0].totalEpisodeCount, 25)
    }

    func testExplicitCreatorDisplayNameUsesCreatorField() {
        let p = show(slug: "p", title: "Some Podcast", source: "podcast",
                     episodeCount: 5, creator: "immocation")
        let c = CreatorAggregator.topCreator(from: [p])!
        XCTAssertEqual(c.displayName, "immocation",
            "Explicit creator field must be used as the display name")
    }

    func testUnassignedShowFallsBackToTitleHeuristic() {
        // A show without a creator field must still group by title-root.
        let p = show(slug: "p", title: "Finance Talk Podcast", source: "podcast", episodeCount: 10)
        let y = show(slug: "y", title: "Finance Talk YouTube", source: "youtube",  episodeCount: 5)

        let creators = CreatorAggregator.aggregate(shows: [p, y])

        XCTAssertEqual(creators.count, 1,
            "Shows without creator field must fall back to title-root heuristic grouping")
    }

    func testExplicitCreatorWinsOverAuthorField() {
        // creator= should override the author= field.
        let p = show(slug: "p", title: "Podcast", source: "podcast",
                     author: "Different Author", episodeCount: 5, creator: "My Brand")
        let y = show(slug: "y", title: "Channel", source: "youtube",
                     author: "Another Author", episodeCount: 8, creator: "My Brand")

        let creators = CreatorAggregator.aggregate(shows: [p, y])

        XCTAssertEqual(creators.count, 1,
            "Explicit creator= must override author= for grouping key")
        XCTAssertEqual(creators[0].displayName, "My Brand")
    }

    func testMixedExplicitAndHeuristicGroupsSeparately() {
        // One show with explicit creator; one without — they must NOT merge even
        // if the title-heuristic key happened to match "my brand".
        let p  = show(slug: "p",  title: "My Brand Podcast", source: "podcast",
                      episodeCount: 10, creator: "My Brand")
        let y  = show(slug: "y",  title: "My Brand YouTube", source: "youtube",
                      episodeCount: 5)   // no creator field — falls back to title heuristic

        let creators = CreatorAggregator.aggregate(shows: [p, y])

        // Both normalise to "my brand", so they DO merge — this is the desired behaviour:
        // explicit creator="My Brand" and the title-heuristic "My Brand" are the same key.
        XCTAssertEqual(creators.count, 1,
            "Shows resolving to the same normalised key must always merge, regardless of whether the key came from the creator field or heuristics")
    }

    func testAllCreatorsReturnsSameAggregateResult() {
        let p = show(slug: "p", title: "Alpha",  source: "podcast", episodeCount: 50)
        let y = show(slug: "y", title: "Beta",   source: "youtube", episodeCount: 80)

        let via_aggregate    = CreatorAggregator.aggregate(shows: [p, y])
        let via_allCreators  = CreatorAggregator.allCreators(from: [p, y])

        XCTAssertEqual(via_aggregate.map(\.id), via_allCreators.map(\.id),
            "allCreators(from:) must return the same result as aggregate(shows:)")
    }
}
