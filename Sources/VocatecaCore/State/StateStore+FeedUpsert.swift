import Foundation
import GRDB

// MARK: - NewEpisode

/// A newly-discovered episode returned from ``StateStore/upsertEpisodeFromFeed(showSlug:guid:title:pubDate:mp3URL:durationSec:)``
/// when the row did not previously exist in the database.
///
/// Callers (``FeedIngestor``, ``IngestCoordinator``) use this to decide whether
/// to create new-episode notifications.
public struct NewEpisode: Sendable, Equatable {
    public let guid: String
    public let title: String
    public init(guid: String, title: String) {
        self.guid = guid
        self.title = title
    }
}

// MARK: - Feed-refresh targeted upsert

extension StateStore {

    /// Upserts an episode discovered from a feed poll into the database,
    /// **preserving pipeline state on conflict**.
    ///
    /// This mirrors `core/state.py :: upsert_episode` EXACTLY:
    ///
    /// ```sql
    /// INSERT INTO episodes (guid, show_slug, title, pub_date, mp3_url,
    ///                       status, duration_sec)
    /// VALUES (?, ?, ?, ?, ?, 'pending', ?)
    /// ON CONFLICT(guid) DO UPDATE SET
    ///     title        = excluded.title,
    ///     pub_date     = excluded.pub_date,
    ///     mp3_url      = excluded.mp3_url,
    ///     duration_sec = COALESCE(excluded.duration_sec, episodes.duration_sec)
    /// ```
    ///
    /// On conflict the following columns are **not** touched:
    /// - `status`          — preserves "downloading", "transcribing", "done", etc.
    /// - `attempts`        — preserves failure/retry bookkeeping
    /// - `transcript_path` — preserves completed transcript path
    /// - `mp3_path`        — preserves the on-disk audio file path
    /// - `word_count`      — preserves measured word count
    /// - `completed_at`, `attempted_at`, `error_text`, `error_category`, …
    ///
    /// For `duration_sec`, `COALESCE(excluded.duration_sec, episodes.duration_sec)` means:
    /// - If the new feed value is non-nil, use it (update).
    /// - If the new feed value is nil, keep the existing DB value.
    ///
    /// - Parameters:
    ///   - showSlug:   The show the episode belongs to.
    ///   - guid:       The episode's unique feed identifier.
    ///   - title:      Episode title from the feed.
    ///   - pubDate:    Publication date from the feed (ISO-8601 string).
    ///   - mp3URL:     Audio URL from the feed.
    ///   - durationSec: Duration in seconds, or `nil` when the feed omits it.
    /// - Returns: A ``NewEpisode`` when the row was freshly inserted, `nil` on update-only conflict.
    /// - Throws: A GRDB error on database failure.
    /// - Parameter initialStatus: The status a **freshly inserted** row is born
    ///   with. Defaults to `.pending`. **L4 (Defer-TOCTOU):** the ingest caller
    ///   passes `.deferred` up front for auto-download-OFF shows so the episode is
    ///   NEVER transiently `pending` before a separate flip — closing the window in
    ///   which a concurrently-running drain (app foreground queue, the daemon, or a
    ///   `vocateca-cli queue run`) could claim it and ignore the auto-download-OFF
    ///   preference. On a CONFLICT (existing row) the status is left untouched, so
    ///   this never disturbs in-flight pipeline state (unchanged behaviour).
    ///   The value is a fixed `EpisodeStatus` enum, so its `rawValue` is a trusted
    ///   literal, not user input.
    @discardableResult
    public func upsertEpisodeFromFeed(
        showSlug: String,
        guid: String,
        title: String,
        pubDate: String,
        mp3URL: String,
        durationSec: Int?,
        initialStatus: EpisodeStatus = .pending
    ) throws -> NewEpisode? {
        // Use `changes` count after INSERT OR IGNORE to detect true inserts vs
        // conflicts, then run the ON CONFLICT UPDATE separately for updated fields.
        //
        // Strategy: INSERT OR IGNORE to test insertion; if rowsAffected == 1 the
        // row is new. Always run the UPDATE so metadata stays fresh on existing rows.
        var isNew = false
        // Tracks whether the conflict-path UPDATE actually changed a value, so
        // we can skip logging the (overwhelmingly common) no-op re-upsert —
        // every feed poll re-upserts EVERY episode of EVERY show, and most of
        // them are unchanged since the last poll. See P15.
        var didChange = false
        try dbQueue.write { db in
            // Step 1: try a pure insert (ignored on conflict). The status is bound
            // as a parameter (from the trusted EpisodeStatus enum) so a new row
            // lands in its FINAL state directly (L4) — no transient `pending`.
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO episodes
                        (guid, show_slug, title, pub_date, mp3_url, status, duration_sec)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [guid, showSlug, title, pubDate, mp3URL, initialStatus.rawValue, durationSec]
            )
            isNew = db.changesCount == 1

            // Step 2: on conflict, update mutable metadata (mirrors ON CONFLICT DO UPDATE).
            if !isNew {
                // Fetch the pre-update row so we can tell a genuine field change
                // (worth logging) from a re-upsert of identical data (noise).
                let old = try Row.fetchOne(db, sql: """
                    SELECT title, pub_date, mp3_url, duration_sec FROM episodes WHERE guid = ?
                    """, arguments: [guid])
                let oldTitle: String? = old?["title"]
                let oldPubDate: String? = old?["pub_date"]
                let oldMp3URL: String? = old?["mp3_url"]
                let oldDuration: Int? = old?["duration_sec"]
                // Mirrors the COALESCE(?, duration_sec) semantics below: a nil
                // feed value keeps the existing duration, so it's not a change.
                let effectiveDuration = durationSec ?? oldDuration
                didChange = oldTitle != title || oldPubDate != pubDate
                    || oldMp3URL != mp3URL || oldDuration != effectiveDuration

                try db.execute(
                    sql: """
                        UPDATE episodes SET
                            title        = ?,
                            pub_date     = ?,
                            mp3_url      = ?,
                            duration_sec = COALESCE(?, duration_sec)
                        WHERE guid = ?
                    """,
                    arguments: [title, pubDate, mp3URL, durationSec, guid]
                )
            }
        }
        // P15: only log a MEANINGFUL upsert — a fresh insert or an actual field
        // change. The overwhelming common case (re-upsert of an unchanged
        // episode on every feed poll) is silent; the per-poll aggregate in
        // `FeedIngestor` ("Podcast poll done … entries=N new=M existing=K")
        // already covers it.
        if isNew || didChange {
            Log.debug("DB upsert episode from feed", component: "StateStore",
                      context: [("guid", guid), ("show", showSlug), ("new", "\(isNew)")])
        }
        return isNew ? NewEpisode(guid: guid, title: title) : nil
    }

    // MARK: - enqueueFront

    /// Sets an episode to `pending` with maximum priority so that
    /// `claimNextPending` picks it up before all other pending episodes,
    /// regardless of `queueOrder`.
    ///
    /// Idempotent: safe to call on an episode already in a terminal state
    /// (it will be re-queued) or already in `pending` (priority is bumped).
    ///
    /// Implementation: writes `status = 'pending'` and a monotonic Unix-timestamp
    /// priority (`strftime('%s','now')`), not a fixed `Int.max` — see the note
    /// in the query below for why. Because all claim orderings start with
    /// `priority DESC`, the episode races to the top of the queue.
    ///
    /// - Parameter guid: The episode to prioritise.
    /// - Throws: A GRDB error if the database is not writable.
    public func enqueueFront(guid: String) throws {
        try dbQueue.write { db in
            // Use a monotonic Unix-timestamp priority (not a fixed Int.max): the
            // most-recently front-enqueued item gets the highest value, so it
            // truly jumps to the top even when several items were front-enqueued.
            // (A fixed Int.max left every front item tied → tie-broken by pub_date;
            // and MAX(priority)+1 would overflow Int64.) Regular episodes stay at
            // priority 0, so any front item (~1.7e9) still dominates them.
            try db.execute(
                sql: """
                    UPDATE episodes
                    SET status = 'pending',
                        priority = CAST(strftime('%s','now') AS INTEGER)
                    WHERE guid = ?
                """,
                arguments: [guid]
            )
        }
        Log.info("DB enqueueFront", component: "StateStore",
                 context: [("guid", guid)])
    }
}
