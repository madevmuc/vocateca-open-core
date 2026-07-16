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
        // Matches "AI" and "ai" but NOT "chair"/"Chairman" — "ai" never starts
        // a word inside either (no boundary before the "ai" substring in
        // "ch[ai]r" or "Ch[ai]rman").
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.termID == "t" })
    }

    /// 2026-07-16 fix: a plain term is a word-boundary PREFIX match (not
    /// both-sides whole-word), so it catches a term at the start of a longer
    /// compound word — the common case in German ("Energiewende",
    /// "Energien"), which the previous `\bTERM\b` silently missed even
    /// though the exact same text was findable via the Library's FTS5
    /// prefix search (`"energie"*`). This is the fix for the "adding
    /// 'Energie' only found 4 hits in a large German library" undercount.
    func testPlainTermMatchesGermanCompoundPrefix() {
        let text = """
            Die Energiewende ist teuer. Erneuerbare Energien sind wichtig.
            Der Energieausweis kostet Geld. Manche sagen energieeffizientere \
            Häuser lohnen sich.
            """
        let hits = KeywordWatch.evaluate(text: text, terms: [term("Energie")])
        // Energiewende, Energien, Energieausweis, energieeffizientere — 4 hits.
        XCTAssertEqual(hits.count, 4)
    }

    /// A term that appears only as a SUFFIX of a compound ("Primärenergie")
    /// still does not match — a prefix match requires a boundary immediately
    /// BEFORE the term, matching FTS5 prefix-token semantics exactly (the
    /// Library search for "energie*" wouldn't match "primärenergie" either,
    /// since that token starts with "primär", not "energie").
    func testPlainTermDoesNotMatchCompoundSuffix() {
        let hits = KeywordWatch.evaluate(text: "Der Primärenergiefaktor zählt.", terms: [term("Energie")])
        XCTAssertTrue(hits.isEmpty)
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
