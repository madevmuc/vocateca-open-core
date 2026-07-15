import Foundation
import GRDB

// MARK: - Worker primitives on StateStore

/// Pipeline-worker extensions for `StateStore`.
///
/// These methods mirror the Python equivalents in `core/state.py` that the
/// queue-worker and pipeline call to drive status transitions, claim pending
/// episodes, and record failures.
extension StateStore {

    // MARK: - setStatus

    /// Updates the `status` column for `guid`, sets ancillary timestamp /
    /// error columns (matching Python `StateStore.set_status`), and emits the
    /// corresponding lifecycle event (if any) via `appendEvent`.
    ///
    /// Column update behaviour mirrors Python exactly:
    /// - `done`         → clears `error_text`, `error_category`, `attempts`; sets `completed_at`.
    /// - `downloading`  → sets `attempted_at`.
    /// - `transcribing` → sets `attempted_at`.
    /// - `failed`       → stores `error_text`.
    /// - all others     → only `status` column updated.
    ///
    /// Lifecycle events are appended for statuses in `EpisodeStatus.lifecycleEventType`;
    /// `pending`, `stale`, and `paused` transitions are silent.
    /// Returns the lifecycle `Event` that was persisted (or `nil` when the status
    /// has no lifecycle event), so the worker layer can also emit it on the
    /// `EventBus` — the DB write is unchanged. `@discardableResult` keeps existing
    /// callers that ignore the return unaffected.
    @discardableResult
    public func setStatus(
        guid: String,
        _ status: EpisodeStatus,
        errorText: String? = nil,
        transcriptPath: String? = nil,
        transcriptOrigin: String? = nil
    ) throws -> Event? {
        let now = Event.nowISO()

        // Fetch show_slug + title for the event payload ONLY when we need an event.
        // Mirrors Python's "only fetch the payload row for statuses that actually emit an event".
        var showSlug: String? = nil
        var title: String? = nil
        var detectedLanguage: String? = nil
        let emitsEvent = status.lifecycleEventType != nil

        try dbQueue.write { db in
            switch status {
            case .done:
                // Success clears failure bookkeeping so a later transient failure
                // gets its full retry budget (mirrors Python set_status for DONE).
                // Also persist the written transcript's absolute path so the Library
                // can resolve it authoritatively (COALESCE keeps any existing path
                // when the caller passes nil, e.g. a re-set of an already-done row).
                try db.execute(
                    sql: """
                        UPDATE episodes
                        SET status = ?, completed_at = ?,
                            error_text = NULL, error_category = NULL, attempts = 0,
                            transcript_path = COALESCE(?, transcript_path),
                            transcript_origin = COALESCE(?, transcript_origin)
                        WHERE guid = ?
                    """,
                    arguments: [status.rawValue, now, transcriptPath, transcriptOrigin, guid]
                )
            case .downloading, .transcribing:
                try db.execute(
                    sql: "UPDATE episodes SET status = ?, attempted_at = ? WHERE guid = ?",
                    arguments: [status.rawValue, now, guid]
                )
            case .failed, .skipped:
                // .skipped stores an optional reason (e.g. "No speech detected —
                // likely music"); other skip paths pass nil, which clears it.
                try db.execute(
                    sql: "UPDATE episodes SET status = ?, error_text = ? WHERE guid = ?",
                    arguments: [status.rawValue, errorText, guid]
                )
            default:
                try db.execute(
                    sql: "UPDATE episodes SET status = ? WHERE guid = ?",
                    arguments: [status.rawValue, guid]
                )
            }

            if emitsEvent {
                let row = try Row.fetchOne(
                    db,
                    SQLRequest(sql: "SELECT show_slug, title, detected_language FROM episodes WHERE guid = ?",
                               arguments: [guid])
                )
                showSlug = row?["show_slug"]
                title    = row?["title"]
                detectedLanguage = row?["detected_language"]
            }
        }

        // Emit lifecycle event outside the write transaction (mirrors Python post-commit emit).
        if emitsEvent, let eventType = status.lifecycleEventType {
            var payload: [String: JSONValue] = [:]
            if let t = title, !t.isEmpty { payload["title"] = .string(t) }
            if let et = errorText, !et.isEmpty { payload["error_text"] = .string(et) }
            // Python includes detected_language in the DONE (episode.transcribed) payload.
            if status == .done, let lang = detectedLanguage, !lang.isEmpty {
                payload["detected_language"] = .string(lang)
            }

            let event = Event(type: eventType, showSlug: showSlug, guid: guid, payload: payload)
            try appendEvent(
                type: eventType,
                showSlug: showSlug,
                guid: guid,
                payloadJSON: event.payloadJSONString()
            )
            return event
        }
        return nil
    }

    // MARK: - claimNextPending

    /// **Atomically** claims the next `pending` episode according to `queueOrder`,
    /// flipping its status to `downloading` and returning the claimed row — or
    /// `nil` when the queue is empty.
    ///
    /// The claim runs as a single `UPDATE … WHERE guid = (SELECT … LIMIT 1)
    /// RETURNING *` inside one write transaction, mirroring Python's
    /// `claim_one_pending`. This is what lets multiple concurrent workers (or a
    /// concurrency-capped `TaskGroup` drain loop) call this **without
    /// double-claiming** the same row: the second caller no longer sees the row
    /// as `pending`. (A bare SELECT-then-flip-later would race — the row would be
    /// returned twice before the first processor set its status.)
    ///
    /// Claim ordering mirrors Python's `_QUEUE_ORDERS` map (validated, never raw
    /// user input):
    ///
    /// | `queueOrder`     | SQL ORDER BY                                       |
    /// |------------------|----------------------------------------------------|
    /// | `oldest_first`   | `priority DESC, pub_date ASC`                      |
    /// | `newest_first`   | `priority DESC, pub_date DESC`                     |
    /// | `shortest_first` | `priority DESC, (duration_sec IS NULL), duration_sec ASC` |
    /// | *(unknown)*      | falls back to `oldest_first`                       |
    ///
    /// The claimed episode is returned already in `downloading` state; the
    /// pipeline's `setStatus(.downloading)` is then an idempotent re-set that
    /// emits the `episode.download_started` lifecycle event exactly once.
    /// (Episodes left in `downloading` by a crash need a startup recovery sweep,
    /// same as the Python app — out of scope here.)
    ///
    /// Returns `nil` when the queue is empty.
    ///
    /// - Parameters:
    ///   - queueOrder: Queue ordering preference (`oldest_first`, `newest_first`,
    ///     `shortest_first`). Validated against a whitelist — never raw SQL.
    ///   - restrictToSlugs: Optional allowlist of show slugs.
    ///     - `nil` or `[]` → claim any pending episode (unchanged legacy behaviour).
    ///     - non-empty array → only claim episodes whose `show_slug` is in the set.
    ///   - excludeSlugs: Optional denylist of show slugs (QA item 9 — "pausing a
    ///     show pauses its episodes"). `nil`/`[]` → no exclusion. A non-empty array
    ///     skips episodes of those shows entirely, WITHOUT touching their `pending`
    ///     status — re-enabling monitoring makes them claimable again on the very
    ///     next claim with no data migration. Orthogonal to `restrictToSlugs`
    ///     (both may be supplied; a slug excluded here is skipped even if it would
    ///     otherwise match the allowlist).
    ///
    /// The nil/empty-array == claim-all convention keeps call sites simple: the
    /// daemon guards on `!enabled.isEmpty` before calling, so an empty array
    /// arriving here is treated as "no restriction" rather than "claim nothing"
    /// (which would be surprising and hard to debug).
    /// Retry-backoff window (seconds). M1 — after a transient failure the Pipeline
    /// resets the row to `pending` with a *recent* `attempted_at` (set on every
    /// `.downloading`/`.transcribing` transition); without a backoff the claim loop
    /// re-picks it in the same second and burns all 3 attempts in a few seconds, so
    /// a 30 s WLAN blip fails the whole queue. Claiming skips rows attempted within
    /// this window; the predicate is time-based (not a permanent exclusion) so the
    /// loop resumes claiming the row the instant the window elapses — it never
    /// deadlocks the drain. A never-attempted row (`attempted_at IS NULL`) is always
    /// eligible. 60 s comfortably outlasts a transient network hiccup.
    public static let retryBackoffSeconds: TimeInterval = 60

    public func claimNextPending(
        queueOrder: String,
        restrictToSlugs: [String]? = nil,
        excludeSlugs: [String]? = nil,
        backoffSeconds: TimeInterval = StateStore.retryBackoffSeconds,
        now: Date = Date()
    ) throws -> Episode? {
        let orderFragment = Self.claimOrderByFragment(queueOrder)
        // Backfill-aware tier (feature D): campaign top-up batches carry a
        // non-null `backfill_seq` (see `BackfillSeqAssigner`) recording their
        // batch drain order under `Settings.backfillOrder`, independent of the
        // live `queueOrder`. Rows with a `backfill_seq` sort ahead of any
        // priority-0 tie, ordered by that value; rows without one (every
        // live/non-backfill row — the common case) fall straight through to
        // the UNTOUCHED, oracle-locked `orderFragment` below. When no row in
        // the table has `backfill_seq` set, both extra tiers are a complete
        // no-op for every pairwise comparison and the query degenerates to
        // exactly `orderFragment` (see `testLiveOnlyQueueOrderUnchanged`).
        let backfillTier = "(backfill_seq IS NULL), backfill_seq ASC"
        let nowISO = Event.nowISO()
        // Backoff cutoff: rows whose `attempted_at` is >= this are still "hot" and
        // are skipped this pass. Computed from the injected `now` so tests can
        // exercise the predicate deterministically.
        let cutoffISO = Event.iso(from: now.addingTimeInterval(-backoffSeconds))

        // Build an optional WHERE clause extension for slug scoping.
        // When restrictToSlugs is nil or empty, no extra predicate is added.
        // When non-empty, we emit `AND show_slug IN (?, ?, …)` with one
        // placeholder per slug — fully parameterised, never string-interpolated.
        let slugs = restrictToSlugs.flatMap { $0.isEmpty ? nil : $0 }  // nil if empty
        let slugFilter: String
        let slugArguments: [DatabaseValue]
        if let slugs = slugs {
            let placeholders = Array(repeating: "?", count: slugs.count).joined(separator: ", ")
            slugFilter = "AND show_slug IN (\(placeholders))"
            slugArguments = slugs.map { $0.databaseValue }
            Log.debug("claimNextPending: scoped to \(slugs.count) show(s)",
                      component: "StateStore",
                      context: [("slugs", slugs.joined(separator: ","))])
        } else {
            slugFilter = ""
            slugArguments = []
            Log.debug("claimNextPending: unscoped (claim any pending)",
                      component: "StateStore")
        }

        // QA item 9 — paused-show guard: an EXCLUDE denylist, orthogonal to the
        // INCLUDE allowlist above. `AND show_slug NOT IN (?, ?, …)`, fully
        // parameterised. Rows for a paused show simply never match this claim —
        // they stay `pending` untouched, so re-enabling monitoring needs no
        // migration or backfill, just lets the very next claim see them again.
        let excluded = excludeSlugs.flatMap { $0.isEmpty ? nil : $0 }
        let excludeFilter: String
        let excludeArguments: [DatabaseValue]
        if let excluded {
            let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ", ")
            excludeFilter = "AND show_slug NOT IN (\(placeholders))"
            excludeArguments = excluded.map { $0.databaseValue }
            Log.debug("claimNextPending: excluding \(excluded.count) paused show(s)",
                      component: "StateStore",
                      context: [("slugs", excluded.joined(separator: ","))])
        } else {
            excludeFilter = ""
            excludeArguments = []
        }

        return try dbQueue.write { db in
            // Atomic claim: flip exactly one pending row to downloading and
            // return it. The ORDER BY fragment is whitelisted (never raw input).
            // The slug filter (if any) is fully parameterised.
            //
            // M1 backoff: also require the row to be OUTSIDE the retry-backoff
            // window — either never attempted (`attempted_at IS NULL`) or last
            // attempted before `cutoffISO` (now − backoff). This is a *time*
            // predicate, so it can never wedge the drain: once the window elapses
            // the same row satisfies it and is claimed. `attempted_at`/`cutoffISO`
            // share `Event`'s byte-identical `+00:00` UTC format, so the string
            // comparison is a valid chronological comparison.
            let sql = """
                UPDATE episodes
                SET status = 'downloading', attempted_at = ?
                WHERE guid = (
                    SELECT guid FROM episodes
                    WHERE status = 'pending'
                    AND (attempted_at IS NULL OR attempted_at < ?)
                    \(slugFilter)
                    \(excludeFilter)
                    ORDER BY priority DESC, \(backfillTier), \(orderFragment)
                    LIMIT 1
                )
                RETURNING *
            """
            // Build arguments: [nowISO (SET)] + [cutoffISO (backoff)] + optional slug values.
            var args: [DatabaseValue] = [nowISO.databaseValue, cutoffISO.databaseValue]
            args.append(contentsOf: slugArguments)
            args.append(contentsOf: excludeArguments)
            return try Episode.fetchOne(db, SQLRequest(sql: sql, arguments: StatementArguments(args)))
        }
    }

    /// Returns the whitelisted ORDER BY fragment for a `queueOrder` value.
    /// Falls back to `oldest_first` for any unknown value, matching Python.
    public static func claimOrderByFragment(_ queueOrder: String) -> String {
        switch queueOrder {
        case "oldest_first":
            return "priority DESC, pub_date ASC"
        case "newest_first":
            return "priority DESC, pub_date DESC"
        case "shortest_first":
            // Mirrors Python: `(duration_sec IS NULL)` sorts NULLs last
            // (SQLite: NULL IS NULL → 1/true → sorts after 0/false).
            return "priority DESC, (duration_sec IS NULL), duration_sec ASC"
        default:
            return "priority DESC, pub_date ASC"
        }
    }

    // MARK: - recordFailure

    /// Records a failure for `guid`: increments `attempts`, stores `errorCategory`,
    /// and sets status to `pending` (when `retry` is true) or `failed`.
    ///
    /// Mirrors Python `StateStore.record_failure`:
    /// - atomically bumps `attempts` in the DB
    /// - calls `set_status(PENDING)` or `set_status(FAILED, error_text=...)` which
    ///   emits the matching lifecycle event
    /// - returns the new attempt count
    ///
    /// - Parameters:
    ///   - guid: Episode identifier.
    ///   - errorText: Human-readable error description (stored on FAILED only).
    ///   - errorCategory: Category string (e.g. "network", "disk") — see Python `core/errors.py`.
    ///   - retry: When `true` → set status back to `pending` (transient retry).
    ///            When `false` → set status to `failed` (permanent failure).
    /// - Returns: The new attempt count after incrementing.
    @discardableResult
    public func recordFailure(
        guid: String,
        errorText: String,
        errorCategory: String,
        retry: Bool
    ) throws -> Int {
        var newAttempts: Int = 1

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE episodes
                    SET attempts = COALESCE(attempts, 0) + 1,
                        error_category = ?
                    WHERE guid = ?
                """,
                arguments: [errorCategory, guid]
            )
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT attempts FROM episodes WHERE guid = ?",
                           arguments: [guid])
            )
            newAttempts = row?["attempts"] ?? 1
        }

        if retry {
            try setStatus(guid: guid, .pending)
        } else {
            try setStatus(guid: guid, .failed, errorText: errorText)
        }

        return newAttempts
    }

    // MARK: - clearAttemptedAt

    /// Nulls `attempted_at` for `guid`. Used by the pipeline's *cancellation*
    /// requeue (Stop / pause / mode switch) so the M1 retry-backoff — which keys
    /// off a recent `attempted_at` — does NOT delay re-claiming an episode the user
    /// interrupted. Cancellation is not a failure, so it should resume instantly; a
    /// genuine transient failure keeps its `attempted_at` and is held back. No-op
    /// on a missing guid.
    public func clearAttemptedAt(guid: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET attempted_at = NULL WHERE guid = ?",
                arguments: [guid])
        }
    }

}
