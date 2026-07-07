import Foundation

/// A typed, comparable cell value for the configurable-table sort engine.
///
/// A column declares which case it produces; the table sorts rows by comparing
/// two `SortValue`s of the same case. Sort **direction** is applied by the
/// caller (it flips the `ComparisonResult`), so `compare` is always ascending.
public enum SortValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case date(String)   // ISO-ish string; lexical order == chronological order

    /// Ascending comparison of two values.
    ///
    /// - `text`   → case- and diacritic-insensitive, locale-aware.
    /// - `number` → `Double` order.
    /// - `date`   → lexical string order (ISO dates sort chronologically).
    ///
    /// Mismatched cases never occur in practice (a column has a fixed kind); if
    /// they do, the result is `.orderedSame` so sorting stays total and stable.
    public static func compare(_ a: SortValue, _ b: SortValue) -> ComparisonResult {
        switch (a, b) {
        case let (.text(l), .text(r)):
            return l.compare(r, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current)
        case let (.number(l), .number(r)):
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        case let (.date(l), .date(r)):
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        default:
            return .orderedSame
        }
    }
}
