import Foundation

/// Rewrites proper nouns in transcript segments to their metadata-known
/// spelling, engine-agnostically, after ASR and before the writer.
///
/// The matcher is deliberately conservative: a word (or adjacent bigram) is
/// replaced by a glossary term only when it shares the term's **primary
/// Double-Metaphone code** *and* lies within a length-scaled Levenshtein
/// budget, *and* the word is neither a glossary term itself nor a known common
/// word. This lets `Gokumo`/`Fertina` snap to `gocomo`/`Firtina` while a
/// homophone-adjacent everyday word like `kommen` is left untouched.
public struct TranscriptGlossaryCorrector {

    /// How aggressively to correct.
    public enum Level: String {
        /// No-op — segments pass through unchanged.
        case off
        /// Primary-code match within the base distance budget.
        case conservative
        /// Also allow secondary-code matches and a distance budget of +1.
        case aggressive
    }

    private let level: Level

    public init(level: Level) {
        self.level = level
    }

    /// A glossary term paired with its precomputed phonetic codes.
    private struct EncodedTerm {
        let text: String
        let primary: String
        let secondary: String
        let tokenCount: Int   // 1 = unigram, 2 = bigram
    }

    /// Apply the correction to every segment. The `log` callback fires once per
    /// replacement as `(from, to)` so the pipeline can record each rewrite.
    public func correct(
        _ segments: [TranscriptionSegment],
        glossary: EpisodeGlossary,
        log: (String, String) -> Void
    ) -> [TranscriptionSegment] {
        guard level != .off else { return segments }

        // Precompute phonetic codes for every glossary term, split by arity.
        let encoded = glossary.terms.map { term -> EncodedTerm in
            let (p, s) = DoubleMetaphone.encode(term.text)
            let count = term.text.split(whereSeparator: { $0.isWhitespace }).count
            return EncodedTerm(text: term.text, primary: p, secondary: s, tokenCount: count)
        }
        let unigrams = encoded.filter { $0.tokenCount == 1 && !$0.primary.isEmpty }
        let bigrams  = encoded.filter { $0.tokenCount == 2 && !$0.primary.isEmpty }

        // Set of glossary spellings (lowercased) — a word that already *is* a
        // glossary term is never rewritten.
        let glossaryWords = Set(glossary.terms.map { $0.text.lowercased() })

        return segments.map { segment in
            let newText = rewrite(
                segment.text,
                unigrams: unigrams,
                bigrams: bigrams,
                glossaryWords: glossaryWords,
                log: log
            )
            guard newText != segment.text else { return segment }
            return TranscriptionSegment(
                start: segment.start,
                end: segment.end,
                text: newText,
                noSpeechProb: segment.noSpeechProb,
                avgLogprob: segment.avgLogprob
            )
        }
    }

    // MARK: - Tokenisation

    /// A slice of the source text: either a run of word characters or a run of
    /// separators (whitespace/punctuation). Preserving both lets us rebuild the
    /// string byte-for-byte except for the words we intentionally replace.
    private enum Piece {
        case word(String)
        case sep(String)
    }

    private func split(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var buf = ""
        var bufIsWord = false
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber
            if buf.isEmpty {
                buf.append(ch); bufIsWord = isWord
            } else if isWord == bufIsWord {
                buf.append(ch)
            } else {
                pieces.append(bufIsWord ? .word(buf) : .sep(buf))
                buf = String(ch); bufIsWord = isWord
            }
        }
        if !buf.isEmpty { pieces.append(bufIsWord ? .word(buf) : .sep(buf)) }
        return pieces
    }

    // MARK: - Rewrite

    private func rewrite(
        _ text: String,
        unigrams: [EncodedTerm],
        bigrams: [EncodedTerm],
        glossaryWords: Set<String>,
        log: (String, String) -> Void
    ) -> String {
        var pieces = split(text)

        // Indices of word pieces, in order, so we can look at adjacent words
        // (ignoring the separator pieces between them) for bigram matching.
        let wordIndices = pieces.indices.filter {
            if case .word = pieces[$0] { return true } else { return false }
        }

        var replacedWordPieceIndices = Set<Int>()

        // Pass 1 — bigrams (only when the glossary has any). Matching a bigram
        // rewrites the FIRST word to the full replacement and blanks the second,
        // preserving the original separator run only if needed.
        if !bigrams.isEmpty {
            var w = 0
            while w + 1 < wordIndices.count {
                let i1 = wordIndices[w]
                let i2 = wordIndices[w + 1]
                guard case let .word(word1) = pieces[i1],
                      case let .word(word2) = pieces[i2] else { w += 1; continue }
                // Only consider a bigram when BOTH words are potentially wrong.
                // If either word is already a glossary term (already correct),
                // let per-word correction handle the other — this keeps the log
                // at word granularity and avoids rewriting a correct token.
                let phrase = "\(word1) \(word2)"
                let eitherAlreadyCorrect =
                    glossaryWords.contains(word1.lowercased()) ||
                    glossaryWords.contains(word2.lowercased())
                // Never rewrite a phrase where either constituent word is itself
                // a known common word — mirrors the unigram guard below. Two
                // adjacent everyday words can otherwise clear the phonetic +
                // Levenshtein gate together even though neither would alone.
                let eitherCommonWord =
                    EpisodeGlossary.commonWords.contains(word1.lowercased()) ||
                    EpisodeGlossary.commonWords.contains(word2.lowercased())
                if !eitherAlreadyCorrect,
                   !eitherCommonWord,
                   !glossaryWords.contains(phrase.lowercased()),
                   let match = bestMatch(for: phrase, in: bigrams) {
                    pieces[i1] = .word(match)
                    // Remove the second word + the separator between the two words.
                    for k in (i1 + 1)...i2 { pieces[k] = .sep("") }
                    replacedWordPieceIndices.insert(i1)
                    replacedWordPieceIndices.insert(i2)
                    log(phrase, match)
                    w += 2   // consume both words
                    continue
                }
                w += 1
            }
        }

        // Pass 2 — single words not already consumed by a bigram replacement.
        for idx in wordIndices where !replacedWordPieceIndices.contains(idx) {
            guard case let .word(word) = pieces[idx] else { continue }
            let lower = word.lowercased()
            // Never rewrite a word that is itself a glossary term, or a common word.
            if glossaryWords.contains(lower) { continue }
            if EpisodeGlossary.commonWords.contains(lower) { continue }
            if let match = bestMatch(for: word, in: unigrams), match != word {
                pieces[idx] = .word(match)
                log(word, match)
            }
        }

        return pieces.map {
            switch $0 { case .word(let s): return s; case .sep(let s): return s }
        }.joined()
    }

    // MARK: - Matching

    /// Find the best glossary term for `token` (a word or a two-word phrase),
    /// or `nil` if none is close enough. Requires a phonetic-code collision and
    /// a length-scaled Levenshtein distance within budget; the closest (then
    /// alphabetically stable) candidate wins.
    private func bestMatch(for token: String, in terms: [EncodedTerm]) -> String? {
        let (tp, ts) = DoubleMetaphone.encode(token)
        guard !tp.isEmpty else { return nil }

        var best: (text: String, distance: Int)? = nil
        for term in terms {
            // Phonetic gate: primary must match; aggressive also accepts a
            // primary↔secondary cross-match.
            let codeMatch: Bool
            switch level {
            case .off:
                codeMatch = false
            case .conservative:
                codeMatch = (tp == term.primary)
            case .aggressive:
                codeMatch = (tp == term.primary)
                    || (ts == term.secondary && !ts.isEmpty)
                    || (tp == term.secondary && !term.secondary.isEmpty)
                    || (ts == term.primary && !ts.isEmpty)
            }
            guard codeMatch else { continue }

            // Distance gate: budget scales with the term length, clamped [1,3]
            // (+1 in aggressive mode).
            let base = min(max(Int((Double(term.text.count) * 0.34).rounded(.up)), 1), 3)
            let budget = (level == .aggressive) ? base + 1 : base
            let d = StringDistance.levenshtein(token, term.text, max: budget)
            guard d <= budget else { continue }

            if best == nil || d < best!.distance
                || (d == best!.distance && term.text < best!.text) {
                best = (term.text, d)
            }
        }
        return best?.text
    }
}
