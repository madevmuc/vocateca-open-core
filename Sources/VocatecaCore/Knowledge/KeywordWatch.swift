import Foundation

// MARK: - KeywordHit

/// A single keyword match found in a text body.
public struct KeywordHit: Sendable, Equatable {
    /// The matched keyword (as originally supplied — case-preserved).
    public let keyword: String

    /// Number of times the keyword appears in the text.
    public let count: Int

    /// Character ranges of each match within the text, in order of occurrence.
    public let ranges: [Range<String.Index>]

    public init(keyword: String, count: Int, ranges: [Range<String.Index>]) {
        self.keyword = keyword
        self.count = count
        self.ranges = ranges
    }
}

// MARK: - KeywordWatch

/// Pure keyword matching for transcript watch lists.
///
/// This is only the low-level matching primitive. The production keyword-watch
/// feature is a separate code path — `WatchTerm` + `WatchlistScanner`, driven
/// from `AppShell`'s watchlist-scan hooks and persisted to the `watchlist_hits`
/// table. `Settings.keywordWatch` is `[WatchTerm]` (v2-only, excluded from
/// oracle parity; YAML key `keyword_watch`).
///
/// ## Matching rules
///
/// ### Case sensitivity
/// All matching is **case-insensitive**.
///
/// ### Whole-word mode (`wholeWord: true`)
/// Uses Unicode word boundaries. A match is only counted when the keyword is
/// surrounded by non-word characters or string boundaries. This prevents
/// "rate" matching "accurate" or "irate".
///
/// Implementation: uses `NSRegularExpression` with `\\b` word-boundary anchors
/// around the keyword (special regex characters in the keyword are escaped).
///
/// ### Substring mode (`wholeWord: false`)
/// Simple case-insensitive substring scan. "rate" matches "accurate".
public struct KeywordWatch: Sendable {

    // MARK: - Pure matcher

    /// Finds all matching keywords in `text`.
    ///
    /// - Parameters:
    ///   - text: The text to search (e.g. a full transcript).
    ///   - keywords: The list of keywords to look for.
    ///   - wholeWord: When `true`, only whole-word matches are counted.
    /// - Returns: One `KeywordHit` per keyword that appears at least once, in
    ///   the same order as `keywords`. Keywords with zero matches are omitted.
    public static func matches(
        text: String,
        keywords: [String],
        wholeWord: Bool
    ) -> [KeywordHit] {
        guard !text.isEmpty, !keywords.isEmpty else { return [] }
        var hits: [KeywordHit] = []

        for keyword in keywords {
            guard !keyword.isEmpty else { continue }
            let ranges = findRanges(of: keyword, in: text, wholeWord: wholeWord)
            if !ranges.isEmpty {
                hits.append(KeywordHit(keyword: keyword, count: ranges.count, ranges: ranges))
            }
        }

        return hits
    }

    // MARK: - Private helpers

    /// Finds all ranges of `keyword` in `text` using the appropriate strategy.
    private static func findRanges(
        of keyword: String,
        in text: String,
        wholeWord: Bool
    ) -> [Range<String.Index>] {
        if wholeWord {
            return findWholeWordRanges(of: keyword, in: text)
        } else {
            return findSubstringRanges(of: keyword, in: text)
        }
    }

    /// Case-insensitive substring scan. Searches the ORIGINAL `text` with the
    /// `.caseInsensitive` option so every returned `Range<String.Index>` is native
    /// to `text` (searching a separately-lowercased copy can yield indices that are
    /// invalid against `text` because `lowercased()` is not length-preserving for
    /// some Unicode, e.g. `İ` → `i̇`).
    private static func findSubstringRanges(
        of keyword: String,
        in text: String
    ) -> [Range<String.Index>] {
        guard !keyword.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: keyword, options: .caseInsensitive, range: searchRange) {
            ranges.append(range)
            if range.upperBound >= text.endIndex { break }
            // Advance by at least one character to avoid an infinite loop on a
            // zero-width match.
            searchRange = (range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound)..<text.endIndex
        }
        return ranges
    }

    /// Case-insensitive whole-word scan via `NSRegularExpression` with `\b`.
    private static func findWholeWordRanges(
        of keyword: String,
        in text: String
    ) -> [Range<String.Index>] {
        // Escape special regex characters in the keyword.
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return [] }

        let nsText = text as NSString
        let nsRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        return matches.compactMap { match -> Range<String.Index>? in
            Range(match.range, in: text)
        }
    }
}

// MARK: - EventType extension (keyword.match)

extension EventType {
    /// Emitted when a watched keyword is found in a newly-transcribed episode.
    ///
    /// Payload keys: `keyword` (String), `count` (Number), `show_slug` (String),
    /// `guid` (String).
    public static let keywordMatch = "keyword.match"
}
