import XCTest
@testable import VocatecaCore

/// Watchlist (#5) Core — `KeywordWatch.evaluate(text:terms:)` matcher.
final class WatchlistTermsTests: XCTestCase {

    private func term(_ t: String, id: String = "t", isRegex: Bool = false, enabled: Bool = true) -> WatchTerm {
        WatchTerm(id: id, term: t, isRegex: isRegex, enabled: enabled)
    }

    func testPlainTermIsWholeWordCaseInsensitive() {
        let text = "The AI chair discussed ai policy. Chairman spoke."
        let hits = KeywordWatch.evaluate(text: text, terms: [term("ai")])
        // Matches "AI" and "ai" but NOT "chair"/"Chairman".
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.termID == "t" })
    }

    func testRegexTerm() {
        let text = "Contact bob@example.com or alice@test.org today."
        let hits = KeywordWatch.evaluate(text: text, terms: [term("\\w+@\\w+\\.\\w+", isRegex: true)])
        XCTAssertEqual(hits.count, 2)
    }

    func testInvalidRegexIsSkippedNotCrashed() {
        let hits = KeywordWatch.evaluate(text: "anything", terms: [term("[unclosed(", isRegex: true)])
        XCTAssertTrue(hits.isEmpty)
    }

    func testDisabledTermIgnored() {
        let hits = KeywordWatch.evaluate(text: "swift is great", terms: [term("swift", enabled: false)])
        XCTAssertTrue(hits.isEmpty)
    }

    func testSnippetContainsMatchAndContext() {
        let text = "A long sentence mentioning Vocateca somewhere in the middle of it."
        let hits = KeywordWatch.evaluate(text: text, terms: [term("Vocateca")], snippetRadius: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("Vocateca"))
        XCTAssertGreaterThan(hits[0].offset, 0)
    }

    func testMultipleTermsIndependentHits() {
        let text = "swift and rust and swift again"
        let hits = KeywordWatch.evaluate(text: text, terms: [
            term("swift", id: "s"),
            term("rust", id: "r"),
        ])
        XCTAssertEqual(hits.filter { $0.termID == "s" }.count, 2)
        XCTAssertEqual(hits.filter { $0.termID == "r" }.count, 1)
    }

    func testEmptyTextNoHits() {
        XCTAssertTrue(KeywordWatch.evaluate(text: "", terms: [term("x")]).isEmpty)
    }
}
