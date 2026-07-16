import Foundation

/// A single proper-noun candidate extracted from episode/show metadata,
/// tagged with the field it came from (for logging + debugging).
public struct GlossaryTerm: Sendable, Equatable {
    /// The term exactly as it appears in the source (original casing).
    public let text: String
    /// Where it was found: `"title" | "description" | "show" | "author" | "prompt"`.
    public let source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

/// The set of proper-noun candidates for one episode, used by
/// ``TranscriptGlossaryCorrector`` to fix ASR mishearings.
///
/// Built from the episode title/description, the show name/author, and the
/// per-show Whisper prompt. Extraction keeps high-signal tokens (and adjacent
/// bigrams) and drops stop-words and a small set of everyday words so the
/// matcher never "corrects" a common word into a brand name.
public struct EpisodeGlossary: Sendable {
    public let terms: [GlossaryTerm]

    public init(terms: [GlossaryTerm]) {
        self.terms = terms
    }

    /// German + English articles, prepositions, pronouns and other closed-class
    /// filler. These are never glossary terms (`keepToken` below), AND — since
    /// they are closed-class by definition, never a proper noun in disguise —
    /// they are also never a correction TARGET: ``TranscriptGlossaryCorrector``
    /// refuses to rewrite a transcript word that appears here, no matter how
    /// well it phonetically collides with a glossary term. This is the fix for
    /// a real production bug where short function words ("so", "ich", "eine",
    /// "an") were being "corrected" into unrelated glossary terms ("CEO",
    /// "Ache", "Anne") purely because they share a short Double-Metaphone code.
    ///
    /// The personal-pronoun rows were added for that fix — the original list
    /// only had the possessive forms (his/her/its/our/your/their and
    /// sein/seine), leaving the base subject/object pronouns (ich/du/er/es/…,
    /// I/you/he/she/…) as an unguarded gap on both the extraction and
    /// correction sides.
    static let stopwords: Set<String> = [
        // de — articles, conjunctions, prepositions, common verb forms
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines",
        "einem", "einen", "und", "oder", "aber", "von", "vom", "zum", "zur", "mit",
        "für", "auf", "aus", "bei", "bis", "durch", "gegen", "ohne", "über", "unter",
        "vor", "nach", "seit", "wie", "als", "auch", "nur", "noch", "sehr", "mehr",
        "sein", "seine", "ist", "sind", "war", "war", "wird", "werden", "hat", "haben",
        "wir", "ihr", "sie", "man", "dann", "wenn", "weil", "dass", "damit", "hier",
        // de — personal pronouns (nominative/accusative/dative), all cases
        "ich", "du", "er", "es", "mich", "dich", "ihn", "uns", "euch",
        "mir", "dir", "ihm", "ihnen", "sich",
        // en — articles, conjunctions, prepositions, common verb forms
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "by",
        "for", "with", "from", "into", "onto", "off", "out", "up", "down", "over",
        "under", "is", "are", "was", "were", "be", "been", "as", "so", "too", "not",
        "his", "her", "its", "our", "your", "their", "this", "that", "these", "those",
        "how", "why", "what", "who", "when", "where",
        // en — personal pronouns
        "i", "you", "he", "she", "we", "they", "it", "me", "him", "them", "us"
    ]

    /// Everyday content words that happen to sound like brand names. Kept small
    /// and deliberate — the phonetic matcher is the last line of defence, but a
    /// term list that includes these would let a common word be "corrected".
    static let commonWords: Set<String> = [
        // de — high-frequency verbs/nouns/adverbs likely to phonetically clash
        "kommen", "kommt", "komme", "gehen", "geht", "machen", "macht", "sagen",
        "sagt", "sehen", "sieht", "geben", "gibt", "nehmen", "folge", "folgen",
        "heute", "morgen", "gestern", "immer", "wieder", "schon", "ganz", "gut",
        "gute", "guten", "neue", "neuen", "leute", "jahr", "jahre", "zeit", "welt",
        // en
        "come", "comes", "coming", "going", "make", "makes", "made", "say", "says",
        "said", "see", "sees", "give", "gives", "take", "takes", "today", "always",
        "again", "good", "great", "people", "year", "years", "time", "world",
        "episode", "podcast", "welcome", "thanks", "thank"
    ]

    /// Build the glossary from raw metadata fields.
    ///
    /// - Title tokens are curated and high-signal: any non-stop/non-common token
    ///   of length ≥ 3 is kept, even lowercase brands (`gocomo`).
    /// - Description tokens are noisy prose: only kept when they carry a
    ///   capitalization signal (Capitalized / ALL-CAPS / inner-capital).
    /// - Show name + author follow the description rule.
    /// - Whisper-prompt terms are split on commas/whitespace and always kept.
    /// Adjacent kept tokens are also emitted as bigrams. Duplicates are removed,
    /// keeping the first (source) spelling.
    public static func build(
        title: String,
        description: String?,
        showName: String,
        author: String?,
        whisperPrompt: String
    ) -> EpisodeGlossary {
        var collected: [GlossaryTerm] = []

        collected += extract(from: title, source: "title", requireCapital: false)
        if let description, !description.isEmpty {
            collected += extract(from: description, source: "description", requireCapital: true)
        }
        collected += extract(from: showName, source: "show", requireCapital: true)
        if let author, !author.isEmpty {
            collected += extract(from: author, source: "author", requireCapital: true)
        }
        collected += promptTerms(whisperPrompt)

        // Dedupe case-insensitively, keeping the first occurrence's spelling.
        var seen = Set<String>()
        var deduped: [GlossaryTerm] = []
        for term in collected {
            let key = term.text.lowercased()
            if seen.insert(key).inserted {
                deduped.append(term)
            }
        }
        return EpisodeGlossary(terms: deduped)
    }

    // MARK: - Extraction

    /// Split text into word tokens, preserving each token's original spelling.
    /// Tokens break on any non-alphanumeric character (so `Co-Founder` → `Co`,
    /// `Founder`; `#193` → `193`).
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// True if a token clears the keep bar for its source.
    private static func keepToken(_ token: String, requireCapital: Bool) -> Bool {
        guard token.count >= 3 else { return false }
        let lower = token.lowercased()
        if stopwords.contains(lower) { return false }
        if commonWords.contains(lower) { return false }
        // Reject pure numbers (e.g. "193").
        if token.allSatisfy({ $0.isNumber }) { return false }
        guard requireCapital else { return true }
        return hasCapitalSignal(token)
    }

    /// Capitalized (first letter upper), ALL-CAPS, or contains an inner capital
    /// (camelCase / studly brand like `gocomo`→no, `PayPal`→yes).
    private static func hasCapitalSignal(_ token: String) -> Bool {
        let chars = Array(token)
        guard let first = chars.first else { return false }
        if first.isUppercase { return true }
        // inner capital
        return chars.dropFirst().contains { $0.isUppercase }
    }

    /// Extract single tokens + adjacent bigrams from one field.
    private static func extract(from text: String, source: String, requireCapital: Bool) -> [GlossaryTerm] {
        let tokens = tokenize(text)
        let kept = tokens.map { ($0, keepToken($0, requireCapital: requireCapital)) }

        var result: [GlossaryTerm] = []
        for (token, ok) in kept where ok {
            result.append(GlossaryTerm(text: token, source: source))
        }
        // Bigrams from consecutive kept tokens (both must individually pass).
        for i in 0..<kept.count where i + 1 < kept.count {
            let (a, aOK) = kept[i]
            let (b, bOK) = kept[i + 1]
            if aOK && bOK {
                result.append(GlossaryTerm(text: "\(a) \(b)", source: source))
            }
        }
        return result
    }

    /// Whisper-prompt terms: split on commas/whitespace, length ≥ 2, kept verbatim.
    private static func promptTerms(_ prompt: String) -> [GlossaryTerm] {
        let raw = prompt.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        return raw
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .map { GlossaryTerm(text: $0, source: "prompt") }
    }
}
