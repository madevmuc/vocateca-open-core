import XCTest
@testable import VocatecaCore

// MARK: - SubscriptionMatchTests

/// Coverage for ``SubscriptionMatch`` — the pure "is this discovery search
/// result already a subscribed show?" decision that powers the "Subscribed"
/// badge in the Add / search UIs (QA item 4). Network-free: no live watchlist,
/// no UI — just the feed-URL/slug matching logic.
final class SubscriptionMatchTests: XCTestCase {

    private func show(slug: String, rss: String) -> Show {
        Show(slug: slug, title: slug.capitalized, rss: rss, source: "podcast")
    }

    // MARK: - normalizeFeedURL

    func testNormalizeFoldsSchemeAndTrailingSlashAndCase() {
        XCTAssertEqual(
            SubscriptionMatch.normalizeFeedURL("HTTP://Feeds.Example.com/Show/"),
            "https://feeds.example.com/show"
        )
        XCTAssertEqual(SubscriptionMatch.normalizeFeedURL("  https://x.io/f  "), "https://x.io/f")
        XCTAssertEqual(SubscriptionMatch.normalizeFeedURL(""), "")
        XCTAssertEqual(SubscriptionMatch.normalizeFeedURL("   "), "")
    }

    // MARK: - Feed-URL match

    func testMatchesByFeedURLIgnoringSchemeAndTrailingSlash() {
        let idx = SubscriptionMatch.index(shows: [
            show(slug: "immocation", rss: "https://immocation.podigee.io/feed/mp3")
        ])
        // http vs https + a trailing slash still resolves to the same feed.
        XCTAssertTrue(SubscriptionMatch.isSubscribed(
            feedURL: "http://immocation.podigee.io/feed/mp3/",
            title: "Something Totally Different",
            in: idx
        ))
    }

    // MARK: - Slug match (feed URL differs)

    func testMatchesBySlugWhenFeedURLDiffers() {
        // Same title → same slug the subscribe path would create, even though the
        // feed URL moved to a different host.
        let idx = SubscriptionMatch.index(shows: [
            show(slug: "the-immocation-podcast-lerne-immobilien",
                 rss: "https://old-host.example/feed")
        ])
        XCTAssertTrue(SubscriptionMatch.isSubscribed(
            feedURL: "https://new-host.example/rss",
            title: "The immocation Podcast Lerne Immobilien",
            in: idx
        ))
    }

    // MARK: - Non-match

    func testDoesNotMatchAnUnknownResult() {
        let idx = SubscriptionMatch.index(shows: [
            show(slug: "immocation", rss: "https://immocation.podigee.io/feed/mp3")
        ])
        XCTAssertFalse(SubscriptionMatch.isSubscribed(
            feedURL: "https://brand-new.example/feed",
            title: "A Brand New Show",
            in: idx
        ))
    }

    func testEmptyIndexNeverMatches() {
        let idx = SubscriptionMatch.index(shows: [])
        XCTAssertFalse(SubscriptionMatch.isSubscribed(
            feedURL: "https://x.io/feed", title: "Whatever", in: idx))
    }

    // MARK: - Index building

    func testIndexSkipsEmptyFeedURLs() {
        // A show with no RSS (e.g. a DB-only / local show) contributes only its
        // slug, never an empty-string feed URL that would spuriously match.
        let idx = SubscriptionMatch.index(shows: [ show(slug: "local-files", rss: "") ])
        XCTAssertFalse(idx.feedURLs.contains(""))
        XCTAssertTrue(idx.slugs.contains("local-files"))
    }
}
