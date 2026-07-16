import Foundation

/// A single Watchlist term the user wants flagged in transcripts.
///
/// Plain terms match on whole-word boundaries (case-insensitive); `isRegex`
/// terms are matched as a raw regular expression (defensively compiled — an
/// invalid pattern is stored but skipped at scan time, never crashing).
public struct WatchTerm: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var term: String
    public var isRegex: Bool
    public var enabled: Bool
    /// Also raise a macOS system notification on a hit (subject to the notif prefs).
    public var notify: Bool
    public var createdAt: String

    public init(
        id: String,
        term: String,
        isRegex: Bool = false,
        enabled: Bool = true,
        notify: Bool = false,
        createdAt: String = ""
    ) {
        self.id = id
        self.term = term
        self.isRegex = isRegex
        self.enabled = enabled
        self.notify = notify
        self.createdAt = createdAt
    }
}

/// One match of a `WatchTerm` in a transcript.
public struct WatchlistHit: Sendable, Equatable {
    public let termID: String
    public let term: String
    /// Trimmed context window around the match (for display in the hits feed).
    public let snippet: String
    /// UTF-16 character offset of the match start in the source text.
    public let offset: Int

    public init(termID: String, term: String, snippet: String, offset: Int) {
        self.termID = termID
        self.term = term
        self.snippet = snippet
        self.offset = offset
    }
}

public extension KeywordWatch {

    /// Scans `text` for every enabled `WatchTerm`, returning one `WatchlistHit`
    /// per match (in text order per term).
    ///
    /// - Plain term → `\bTERM` (word-boundary PREFIX match), case-insensitive.
    ///   "ai" matches the standalone word "AI" but not "chair"/"Chairman"
    ///   (no boundary before "ai" inside those words) — same exclusion as
    ///   before. Unlike the old `\bTERM\b` (both boundaries), a prefix match
    ///   also catches a term at the START of a longer word, e.g. "energie"
    ///   now matches "Energiewende"/"Energien"/"energieeffizientere". This
    ///   deliberately mirrors `StateStore.makeFTSMatchExpression`'s `"term"*`
    ///   FTS5 prefix-token query — the SAME matching semantics the Library
    ///   full-text search already uses successfully against German compound
    ///   words — so a keyword that finds plenty of hits via Library search no
    ///   longer silently under-counts in the Watchlist scan (2026-07-16: a
    ///   German "Energie" term whole-word-matched only standalone "Energie"
    ///   occurrences, missing "Energiewende"/"Energiepreis"/etc. compounds
    ///   that make up the bulk of real hits in German transcripts).
    /// - `isRegex` term → the raw pattern, case-insensitive; an invalid pattern
    ///   is skipped (never throws). Users who want the OLD exact-word-only
    ///   behaviour can still write `\bTERM\b` themselves via regex mode.
    /// - `snippetRadius` characters of context are captured on each side.
    static func evaluate(text: String, terms: [WatchTerm], snippetRadius: Int = 40) -> [WatchlistHit] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [WatchlistHit] = []

        for term in terms where term.enabled && !term.term.isEmpty {
            let pattern = term.isRegex
                ? term.term
                : "\\b\(NSRegularExpression.escapedPattern(for: term.term))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                Log.warn("KeywordWatch: invalid regex term skipped", component: "Watchlist",
                         context: [("termID", term.id), ("isRegex", "\(term.isRegex)")])
                continue  // invalid regex → skip, don't crash
            }
            for match in regex.matches(in: text, options: [], range: full) {
                let r = match.range
                guard r.length > 0 else { continue }  // ignore zero-width matches
                let start = max(0, r.location - snippetRadius)
                let end = min(ns.length, r.location + r.length + snippetRadius)
                let snippet = ns.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hits.append(WatchlistHit(termID: term.id, term: term.term, snippet: snippet, offset: r.location))
            }
        }
        return hits
    }
}
