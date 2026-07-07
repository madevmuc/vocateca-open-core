import XCTest
@testable import VocatecaCore

// MARK: - LibrarySearchTests

/// Tests for ``LibrarySearch`` ranking and search filtering.
///
/// All tests are pure and deterministic — no filesystem or network access.
final class LibrarySearchTests: XCTestCase {

    // MARK: - Helpers

    /// Makes a bare ``IndexedEpisode`` with no transcript file.
    private func makeEpisode(
        guid: String,
        title: String,
        showSlug: String
    ) -> IndexedEpisode {
        let ep = Episode(
            guid: guid,
            showSlug: showSlug,
            title: title,
            pubDate: "2026-01-01T00:00:00",
            mp3Url: "https://example.com/\(guid).mp3"
        )
        return IndexedEpisode(episode: ep, transcriptURL: nil)
    }

    // MARK: - Score: title weighting

    /// A title match must score higher than a body-only match for the same term.
    func testTitleMatchOutranksBodyOnlyMatch() {
        // "Swift" appears in the title of ep1 but only in body of ep2.
        let titleScore = LibrarySearch.score(
            query: "Swift",
            title: "Swift Programming Language",
            body: "Python is a great language",
            show: "tech-show"
        )
        let bodyScore = LibrarySearch.score(
            query: "Swift",
            title: "Programming Languages",
            body: "Swift is a great language for iOS",
            show: "tech-show"
        )
        XCTAssertGreaterThan(titleScore, bodyScore,
            "Title match (w=3) must outscore body-only match (w=1)")
    }

    /// A query that matches neither title nor body must score 0.
    func testNoMatchScoresZero() {
        let s = LibrarySearch.score(
            query: "Haskell",
            title: "Swift Programming",
            body: "We talk about Rust today",
            show: "tech-show"
        )
        XCTAssertEqual(s, 0.0, "No matching term must produce score 0")
    }

    /// A match in the show slug provides a bonus on top of title/body hits.
    func testShowBonusAddedWhenShowMatches() {
        let withBonus = LibrarySearch.score(
            query: "swift",
            title: "Swift Talk",
            body: "",
            show: "swift-cast"     // slug contains "swift" → bonus
        )
        let withoutBonus = LibrarySearch.score(
            query: "swift",
            title: "Swift Talk",
            body: "",
            show: "other-podcast"  // slug does NOT contain "swift"
        )
        XCTAssertGreaterThan(withBonus, withoutBonus,
            "Show-name match must add \(LibrarySearch.showBonus) bonus")
        XCTAssertEqual(withBonus - withoutBonus, LibrarySearch.showBonus, accuracy: 1e-9)
    }

    /// Multi-term query: partial match produces proportional score.
    func testMultiTermPartialMatchProportional() {
        // query has 2 terms; only 1 matches in title → tf_title = 0.5
        let s = LibrarySearch.score(
            query: "apple banana",
            title: "Apple Inc.",
            body: "",
            show: "fruit-show"
        )
        let expected = 0.5 * LibrarySearch.titleWeight  // 0.5 * 3.0 = 1.5
        XCTAssertEqual(s, expected, accuracy: 1e-9)
    }

    /// All terms matching in body gives tf_body = 1.0, so score = bodyWeight = 1.0.
    func testFullBodyMatchScoresBodyWeight() {
        let s = LibrarySearch.score(
            query: "apple banana",
            title: "Fruit Salad",
            body: "We talk about apple and banana today",
            show: "food-show"
        )
        let expected = 1.0 * LibrarySearch.bodyWeight  // 1.0 * 1.0 = 1.0
        XCTAssertEqual(s, expected, accuracy: 1e-9)
    }

    /// Title + body both fully match → maximum non-bonus score = titleWeight + bodyWeight.
    func testFullTitleAndBodyMatch() {
        let s = LibrarySearch.score(
            query: "apple banana",
            title: "Apple and Banana",
            body: "We discuss apple and banana",
            show: "food-show"
        )
        let expected = LibrarySearch.titleWeight + LibrarySearch.bodyWeight
        XCTAssertEqual(s, expected, accuracy: 1e-9)
    }

    // MARK: - Score: case-insensitivity

    func testScoreIsCaseInsensitive() {
        let s1 = LibrarySearch.score(query: "SWIFT", title: "Swift Tip",  body: "", show: "s")
        let s2 = LibrarySearch.score(query: "swift", title: "Swift Tip",  body: "", show: "s")
        let s3 = LibrarySearch.score(query: "Swift", title: "swift tip",  body: "", show: "s")
        XCTAssertEqual(s1, s2, accuracy: 1e-9, "Query case must not matter")
        XCTAssertEqual(s2, s3, accuracy: 1e-9, "Title case must not matter")
    }

    // MARK: - Empty query rule

    /// An empty query must return an empty result array.
    func testEmptyQueryReturnsEmpty() {
        let searcher = LibrarySearch()
        let episodes = [
            makeEpisode(guid: "g1", title: "Episode 1", showSlug: "show-a"),
            makeEpisode(guid: "g2", title: "Episode 2", showSlug: "show-b"),
        ]
        let results = searcher.search("", in: episodes)
        XCTAssertTrue(results.isEmpty, "Empty query must return empty result array")
    }

    /// Whitespace-only query must return empty.
    func testWhitespaceOnlyQueryReturnsEmpty() {
        let searcher = LibrarySearch()
        let episodes = [makeEpisode(guid: "g1", title: "Any Episode", showSlug: "show")]
        let results = searcher.search("   ", in: episodes)
        XCTAssertTrue(results.isEmpty, "Whitespace query must return empty result array")
    }

    // MARK: - Zero-score filtered

    /// Episodes with score 0 must not appear in results.
    func testZeroScoreEpisodesFiltered() {
        let searcher = LibrarySearch()
        let matching    = makeEpisode(guid: "g1", title: "Rust Programming", showSlug: "tech")
        let nonMatching = makeEpisode(guid: "g2", title: "Cooking With Oil", showSlug: "food")

        let results = searcher.search("Rust", in: [matching, nonMatching])

        XCTAssertEqual(results.count, 1, "Only the matching episode must appear")
        XCTAssertEqual(results[0].indexedEpisode.episode.guid, "g1")
    }

    // MARK: - Ordering

    /// Results must be sorted by score descending.
    func testResultsSortedByScoreDescending() {
        let searcher = LibrarySearch()

        // "swift" in title of ep1 (high score), only in show of ep2 (low score via bonus)
        let ep1 = makeEpisode(guid: "g1", title: "Swift Tips", showSlug: "coding")
        let ep2 = makeEpisode(guid: "g2", title: "Tips for Beginners", showSlug: "swift-cast")

        let results = searcher.search("swift", in: [ep1, ep2])
        XCTAssertEqual(results.count, 2)
        XCTAssertGreaterThan(results[0].score, results[1].score,
            "Higher-score result must come first")
        XCTAssertEqual(results[0].indexedEpisode.episode.guid, "g1",
            "Title match must outscore show-only match")
    }

    /// Golden-style ordering: crafted 3-episode set with known expected order.
    func testGoldenOrdering() {
        let searcher = LibrarySearch()

        // ep-a: "machine learning" in title AND show → highest
        let epA = makeEpisode(guid: "ga", title: "Machine Learning Deep Dive",
                              showSlug: "machine-learning-pod")
        // ep-b: "machine learning" in title only → middle
        let epB = makeEpisode(guid: "gb", title: "Machine Learning Basics",
                              showSlug: "tech-talks")
        // ep-c: "machine" in body only (no file → body = "") → this would
        //        be zero-score since no body; but let's use title match for
        //        just one term to distinguish from ep-b.
        let epC = makeEpisode(guid: "gc", title: "Learning to Code",
                              showSlug: "coding-show")

        let results = searcher.search("machine learning", in: [epC, epB, epA])

        // Expected order: epA > epB > epC
        XCTAssertGreaterThan(results[0].score, results[1].score)
        XCTAssertEqual(results[0].indexedEpisode.episode.guid, "ga",
            "ep-a must be first (title + show match)")
        XCTAssertEqual(results[1].indexedEpisode.episode.guid, "gb",
            "ep-b must be second (title match only)")
        // ep-c matches "learning" in title only → score = 0.5 * W_TITLE = 1.5
        // ep-b matches both terms in title → score = 1.0 * W_TITLE = 3.0
        XCTAssertEqual(results.count, 3, "All 3 episodes score > 0 (each matches at least 1 term)")
    }
}
