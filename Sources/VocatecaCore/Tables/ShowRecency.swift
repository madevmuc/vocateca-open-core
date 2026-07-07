import Foundation

public extension Show {
    /// Whether an `added_at` value (a `yyyy-MM-dd` date or full ISO timestamp) is
    /// within the last 24 hours — the predicate behind the Shows "New" badge.
    ///
    /// The sentinel past date (`defaultAddedAt`), unparseable values, and future
    /// dates all return `false`.
    static func isAddedAtRecent(_ addedAt: String, now: Date = Date()) -> Bool {
        guard addedAt != defaultAddedAt else { return false }

        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone.current
        dateOnly.dateFormat = "yyyy-MM-dd"

        let parsed = dateOnly.date(from: addedAt) ?? ISO8601DateFormatter().date(from: addedAt)
        guard let date = parsed else { return false }
        return date <= now && now.timeIntervalSince(date) < 24 * 60 * 60
    }
}
