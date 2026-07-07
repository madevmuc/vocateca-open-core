import XCTest
@testable import VocatecaCore

/// Acceptance tests for ``TranscriptGlossaryCorrector`` — the end-to-end
/// behaviour of the proper-noun correction feature over transcript segments.
final class CorrectionTranscriptGlossaryCorrectorTests: XCTestCase {

    func testCorrectsBrandAndName() {
        let g = EpisodeGlossary.build(title: "Sascha Firtina, Co-Founder von gocomo",
                                      description: nil, showName: "x", author: nil, whisperPrompt: "")
        let segs = [TranscriptionSegment(start: 0, end: 2, text: "arbeitet Gokumo. Gegründet von Sascha Fertina.", noSpeechProb: nil, avgLogprob: nil)]
        let out = TranscriptGlossaryCorrector(level: .conservative).correct(segs, glossary: g, log: {_,_ in})
        XCTAssertEqual(out[0].text, "arbeitet gocomo. Gegründet von Sascha Firtina.")
    }

    func testDoesNotOvercorrectCommonWord() {
        let g = EpisodeGlossary.build(title: "gocomo", description: nil, showName: "x", author: nil, whisperPrompt: "")
        let segs = [TranscriptionSegment(start: 0, end: 1, text: "wir kommen gleich", noSpeechProb: nil, avgLogprob: nil)]
        // "kommen" is phonetically near "gocomo" — must NOT be replaced (common word guard)
        let out = TranscriptGlossaryCorrector(level: .conservative).correct(segs, glossary: g, log: {_,_ in})
        XCTAssertEqual(out[0].text, "wir kommen gleich")
    }

    func testBigramPassDoesNotOvercorrectTwoCommonWords() {
        // "kommen" and "gleich" are both everyday German words in
        // EpisodeGlossary.commonWords. Neither is individually close enough to
        // trip the unigram guard's phonetic gate against a single-word glossary
        // term, but the adjacent PHRASE "kommen gleich" phonetically collides
        // (Double Metaphone) with, and is within Levenshtein budget of, the
        // two-word proper-noun glossary term below — so the bigram pass alone
        // must guard against rewriting two common words, mirroring the unigram
        // guard at line ~167.
        let g = EpisodeGlossary(terms: [GlossaryTerm(text: "Komen Gleich", source: "test")])
        let segs = [TranscriptionSegment(start: 0, end: 1, text: "wir kommen gleich zurück", noSpeechProb: nil, avgLogprob: nil)]
        var logs: [(String, String)] = []
        let out = TranscriptGlossaryCorrector(level: .conservative).correct(segs, glossary: g, log: { logs.append(($0, $1)) })
        XCTAssertEqual(out[0].text, "wir kommen gleich zurück")
        XCTAssertTrue(logs.isEmpty, "unexpected replacement(s): \(logs)")
    }

    func testOffIsNoOpAndLogsFire() {
        // .off returns input unchanged; conservative fires the log callback once per replacement.
        let g = EpisodeGlossary.build(title: "Sascha Firtina, Co-Founder von gocomo",
                                      description: nil, showName: "x", author: nil, whisperPrompt: "")
        let segs = [TranscriptionSegment(start: 0, end: 2, text: "arbeitet Gokumo. Gegründet von Sascha Fertina.", noSpeechProb: nil, avgLogprob: nil)]

        // .off — identity, no log calls.
        var offCalls: [(String, String)] = []
        let offOut = TranscriptGlossaryCorrector(level: .off).correct(segs, glossary: g, log: { offCalls.append(($0, $1)) })
        XCTAssertEqual(offOut, segs)
        XCTAssertTrue(offCalls.isEmpty)

        // .conservative — two replacements (Gokumo→gocomo, Fertina→Firtina), one log per replacement.
        var calls: [(String, String)] = []
        _ = TranscriptGlossaryCorrector(level: .conservative).correct(segs, glossary: g, log: { calls.append(($0, $1)) })
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.contains(where: { $0 == "Gokumo" && $1 == "gocomo" }))
        XCTAssertTrue(calls.contains(where: { $0 == "Fertina" && $1 == "Firtina" }))
    }
}
