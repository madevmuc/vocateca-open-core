import Foundation

// MARK: - EpisodeFilterLogic

/// Pure (UI-free) episode filtering and sorting logic for the Show Details
/// popup. Extracted into `VocatecaCore` so it can be unit-tested directly
/// without touching SwiftUI.
///
/// The `ShowDetailsSheet` delegates to these functions so its computed property
/// `filteredEpisodes` is thin and testable.
public enum EpisodeFilterLogic {

    // MARK: - Sort key

    public enum SortKey: String, CaseIterable, Sendable {
        case title    = "Title"
        case date     = "Date"
        case duration = "Duration"
    }

    // MARK: - Combined filter

    /// Returns the subset of `episodes` that match the free-text `query`
    /// (title or description) **and** fall within the optional date range.
    ///
    /// - Parameters:
    ///   - episodes: Source list (not mutated).
    ///   - query:    Case-insensitive search string. Empty / whitespace-only →
    ///               all episodes pass the text filter.
    ///   - dateFrom: Inclusive lower bound on `pub_date` (ISO-8601 prefix
    ///               comparison). `nil` → no lower bound.
    ///   - dateTo:   Inclusive upper bound (the full calendar day of `dateTo`
    ///               is included). `nil` → no upper bound.
    public static func filter(
        _ episodes: [Episode],
        query: String,
        dateFrom: Date?,
        dateTo: Date?
    ) -> [Episode] {
        var result = episodes

        // ── Text filter ────────────────────────────────────────────────
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter { ep in
                ep.title.lowercased().contains(q) ||
                (ep.description ?? "").lowercased().contains(q)
            }
        }

        // ── Date filter ────────────────────────────────────────────────
        if let from = dateFrom {
            let fromStr = ymd(from)
            result = result.filter { $0.pubDate >= fromStr }
        }
        if let to = dateTo {
            // Include the full to-day (pub_date < day after to).
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: to) ?? to
            let toStr = ymd(nextDay)
            result = result.filter { $0.pubDate < toStr }
        }

        return result
    }

    // MARK: - Sort

    /// Returns `episodes` sorted by `key` in the requested direction.
    ///
    /// - `title`:    Lexicographic (`localizedCompare`).
    /// - `date`:     `pub_date` string prefix comparison (ISO-8601 dates sort correctly lexicographically).
    /// - `duration`: `durationSec`, with `nil` treated as 0 seconds.
    public static func sort(
        _ episodes: [Episode],
        by key: SortKey,
        ascending: Bool
    ) -> [Episode] {
        episodes.sorted { a, b in
            switch key {
            case .title:
                let cmp = a.title.localizedCompare(b.title)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            case .date:
                return ascending ? a.pubDate < b.pubDate : a.pubDate > b.pubDate
            case .duration:
                let da = a.durationSec ?? 0
                let db = b.durationSec ?? 0
                return ascending ? da < db : da > db
            }
        }
    }

    // MARK: - Helpers

    /// Format `date` as `"yyyy-MM-dd"` in UTC, matching the `pub_date` column format.
    public static func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
