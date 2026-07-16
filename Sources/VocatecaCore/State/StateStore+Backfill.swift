import Foundation
import GRDB

// MARK: - StateStore+Backfill

/// Applies a unified ``BackfillPolicy`` against the `episodes` table for one
/// show — the DB-facing counterpart to the pure `BackfillPolicy.inScopeGuids`
/// scope logic.
///
/// Only `pending` ⇄ `deferred` rows are ever touched. Terminal / in-flight
/// statuses (`done`, `downloading`, `transcribing`, `failed`, `skipped`,
/// `stale`, `paused`) are never modified — a policy change narrows or widens
/// the *queue*, it never un-does work already performed or in progress.
extension StateStore {

    // MARK: - backfillPreview (dry-run)

    /// Dry-run: computes how many `pending`/`deferred` episodes for `showSlug`
    /// the policy would newly queue (deferred → pending) vs. newly defer
    /// (pending → deferred), **without modifying the DB**.
    ///
    /// - Parameters:
    ///   - showSlug: The show to preview.
    ///   - policy: The candidate policy (not necessarily the one currently
    ///     stored on the show — callers preview edits before saving).
    /// - Returns: `(willQueue, willDefer)` counts.
    public func backfillPreview(showSlug: String, policy: BackfillPolicy) throws -> (willQueue: Int, willDefer: Int) {
        let (inScope, outOfScope) = try scopedGuids(showSlug: showSlug, policy: policy)
        return try dbQueue.read { db in
            let willQueue = try Int.fetchOne(db, SQLRequest(sql: """
                SELECT COUNT(*) FROM episodes
                WHERE show_slug = ? AND status = 'deferred' AND guid IN (\(placeholders(inScope.count)))
            """, arguments: StatementArguments([showSlug] + Array(inScope)))) ?? 0

            let willDefer = try Int.fetchOne(db, SQLRequest(sql: """
                SELECT COUNT(*) FROM episodes
                WHERE show_slug = ? AND status = 'pending' AND guid IN (\(placeholders(outOfScope.count)))
            """, arguments: StatementArguments([showSlug] + Array(outOfScope)))) ?? 0

            return (willQueue, willDefer)
        }
    }

    // MARK: - applyBackfill

    /// Applies `policy` to `showSlug`'s episodes:
    /// - in-scope + currently `deferred` → `pending`
    /// - out-of-scope + currently `pending` → `deferred`
    ///
    /// Never touches `done`/`downloading`/`transcribing`/`failed`/`skipped`/
    /// `stale`/`paused` rows. Uses `setStatus` for each transitioned row so
    /// the usual lifecycle event (`episode.deferred` has one; `pending` does
    /// not) and timestamp bookkeeping stay consistent with every other status
    /// transition in the app.
    ///
    /// - Returns: `(queued, deferred)` — the actual counts transitioned.
    @discardableResult
    /// - Parameter backfillOrder: `Settings.backfillOrder` — the order the
    ///   promoted batch should DRAIN in. Without this, promoted rows had a NULL
    ///   `backfill_seq` and fell through to the live `queueOrder` (default
    ///   `oldest_first`), so "backfill all" queued oldest-first even though the
    ///   user's `backfill_order` was `newest_first`. Now the batch is stamped
    ///   with `backfill_seq` (via ``BackfillSeqAssigner``), exactly like the
    ///   campaign path (``BackfillCampaignAdvancer``), so both backfill routes
    ///   honour `backfill_order`.
    public func applyBackfill(
        showSlug: String,
        policy: BackfillPolicy,
        backfillOrder: String = Settings.defaultBackfillOrder
    ) throws -> (queued: Int, deferred: Int) {
        let (inScope, outOfScope) = try scopedGuids(showSlug: showSlug, policy: policy)

        let toQueue: [String] = try dbQueue.read { db in
            try String.fetchAll(db, SQLRequest(sql: """
                SELECT guid FROM episodes
                WHERE show_slug = ? AND status = 'deferred' AND guid IN (\(placeholders(inScope.count)))
            """, arguments: StatementArguments([showSlug] + Array(inScope))))
        }
        let toDefer: [String] = try dbQueue.read { db in
            try String.fetchAll(db, SQLRequest(sql: """
                SELECT guid FROM episodes
                WHERE show_slug = ? AND status = 'pending' AND guid IN (\(placeholders(outOfScope.count)))
            """, arguments: StatementArguments([showSlug] + Array(outOfScope))))
        }

        // Promote the in-scope deferred episodes to Coming up, stamping each with
        // a `backfill_seq` so the batch drains in `backfillOrder` (newest_first
        // default) rather than the live `queueOrder`. Mirrors the campaign path.
        if !toQueue.isEmpty {
            let pubDatesByGuid = (try? pubDates(guids: toQueue)) ?? [:]
            let episodesForSeq = toQueue.map { (guid: $0, pubDate: pubDatesByGuid[$0] ?? "") }
            let base = (try? nextBackfillSeqBase()) ?? 1
            let seqMap = BackfillSeqAssigner.assign(episodes: episodesForSeq, order: backfillOrder, base: base)
            try undeferToComingUp(guids: toQueue, backfillSeq: seqMap)
        }
        for guid in toDefer {
            try setStatus(guid: guid, .deferred)
        }

        Log.info("Backfill applied", component: "Backfill", context: [
            ("show", showSlug),
            ("mode", policy.mode.rawValue),
            ("order", backfillOrder),
            ("queued", "\(toQueue.count)"),
            ("deferred", "\(toDefer.count)"),
        ])

        // "Queue the last 10" that queues nothing because the show has no episodes
        // at all is not a successful backfill — it means the feed was never polled
        // (see the FeedIngestor backoff deadlock). It read as an INFO success in
        // the log while the user sat in front of an empty show wondering what
        // happened (incident 2026-07-16). Say so.
        if toQueue.isEmpty, toDefer.isEmpty, (try? episodeCountForBackfillWarning(showSlug: showSlug)) == 0 {
            Log.warn("Backfill queued nothing — the show has no episodes yet (feed not polled?)",
                     component: "Backfill",
                     context: [("show", showSlug), ("mode", policy.mode.rawValue)])
        }

        return (toQueue.count, toDefer.count)
    }

    /// Total episodes on record for `showSlug`, regardless of status. Used only to
    /// tell "backfill queued nothing because everything is already queued" apart
    /// from "backfill queued nothing because there is nothing" — the latter means
    /// the feed never got polled and deserves a warning.
    private func episodeCountForBackfillWarning(showSlug: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, SQLRequest(
                sql: "SELECT COUNT(*) FROM episodes WHERE show_slug = ?",
                arguments: [showSlug])) ?? 0
        }
    }

    /// Guids currently `pending` for a show (newest first, any priority).
    ///
    /// On an INITIAL subscribe these are exactly the episodes `applyBackfill`
    /// just promoted from `deferred` (everything else was seeded `deferred`), so
    /// it is the set to auto-enqueue + start right after a subscribe.
    public func pendingGuids(showSlug: String) throws -> [String] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT guid FROM episodes
                WHERE show_slug = ? AND status = 'pending'
                ORDER BY pub_date DESC
            """, arguments: [showSlug]).map { $0["guid"] as String }
        }
    }

    // MARK: - Private helpers

    /// Fetches every `(guid, pubDate)` for `showSlug` and partitions them into
    /// in-scope / out-of-scope guid sets via `BackfillPolicy.inScopeGuids`.
    private func scopedGuids(showSlug: String, policy: BackfillPolicy) throws -> (inScope: Set<String>, outOfScope: Set<String>) {
        let rows: [(guid: String, pubDate: String)] = try dbQueue.read { db in
            let raw = try Row.fetchAll(db, SQLRequest(sql: """
                SELECT guid, pub_date FROM episodes WHERE show_slug = ?
            """, arguments: [showSlug]))
            return raw.map { row in
                (guid: row["guid"] as String, pubDate: (row["pub_date"] as String?) ?? "")
            }
        }
        let inScope = policy.inScopeGuids(episodes: rows)
        let outOfScope = Set(rows.map(\.guid)).subtracting(inScope)
        return (inScope, outOfScope)
    }

    /// Builds a `(?, ?, …)`-style placeholder list for `count` items. Returns
    /// `"(NULL)"` (matches nothing, valid SQL) when `count == 0` so callers
    /// never need to special-case an empty IN-list.
    private func placeholders(_ count: Int) -> String {
        guard count > 0 else { return "NULL" }
        return Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
