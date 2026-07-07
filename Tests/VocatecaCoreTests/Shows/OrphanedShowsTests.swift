import XCTest
@testable import VocatecaCore

// MARK: - OrphanedShowsTests

/// Verifies the pure orphaned-slug enumeration logic in ``OrphanedShows``
/// without touching the UI or a real DB — mirrors ``ShowsMergeTests``.
final class OrphanedShowsTests: XCTestCase {

    private func makeShow(slug: String, source: String = "podcast") -> Show {
        Show(slug: slug, title: slug.capitalized, rss: "https://rss.example/\(slug)", source: source)
    }

    // MARK: - DB-only slugs are surfaced

    func testDBOnlySlugIsSurfacedAsOrphan() {
        let watchlist = [makeShow(slug: "alpha")]
        let dbSlugs = ["alpha", "orphan-show"]
        let counts: [String: (done: Int, total: Int)] = [
            "alpha": (done: 3, total: 5),
            "orphan-show": (done: 40, total: 42),
        ]

        let result = OrphanedShows.enumerate(dbShowSlugs: dbSlugs, watchlistShows: watchlist, countsBySlug: counts)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].slug, "orphan-show")
        XCTAssertEqual(result[0].episodeCount, 42)
        XCTAssertEqual(result[0].doneCount, 40)
    }

    // MARK: - Watchlist slugs are excluded even when present in the DB

    func testWatchlistSlugIsExcluded() {
        let watchlist = [makeShow(slug: "alpha"), makeShow(slug: "beta")]
        let dbSlugs = ["alpha", "beta"]
        let counts: [String: (done: Int, total: Int)] = [
            "alpha": (done: 1, total: 1),
            "beta": (done: 1, total: 1),
        ]

        let result = OrphanedShows.enumerate(dbShowSlugs: dbSlugs, watchlistShows: watchlist, countsBySlug: counts)

        XCTAssertTrue(result.isEmpty, "every DB slug has a matching watchlist entry — nothing is orphaned")
    }

    // MARK: - The local-ingest pseudo-show bucket is always excluded

    func testLocalFilesBucketSlugIsExcluded() {
        // Simulates the exact data-loss scenario: watchlist.yaml was lost, so
        // NO shows (including the local bucket) have a watchlist entry. Even
        // then, the local-files bucket must never be offered as "reconnect a
        // feed" — it isn't a feed-backed show.
        let dbSlugs = ["orphan-show", LocalIngestService.localFilesBucketSlug]
        let counts: [String: (done: Int, total: Int)] = [
            "orphan-show": (done: 2, total: 4),
            LocalIngestService.localFilesBucketSlug: (done: 9, total: 9),
        ]

        let result = OrphanedShows.enumerate(dbShowSlugs: dbSlugs, watchlistShows: [], countsBySlug: counts)

        XCTAssertEqual(result.map(\.slug), ["orphan-show"],
                        "the local-files bucket slug must never be enumerated as an orphan")
    }

    // MARK: - Sorted alphabetically, deterministic order

    func testResultsAreSortedAlphabetically() {
        let dbSlugs = ["zeta-show", "alpha-show", "mu-show"]
        let counts: [String: (done: Int, total: Int)] = [
            "zeta-show": (done: 0, total: 1),
            "alpha-show": (done: 0, total: 1),
            "mu-show": (done: 0, total: 1),
        ]

        let result = OrphanedShows.enumerate(dbShowSlugs: dbSlugs, watchlistShows: [], countsBySlug: counts)

        XCTAssertEqual(result.map(\.slug), ["alpha-show", "mu-show", "zeta-show"])
    }

    // MARK: - Missing counts default to zero (never crashes)

    func testMissingCountsDefaultToZero() {
        let result = OrphanedShows.enumerate(dbShowSlugs: ["mystery"], watchlistShows: [], countsBySlug: [:])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].episodeCount, 0)
        XCTAssertEqual(result[0].doneCount, 0)
    }

    // MARK: - Empty DB slugs → empty result

    func testEmptyDBSlugsReturnsEmpty() {
        let result = OrphanedShows.enumerate(dbShowSlugs: [], watchlistShows: [makeShow(slug: "alpha")], countsBySlug: [:])
        XCTAssertTrue(result.isEmpty)
    }
}
