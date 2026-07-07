import Foundation
import GRDB

// MARK: - Show slugs (StateStore passthrough)

extension StateStore {
    /// All distinct `show_slug` values in `episodes`, sorted alphabetically.
    ///
    /// Mirrors ``StateReader/allShowSlugs()`` exactly. Added so `AutomationRunner`
    /// (which holds a `StateStore`, not a `StateReader`) can determine whether any
    /// show has auto-download enabled without needing a second reader instance.
    public func allShowSlugs() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, SQLRequest(sql: "SELECT DISTINCT show_slug FROM episodes ORDER BY show_slug"))
            return rows.map { $0["show_slug"] as String }
        }
    }
}
