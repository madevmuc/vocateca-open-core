import Foundation

/// One resolved item in a batch picker (`BatchSelectionSheet`) — a playlist
/// video or a CSV line, always preselected on construction. Shared by
/// playlist-expand and CSV import (design doc §C) and reused by Phase B.
public struct BatchEntry: Identifiable, Sendable, Equatable {
    /// The URL doubles as the stable identity — a batch never contains two
    /// rows for the same link.
    public let id: String
    public let url: String
    public var title: String
    public let kind: OneOffLinkKind
    public var selected: Bool

    public init(url: String, title: String, kind: OneOffLinkKind, selected: Bool = true) {
        self.id = url
        self.url = url
        self.title = title
        self.kind = kind
        self.selected = selected
    }
}

public extension Array where Element == BatchEntry {
    /// De-duplicates by URL, keeping the first occurrence — a playlist line
    /// and a CSV line resolving to the same video should only appear once.
    func deduplicatedByURL() -> [BatchEntry] {
        var seen = Set<String>()
        var result: [BatchEntry] = []
        for entry in self where !seen.contains(entry.id) {
            seen.insert(entry.id)
            result.append(entry)
        }
        return result
    }
}

/// The batch-size guard (design doc §C: "bei sehr vielen Einträgen expliziter
/// Bestätigungs-Hinweis"). `BatchSelectionSheet` shows an explicit warning
/// once a batch exceeds this size instead of silently pre-checking dozens of
/// items.
public enum BatchAvalancheGuard {
    public static let threshold = 50
    public static func needsExplicitConfirmation(count: Int) -> Bool { count > threshold }
}
