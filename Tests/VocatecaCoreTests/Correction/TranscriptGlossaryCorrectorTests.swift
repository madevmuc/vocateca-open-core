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

    // MARK: - 2026-07-16 production incident: short function words

    func testRealIncidentSoIsNotCorrectedToCEO() {
        // Real production glossary: show title "The Diary Of A CEO" yields the
        // glossary term "CEO". "so" and "CEO" both reduce to the single-symbol
        // Double-Metaphone code "S" and were within the (pre-fix) length-scaled
        // Levenshtein budget, so every "so"/"So" in the transcript was rewritten
        // to "CEO" — e.g. "And so I'm on a mission" → "And CEO I'm on a mission".
        let g = EpisodeGlossary.build(title: "The Diary Of A CEO", description: nil,
                                      showName: "x", author: nil, whisperPrompt: "")
        XCTAssertTrue(g.terms.map(\.text).contains("CEO"), "test glossary must actually contain CEO")
        let segs = [TranscriptionSegment(start: 0, end: 2,
                                          text: "And so I'm on a mission. So it goes.",
                                          noSpeechProb: nil, avgLogprob: nil)]
        var logs: [(String, String)] = []
        let out = TranscriptGlossaryCorrector(level: .conservative)
            .correct(segs, glossary: g, log: { logs.append(($0, $1)) })
        XCTAssertEqual(out[0].text, "And so I'm on a mission. So it goes.")
        XCTAssertTrue(logs.isEmpty, "unexpected replacement(s): \(logs)")
    }

    func testRealIncidentGermanFunctionWordsAreNotCorrected() {
        // Real production glossary entries "Ache" (surname) and "Anne" (first
        // name) phonetically collided with common German function words:
        // 'ich'/'auch' → 'Ache' (273x / 127x in the live transcript), 'eine'/'an'
        // → 'Anne' (84x / 40x), 'uns' → 'ins' (30x). Every one of these is a
        // short, extremely common word that must never be treated as a proper
        // noun regardless of how well it phonetically collides with a glossary
        // entry — they're all in EpisodeGlossary.stopwords.
        let g = EpisodeGlossary(terms: [
            GlossaryTerm(text: "Ache", source: "author"),
            GlossaryTerm(text: "Anne", source: "author"),
            GlossaryTerm(text: "ins", source: "prompt"),
        ])
        let segs = [TranscriptionSegment(
            start: 0, end: 2,
            text: "Ich habe auch eine Idee, und an das haben wir uns schon gewöhnt.",
            noSpeechProb: nil, avgLogprob: nil)]
        var logs: [(String, String)] = []
        let out = TranscriptGlossaryCorrector(level: .conservative)
            .correct(segs, glossary: g, log: { logs.append(($0, $1)) })
        XCTAssertEqual(out[0].text, segs[0].text)
        XCTAssertTrue(logs.isEmpty, "unexpected replacement(s): \(logs)")
    }

    func testShortTokenRequiresNearExactMatchNotJustPhoneticCollision() {
        // Structural guard (independent of the stop-word list): below
        // `minFuzzyTokenLength` (4), a token may only match within an edit
        // distance of 1, never the fuller length-scaled budget. "uns" (3 chars)
        // and "ins" (glossary term, 3 chars) collide on the same phonetic code
        // and are only 1 edit apart, which is why the stop-word guard above is
        // what actually blocks that specific pair — but a token further than 1
        // edit away from a short candidate must be rejected purely on
        // structural grounds even if it isn't a known stop-word or common word.
        let g = EpisodeGlossary(terms: [GlossaryTerm(text: "Anne", source: "author")])
        // "an" (2 chars) is 2 edits from "Anne" — too far for the near-exact
        // short-token budget even though the codes collide (both "AN").
        let segs = [TranscriptionSegment(start: 0, end: 1, text: "wir gehen an",
                                          noSpeechProb: nil, avgLogprob: nil)]
        let out = TranscriptGlossaryCorrector(level: .conservative).correct(segs, glossary: g, log: { _, _ in })
        XCTAssertEqual(out[0].text, "wir gehen an")
    }

    func testShortTokenNearExactTypoStillCorrects() {
        // True positive: the near-exact (edit distance ≤ 1) path for short
        // tokens must still fire — a 3-letter name mis-transcribed by a single
        // letter is exactly the kind of real correction this feature exists
        // for, and the short-token guard must not neuter it.
        let g = EpisodeGlossary(terms: [GlossaryTerm(text: "Kim", source: "author")])
        let segs = [TranscriptionSegment(start: 0, end: 1, text: "das war Kym, glaube ich",
                                          noSpeechProb: nil, avgLogprob: nil)]
        var logs: [(String, String)] = []
        let out = TranscriptGlossaryCorrector(level: .conservative)
            .correct(segs, glossary: g, log: { logs.append(($0, $1)) })
        XCTAssertEqual(out[0].text, "das war Kim, glaube ich")
        XCTAssertTrue(logs.contains(where: { $0 == "Kym" && $1 == "Kim" }))
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
