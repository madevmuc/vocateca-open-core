import Foundation

/// Persisted per-column state for a configurable table.
public struct ColumnState: Codable, Equatable, Sendable {
    public let id: String
    public var visible: Bool
    public var width: Double
    public var order: Int

    public init(id: String, visible: Bool, width: Double, order: Int) {
        self.id = id
        self.visible = visible
        self.width = width
        self.order = order
    }
}

/// The active sort for a table: which column, ascending or descending.
public struct SortState: Codable, Equatable, Sendable {
    public var columnID: String
    public var ascending: Bool

    public init(columnID: String, ascending: Bool) {
        self.columnID = columnID
        self.ascending = ascending
    }
}

/// A table's full persisted layout — column visibility/width/order plus the
/// active sort. Stored per table id in `Settings.tableLayouts` (portable YAML).
public struct TableLayout: Codable, Equatable, Sendable {
    public var columns: [ColumnState]
    public var sort: SortState?

    /// JSON blob of a native SwiftUI `Table`'s `TableColumnCustomization`
    /// (per-column width / visibility / order). Used by the native-`Table` screens
    /// (Shows, …). Optional so pre-existing YAML without the key still decodes.
    public var customization: String?

    public init(columns: [ColumnState], sort: SortState? = nil, customization: String? = nil) {
        self.columns = columns
        self.sort = sort
        self.customization = customization
    }

    /// Reconciles a persisted layout against the columns the code currently
    /// defines (`available`, each carrying its default state):
    ///
    /// - keeps persisted columns that still exist (preserving the user's
    ///   visibility / width / order),
    /// - drops persisted columns whose id is no longer available,
    /// - appends newly-available columns at their defaults, after existing ones,
    /// - clears the sort if its column no longer exists.
    ///
    /// This makes stored layouts forward/backward-compatible across releases.
    public func merge(withAvailable available: [ColumnState]) -> TableLayout {
        let availableIDs = Set(available.map(\.id))

        // Dedupe persisted columns by id (keep first) so a corrupted / hand-edited
        // layout with repeated ids can't accumulate permanent duplicates.
        var seen = Set<String>()
        let deduped = columns.filter { seen.insert($0.id).inserted }

        var kept = deduped.filter { availableIDs.contains($0.id) }
        let keptIDs = Set(kept.map(\.id))

        var nextOrder = (kept.map(\.order).max() ?? -1) + 1
        for col in available where !keptIDs.contains(col.id) {
            var c = col
            c.order = nextOrder
            nextOrder += 1
            kept.append(c)
        }

        let newSort = sort.flatMap { availableIDs.contains($0.columnID) ? $0 : nil }
        return TableLayout(columns: kept, sort: newSort, customization: customization)
    }
}
