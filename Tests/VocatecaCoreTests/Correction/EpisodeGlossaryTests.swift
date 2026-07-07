import XCTest
@testable import VocatecaCore

/// Tests for ``EpisodeGlossary`` proper-noun extraction and the bounded
/// ``StringDistance.levenshtein`` it relies on.
final class CorrectionEpisodeGlossaryTests: XCTestCase {

    func testExtractsProperNounsFromTitle() {
        let g = EpisodeGlossary.build(title: "Folge #193, Sascha Firtina, Co-Founder von gocomo",
                                      description: nil, showName: "What's Next, Agencies?",
                                      author: nil, whisperPrompt: "")
        let t = g.terms.map(\.text)
        XCTAssertTrue(t.contains("Firtina"))
        XCTAssertTrue(t.contains("gocomo"))        // lowercase brand kept (title token, not a common word)
        XCTAssertTrue(t.contains("Sascha Firtina")) // bigram
        XCTAssertFalse(t.contains("von"))           // stop-word dropped
        XCTAssertFalse(t.contains("Co"))            // < 3 chars dropped
    }

    func testWhisperPromptTermsIncludedVerbatim() {
        let g = EpisodeGlossary.build(title: "x", description: nil, showName: "y", author: nil,
                                      whisperPrompt: "DOAC, Flightstory")
        XCTAssertTrue(g.terms.map(\.text).contains("Flightstory"))
    }

    func testLevenshteinBounded() {
        XCTAssertEqual(StringDistance.levenshtein("Fertina", "Firtina", max: 3), 1)
        XCTAssertEqual(StringDistance.levenshtein("Berlin", "gocomo", max: 2), 3) // clamps at max+? — assert > max
    }
}
