import Foundation
import GRDB

// MARK: - StateStore: transcript deletion + skip

public extension StateStore {

    /// Clears the `transcript_path` column for `guid`, sets `status = 'skipped'`,
    /// and returns the **prior** `transcript_path` value so the caller can delete
    /// the file from disk.
    ///
    /// Everything runs in a single write transaction. After this call:
    /// - `claimNextPending` will never re-enqueue the episode (it only picks `pending`).
    /// - The transcript file is NOT deleted here — the caller receives the path and
    ///   is responsible for removing it via `FileManager`.
    ///
    /// - Parameter guid: The episode to act on.
    /// - Returns: The prior `transcript_path` string, or `nil` if none was set.
    /// - Throws: A GRDB error if the write fails.
    func clearTranscriptAndSkip(guid: String) throws -> String? {
        try dbQueue.write { db in
            // Read the current transcript path before clearing it.
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT transcript_path FROM episodes WHERE guid = ?",
                           arguments: [guid])
            )
            let priorPath: String? = row?["transcript_path"]

            // Single UPDATE: null out the path and mark as skipped.
            try db.execute(
                sql: """
                    UPDATE episodes
                    SET status = 'skipped', transcript_path = NULL
                    WHERE guid = ?
                """,
                arguments: [guid]
            )

            // Drop the transcript's FTS row in the SAME transaction — the file is
            // about to be deleted from disk, so leaving it searchable would let a
            // hit open a gone transcript. Guarded for pre-v5 DBs (see deleteShow).
            if try db.tableExists("transcripts_fts") {
                try db.execute(
                    sql: "DELETE FROM transcripts_fts WHERE guid = ?",
                    arguments: [guid]
                )
            }

            return priorPath
        }
    }

    /// Clears the `transcript_path` column for `guid`, sets `status = 'deleted'`,
    /// and returns the **prior** `transcript_path` value so the caller can delete
    /// the file from disk.
    ///
    /// Identical to ``clearTranscriptAndSkip(guid:)`` in every respect (single
    /// write transaction, drops the FTS row, returns the prior path for the
    /// caller to unlink) EXCEPT the terminal status it writes: `deleted` rather
    /// than `skipped`. `deleted` shares `skipped`'s processing semantics — the
    /// episode is never re-enqueued (`claimNextPending` only picks `pending`) —
    /// but the UI renders it as a neutral "Deleted" pill instead of "failed",
    /// distinguishing a user-deleted transcript from a pipeline skip.
    ///
    /// Used by the Show-detail "Delete transcripts & files" action. Existing
    /// skip callers are intentionally left on ``clearTranscriptAndSkip(guid:)``.
    ///
    /// - Parameter guid: The episode to act on.
    /// - Returns: The prior `transcript_path` string, or `nil` if none was set.
    /// - Throws: A GRDB error if the write fails.
    func clearTranscriptAndMarkDeleted(guid: String) throws -> String? {
        try dbQueue.write { db in
            // Read the current transcript path before clearing it.
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT transcript_path FROM episodes WHERE guid = ?",
                           arguments: [guid])
            )
            let priorPath: String? = row?["transcript_path"]

            // Single UPDATE: null out the path and mark as deleted.
            try db.execute(
                sql: """
                    UPDATE episodes
                    SET status = 'deleted', transcript_path = NULL
                    WHERE guid = ?
                """,
                arguments: [guid]
            )

            // Drop the transcript's FTS row in the SAME transaction — the file is
            // about to be deleted from disk, so leaving it searchable would let a
            // hit open a gone transcript. Guarded for pre-v5 DBs (see deleteShow).
            if try db.tableExists("transcripts_fts") {
                try db.execute(
                    sql: "DELETE FROM transcripts_fts WHERE guid = ?",
                    arguments: [guid]
                )
            }

            return priorPath
        }
    }

    /// Restores a transcript that ``clearTranscriptAndSkip(guid:)`` cleared: sets
    /// `transcript_path` back and returns the episode to its prior `status` (e.g.
    /// `"done"`). Used by ``TrashStore/restore(id:watchlistURL:)`` for the undo /
    /// „Wiederherstellen" path. The FTS row is re-inserted by the caller (it has
    /// the plain-text content); this only touches `episodes`.
    ///
    /// - Parameters:
    ///   - guid: The episode to restore.
    ///   - transcriptPath: The `transcript_path` value to put back (may be nil).
    ///   - status: The `status` to restore (the value the episode had pre-delete).
    func restoreTranscript(guid: String, transcriptPath: String?, status: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET status = ?, transcript_path = ? WHERE guid = ?",
                arguments: [status, transcriptPath, guid]
            )
        }
    }
}
