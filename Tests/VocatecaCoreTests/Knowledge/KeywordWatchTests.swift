import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - KeywordWatchTests

/// Tests for ``KeywordWatch`` — pure matcher.
final class KeywordWatchTests: XCTestCase {

    // MARK: - Pure matcher: basic matching

    func testMatchesFindsKeyword() {
        let hits = KeywordWatch.matches(
            text: "Welcome to the Swift podcast",
            keywords: ["Swift"],
            wholeWord: false
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].keyword, "Swift")
        XCTAssertEqual(hits[0].count, 1)
    }

    func testMatchesCountsMultipleOccurrences() {
        let hits = KeywordWatch.matches(
            text: "Swift is great. I love Swift. Swift for life!",
            keywords: ["Swift"],
            wholeWord: false
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].count, 3, "Must count all 3 occurrences")
    }

    func testMatchesMultipleKeywords() {
        let hits = KeywordWatch.matches(
            text: "Today we discuss AI and also Machine Learning",
            keywords: ["AI", "Machine Learning", "Blockchain"],
            wholeWord: false
        )
        // "AI" and "Machine Learning" match; "Blockchain" does not.
        XCTAssertEqual(hits.count, 2)
        let keywords = hits.map(\.keyword)
        XCTAssertTrue(keywords.contains("AI"))
        XCTAssertTrue(keywords.contains("Machine Learning"))
        XCTAssertFalse(keywords.contains("Blockchain"))
    }

    func testMatchesEmptyTextReturnsEmpty() {
        let hits = KeywordWatch.matches(text: "", keywords: ["Swift"], wholeWord: false)
        XCTAssertTrue(hits.isEmpty)
    }

    func testMatchesEmptyKeywordsReturnsEmpty() {
        let hits = KeywordWatch.matches(text: "Some text here", keywords: [], wholeWord: false)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Pure matcher: case-insensitivity

    func testMatchesCaseInsensitiveQuery() {
        let hitsUpper = KeywordWatch.matches(text: "Swift is cool", keywords: ["SWIFT"], wholeWord: false)
        let hitsLower = KeywordWatch.matches(text: "Swift is cool", keywords: ["swift"], wholeWord: false)
        let hitsMixed = KeywordWatch.matches(text: "SWIFT IS COOL", keywords: ["Swift"], wholeWord: false)

        XCTAssertEqual(hitsUpper.count, 1, "Uppercase keyword must match lowercase text")
        XCTAssertEqual(hitsLower.count, 1, "Lowercase keyword must match mixed-case text")
        XCTAssertEqual(hitsMixed.count, 1, "Mixed-case keyword must match uppercase text")
    }

    // MARK: - Pure matcher: whole-word mode

    /// "rate" must NOT match "accurate" in whole-word mode.
    func testWholeWordDoesNotMatchSubstring() {
        let hits = KeywordWatch.matches(
            text: "I am very accurate in my estimates",
            keywords: ["rate"],
            wholeWord: true
        )
        // "accurate" contains "rate" but it's not a whole word.
        // "rate" does not appear standalone.
        XCTAssertTrue(hits.isEmpty, "Whole-word mode must not match 'rate' inside 'accurate'")
    }

    /// "rate" SHOULD match "rate" as a standalone word.
    func testWholeWordMatchesStandaloneWord() {
        let hits = KeywordWatch.matches(
            text: "The rate is high",
            keywords: ["rate"],
            wholeWord: true
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].count, 1)
    }

    /// "AI" should not match "PAID" in whole-word mode.
    func testWholeWordDoesNotMatchPartOfWord() {
        let hits = KeywordWatch.matches(
            text: "He was paid well",
            keywords: ["ai"],
            wholeWord: true
        )
        XCTAssertTrue(hits.isEmpty, "Whole-word 'ai' must not match inside 'paid'")
    }

    /// Whole-word: keyword at start of string.
    func testWholeWordMatchesAtStringStart() {
        let hits = KeywordWatch.matches(
            text: "Swift is a language",
            keywords: ["Swift"],
            wholeWord: true
        )
        XCTAssertEqual(hits.count, 1)
    }

    /// Whole-word: keyword at end of string.
    func testWholeWordMatchesAtStringEnd() {
        let hits = KeywordWatch.matches(
            text: "We use Swift",
            keywords: ["Swift"],
            wholeWord: true
        )
        XCTAssertEqual(hits.count, 1)
    }

    /// Whole-word mode is case-insensitive.
    func testWholeWordCaseInsensitive() {
        let hits = KeywordWatch.matches(
            text: "SWIFT is great",
            keywords: ["swift"],
            wholeWord: true
        )
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: - Pure matcher: zero-match keywords omitted from results

    func testNoMatchingKeywordsReturnEmpty() {
        let hits = KeywordWatch.matches(
            text: "Hello world",
            keywords: ["Haskell", "Erlang"],
            wholeWord: false
        )
        XCTAssertTrue(hits.isEmpty, "Non-matching keywords must not appear in result")
    }

    // MARK: - Pure matcher: ranges populated

    func testMatchesPopulatesRanges() {
        let text = "Swift and swift"
        let hits = KeywordWatch.matches(text: text, keywords: ["swift"], wholeWord: false)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].ranges.count, 2, "Must return a range for each occurrence")
    }

}
