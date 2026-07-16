// swift/Sources/VocatecaCore/CommandPalette/CommandPaletteFilter.swift
import Foundation

/// A single entry in the ⌘K command palette (UX pass, Task 5). Pure data —
/// the palette action itself (a `NotificationCenter` post) lives in
/// `VocatecaUI/Screens/CommandPalette/CommandPaletteSheet.swift` alongside a
/// parallel `id -> () -> Void` action map, so this struct stays `Sendable`/
/// `Equatable` and testable from `VocatecaCore` (which has no UI dependency).
public struct CommandPaletteEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    /// Intent-based group label (e.g. "Navigate", "Add", "Actions", "Open") used
    /// to render section headers in the palette. Plain, pre-localised display
    /// string — `VocatecaCore` has no UI/localisation dependency, so callers in
    /// `VocatecaUI` pass the already-`L(...)`-resolved string. Defaults to ""
    /// so existing call sites (and tests) that don't care about grouping still compile.
    public let group: String
    /// Extra search synonyms NOT shown in the row, matched by the filter so an
    /// action is findable by words a user is likely to type even when they don't
    /// appear in the title/subtitle (e.g. „update" finding „Refresh All Shows"
    /// and „Check for Updates"). Space-separated. Empty by default so existing
    /// call sites/tests are unaffected. 2026-07-16.
    public let keywords: String

    public init(id: String, title: String, subtitle: String, systemImage: String,
                group: String = "", keywords: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.group = group
        self.keywords = keywords
    }
}

/// Pure, unit-testable filter for the command palette's search field.
public enum CommandPaletteFilter {
    /// Case-insensitive substring match over `title` + `subtitle` + `keywords`.
    /// An empty (or all-whitespace) query returns all entries in their original
    /// order.
    public static func filter(_ query: String, _ entries: [CommandPaletteEntry]) -> [CommandPaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.title.range(of: trimmed, options: .caseInsensitive) != nil ||
            $0.subtitle.range(of: trimmed, options: .caseInsensitive) != nil ||
            (!$0.keywords.isEmpty && $0.keywords.range(of: trimmed, options: .caseInsensitive) != nil)
        }
    }
}
