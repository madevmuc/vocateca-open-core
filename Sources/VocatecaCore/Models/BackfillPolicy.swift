import Foundation

// MARK: - BackfillMode

/// The four unified import-scope modes usable by every source (podcast,
/// YouTube, Instagram) via `Show.backfillMode`.
public enum BackfillMode: String, Sendable, CaseIterable, Codable {
    /// Every item in scope — the historical, still-default behaviour.
    case all
    /// Only the most recent `Show.backfillN` items (by pub date).
    case lastN = "last_n"
    /// Only items with `pubDate >= Show.backfillSince` (ISO `YYYY-MM-DD`).
    case sinceDate = "since_date"
    /// Nothing historical — only items published after `Show.addedAt`.
    case onlyNew = "only_new"

    /// User-facing label for pickers (Show Details, Add-source sheets).
    public var displayName: String {
        switch self {
        case .all:       return "All episodes"
        case .lastN:     return "Last N"
        case .sinceDate: return "Since date"
        case .onlyNew:   return "Only new from now"
        }
    }
}

// MARK: - BackfillPolicy

/// Pure, testable description of a show's import scope plus the logic that
/// decides which episodes fall inside it.
///
/// `BackfillPolicy` itself does no I/O — `StateStore.backfillPreview` /
/// `applyBackfill` build one from a `Show`'s stored fields and pass it here.
public struct BackfillPolicy: Sendable, Equatable {
    public let mode: BackfillMode
    public let n: Int
    /// ISO `YYYY-MM-DD` or empty (only meaningful for `.sinceDate`).
    public let sinceDate: String
    /// `Show.addedAt` — ISO `YYYY-MM-DD` (only meaningful for `.onlyNew`).
    public let subscribedAt: String

    public init(mode: BackfillMode, n: Int, sinceDate: String, subscribedAt: String) {
        self.mode = mode
        self.n = n
        self.sinceDate = sinceDate
        self.subscribedAt = subscribedAt
    }

    /// Convenience initializer straight from a `Show`'s stored backfill fields.
    public init(show: Show) {
        self.mode = BackfillMode(rawValue: show.backfillMode) ?? .all
        self.n = show.backfillN
        self.sinceDate = show.backfillSince
        self.subscribedAt = show.addedAt
    }

    /// Decides which `episodes` are in scope under this policy.
    ///
    /// - Parameter episodes: May be unsorted; sorted by `pubDate` descending
    ///   internally before applying `.lastN`. Entries with an empty/malformed
    ///   `pubDate` sort last (treated as "oldest" — never picked as one of the
    ///   newest N) and are excluded from `.sinceDate` / `.onlyNew` (a missing
    ///   date can't be proven to satisfy either comparison, so it is treated
    ///   as NOT in scope — the safer default for a scope-narrowing feature).
    /// - Returns: The set of `guid`s that are in scope.
    public func inScopeGuids(episodes: [(guid: String, pubDate: String)]) -> Set<String> {
        switch mode {
        case .all:
            return Set(episodes.map(\.guid))

        case .lastN:
            guard n > 0 else { return [] }
            let sorted = episodes.sorted { lhs, rhs in
                // Empty/malformed dates sort last regardless of string value.
                let l = lhs.pubDate, r = rhs.pubDate
                if l.isEmpty != r.isEmpty { return r.isEmpty }  // non-empty first
                return l > r  // ISO strings compare lexicographically desc
            }
            return Set(sorted.prefix(n).map(\.guid))

        case .sinceDate:
            guard Self.isValidISODate(sinceDate) else { return [] }
            return Set(episodes.filter { Self.isValidISODate($0.pubDate) && $0.pubDate >= sinceDate }
                .map(\.guid))

        case .onlyNew:
            guard Self.isValidISODate(subscribedAt) else { return [] }
            return Set(episodes.filter { Self.isValidISODate($0.pubDate) && $0.pubDate > subscribedAt }
                .map(\.guid))
        }
    }

    /// True when `date` looks like a well-formed ISO date/datetime string
    /// (at minimum a 10-char `YYYY-MM-DD` prefix). Guards against empty or
    /// malformed `pubDate`/`sinceDate` values corrupting string comparisons.
    static func isValidISODate(_ date: String) -> Bool {
        guard date.count >= 10 else { return false }
        let prefix = date.prefix(10)
        let parts = prefix.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return true
    }
}
