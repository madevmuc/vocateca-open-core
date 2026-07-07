import XCTest
@testable import VocatecaCore

// MARK: - ShowsMerge unit tests

/// Verifies the pure merge logic in ``ShowsMerge`` without touching the UI or
/// the real DB.  Every test exercises one merge rule from the spec.
final class ShowsMergeTests: XCTestCase {

    // MARK: - Helpers

    private func makeShow(slug: String, source: String = "podcast") -> Show {
        Show(slug: slug, title: slug.capitalized, rss: "https://rss.example/\(slug)", source: source)
    }

    // MARK: - Test 1: Watchlist-only shows (no DB counts) → all appear with 0 counts

    func testWatchlistOnlyShowsGetZeroCounts() {
        let shows = [makeShow(slug: "alpha"), makeShow(slug: "beta")]
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: [:])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].show.slug, "alpha")
        XCTAssertEqual(result[0].doneCount, 0)
        XCTAssertEqual(result[0].pendingCount, 0)
        XCTAssertEqual(result[1].show.slug, "beta")
        XCTAssertEqual(result[1].doneCount, 0)
        XCTAssertEqual(result[1].pendingCount, 0)
    }

    // MARK: - Test 2: DB counts merged onto matching watchlist shows

    func testDBCountsMergedOntoWatchlistShows() {
        let shows = [makeShow(slug: "alpha"), makeShow(slug: "beta")]
        let counts: [String: (done: Int, pending: Int)] = [
            "alpha": (done: 42, pending: 3),
            "beta":  (done: 10, pending: 0),
        ]
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: counts)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].show.slug, "alpha")
        XCTAssertEqual(result[0].doneCount, 42)
        XCTAssertEqual(result[0].pendingCount, 3)
        XCTAssertEqual(result[1].show.slug, "beta")
        XCTAssertEqual(result[1].doneCount, 10)
        XCTAssertEqual(result[1].pendingCount, 0)
    }

    // MARK: - Test 3: DB-only slug appended at end as synthetic show

    func testDBOnlySlugAppendedAtEnd() {
        let shows = [makeShow(slug: "alpha")]
        // "ghost" is in the DB but not in the watchlist.
        let counts: [String: (done: Int, pending: Int)] = [
            "alpha": (done: 5, pending: 1),
            "ghost": (done: 99, pending: 7),
        ]
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: counts)

        XCTAssertEqual(result.count, 2)
        // Watchlist show first.
        XCTAssertEqual(result[0].show.slug, "alpha")
        XCTAssertEqual(result[0].doneCount, 5)
        // DB-only show appended.
        XCTAssertEqual(result[1].show.slug, "ghost")
        XCTAssertEqual(result[1].doneCount, 99)
        XCTAssertEqual(result[1].pendingCount, 7)
        // Synthetic show uses slug as title.
        XCTAssertEqual(result[1].show.title, "ghost")
    }

    // MARK: - Test 4: De-dupe — watchlist entry wins over DB-only for same slug

    func testDedupeWatchlistEntryWins() {
        let shows = [makeShow(slug: "shared")]
        // "shared" is in both watchlist and countsBySlug — watchlist entry must win.
        let counts: [String: (done: Int, pending: Int)] = [
            "shared": (done: 20, pending: 2),
        ]
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: counts)

        // Only one entry for "shared" — not duplicated.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].show.slug, "shared")
        // Counts from countsBySlug are applied.
        XCTAssertEqual(result[0].doneCount, 20)
        XCTAssertEqual(result[0].pendingCount, 2)
        // The show's title comes from the watchlist Show, not from the slug.
        XCTAssertEqual(result[0].show.title, "Shared")   // makeShow uses .capitalized
    }

    // MARK: - Test 5: Watchlist order is preserved; DB-only shows sorted alphabetically

    func testOrderingWatchlistFirstThenDBAlphabetically() {
        let shows = [
            makeShow(slug: "zeta"),
            makeShow(slug: "alpha"),
        ]
        // "bravo" and "charlie" are DB-only — should be appended alphabetically.
        let counts: [String: (done: Int, pending: Int)] = [
            "zeta":    (done: 1, pending: 0),
            "alpha":   (done: 2, pending: 0),
            "charlie": (done: 3, pending: 0),
            "bravo":   (done: 4, pending: 0),
        ]
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: counts)

        XCTAssertEqual(result.count, 4)
        // Watchlist order first.
        XCTAssertEqual(result[0].show.slug, "zeta")
        XCTAssertEqual(result[1].show.slug, "alpha")
        // DB-only sorted alpha.
        XCTAssertEqual(result[2].show.slug, "bravo")
        XCTAssertEqual(result[3].show.slug, "charlie")
    }

    // MARK: - Test 6: Empty watchlist, DB-only slugs only

    func testEmptyWatchlistDBOnlySlugsSorted() {
        let counts: [String: (done: Int, pending: Int)] = [
            "zzz": (done: 1, pending: 0),
            "aaa": (done: 2, pending: 0),
        ]
        let result = ShowsMerge.merge(watchlistShows: [], countsBySlug: counts)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].show.slug, "aaa")
        XCTAssertEqual(result[1].show.slug, "zzz")
    }

    // MARK: - Test 7: Both empty — result is empty

    func testBothEmptyReturnsEmpty() {
        let result = ShowsMerge.merge(watchlistShows: [], countsBySlug: [:])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Test 8: Duplicate slugs in watchlist — only first entry retained

    func testDuplicateWatchlistSlugsDeduped() {
        let shows = [makeShow(slug: "dup"), makeShow(slug: "dup")]
        let counts: [String: (done: Int, pending: Int)] = ["dup": (done: 5, pending: 1)]
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: counts)

        // Only the first watchlist occurrence should appear.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].show.slug, "dup")
    }

    // MARK: - Test 9: Freshly-subscribed show in watchlist but absent from countsBySlug → 0 counts

    func testFreshlySubscribedShowGetsZeroCounts() {
        let shows = [makeShow(slug: "brand-new")]
        // "brand-new" has no DB rows yet.
        let result = ShowsMerge.merge(watchlistShows: shows, countsBySlug: [:])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].show.slug, "brand-new")
        XCTAssertEqual(result[0].doneCount, 0)
        XCTAssertEqual(result[0].pendingCount, 0)
        // Show should use the real watchlist Show (title from makeShow = "Brand-New").
        XCTAssertEqual(result[0].show.title, "Brand-New")
    }
}
