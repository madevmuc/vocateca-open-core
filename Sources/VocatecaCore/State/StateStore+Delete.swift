import Foundation
import GRDB

// MARK: - StateStore: show deletion

public extension StateStore {

    /// Deletes all episode rows for `slug` from the `episodes` table.
    ///
    /// Uses a parameterised DELETE so it is safe against slug values that
    /// contain SQL-special characters.  The `slug_reservations` and IG cursor
    /// tables are left intact — those are low-cost references and their absence
    /// would be confusing if the user re-adds the same show later.
    ///
    /// - Parameter slug: The ``Show/slug`` to remove.
    /// - Throws: A GRDB error if the database is not writable or the query fails.
    func deleteShow(slug: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM episodes WHERE show_slug = ?",
                arguments: [slug]
            )
            // Drop this show's transcript FTS rows in the SAME transaction so the
            // Library full-text search never surfaces hits for an unsubscribed
            // show whose transcript files were just removed from disk. Guarded so
            // an older DB without the FTS table (pre-v5, before the first open ran
            // `ensureAdditiveTables`) doesn't turn a show-delete into a throw.
            if try db.tableExists("transcripts_fts") {
                try db.execute(
                    sql: "DELETE FROM transcripts_fts WHERE show_slug = ?",
                    arguments: [slug]
                )
            }
        }
    }
}
