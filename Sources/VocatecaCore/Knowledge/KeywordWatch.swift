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

/// Pure keyword matching and event emission for transcript watch lists.
///
/// ## Storage
/// Keywords are stored in `Settings.keywordWatch: [String]` — a v2-only field
/// (not present in the Python oracle). See ``Settings`` for the full field
/// definition. Each string in the array is a keyword/phrase to watch for.
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
///
/// ## Event emission
/// After transcription completes, call ``evaluate(text:keywords:showSlug:guid:bus:)``
/// to scan the text and emit `keyword.match` events via the provided `EventBus`.
/// Each keyword that appears at least once produces one event with the keyword
/// and match count in the payload.
///
/// ## Keyword storage field
/// `Settings.keywordWatch: [String]` is a v2-only field excluded from oracle parity.
/// YAML key: `keyword_watch`. Default: empty array.
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

    // MARK: - Event evaluator

    /// Scans transcript text for watched keywords and emits `keyword.match`
    /// events for each hit via `bus`.
    ///
    /// Call this after a new episode has been successfully transcribed. Each
    /// keyword that matches produces exactly one `keyword.match` event with:
    ///
    /// ```
    /// payload = {
    ///   "keyword":   .string(keyword),
    ///   "count":     .number(Double(hit.count)),
    ///   "show_slug": .string(showSlug),   // also in Event.showSlug
    ///   "guid":      .string(guid)         // also in Event.guid
    /// }
    /// ```
    ///
    /// Uses `wholeWord: false` (substring matching) — users can include spaces
    /// or punctuation in their keywords if they need phrase-level precision.
    ///
    /// - Parameters:
    ///   - text:     Transcript text to scan.
    ///   - keywords: List of keywords to watch for.
    ///   - showSlug: Show slug for the event payload.
    ///   - guid:     Episode guid for the event payload.
    ///   - bus:      EventBus to emit on.
    public static func evaluate(
        text: String,
        keywords: [String],
        showSlug: String,
        guid: String,
        bus: EventBus
    ) async {
        let hits = matches(text: text, keywords: keywords, wholeWord: false)
        for hit in hits {
            let event = Event(
                type: EventType.keywordMatch,
                showSlug: showSlug,
                guid: guid,
                payload: [
                    "keyword":   .string(hit.keyword),
                    "count":     .number(Double(hit.count)),
                    "show_slug": .string(showSlug),
                    "guid":      .string(guid),
                ]
            )
            await bus.emit(event)
        }
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
