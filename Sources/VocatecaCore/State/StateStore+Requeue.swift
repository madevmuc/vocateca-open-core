import Foundation
import GRDB

// MARK: - StateStore: episode re-queue

public extension StateStore {

    /// Resets the `status` column of all episodes in `guids` to `"pending"` so
    /// the queue runner picks them up on its next pass.
    ///
    /// This is a **manual** retry / "Wieder einplanen": the user explicitly asked
    /// for another go, so the failure bookkeeping is cleared to give a full retry
    /// budget:
    /// - `attempts = 0` (**L1**): previously untouched, so a manually-requeued
    ///   episode that had already failed twice had only one attempt left and died
    ///   on the next transcribe-fail immediately. Resetting gives the full
    ///   `maxAttempts` budget the user expects from a manual retry.
    /// - `attempted_at = NULL`: also cleared so the **M1** retry-backoff window
    ///   (which keys off a recent `attempted_at`) doesn't delay this deliberate
    ///   re-queue — it should be claimable at once.
    /// - `error_text` / `error_category` are cleared so the row doesn't carry a
    ///   stale failure reason while it waits to be re-processed.
    ///
    /// `completed_at` is left as-is. Silently ignores guids that are not found.
    ///
    /// - Parameter guids: The episode guids to re-queue.
    /// - Throws: A GRDB error if the database is not writable.
    func requeue(guids: [String]) throws {
        guard !guids.isEmpty else { return }
        // Build a parameterised IN clause. GRDB's StatementArguments accepts a
        // flat list; the placeholders are "?,?,?..." matching guids.count.
        let placeholders = guids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            UPDATE episodes
            SET status = 'pending', attempts = 0, attempted_at = NULL,
                error_text = NULL, error_category = NULL
            WHERE guid IN (\(placeholders))
        """
        let args = StatementArguments(guids)
        try dbQueue.write { db in
            try db.execute(sql: sql, arguments: args)
        }
    }
}
