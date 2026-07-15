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
    public func applyBackfill(showSlug: String, policy: BackfillPolicy) throws -> (queued: Int, deferred: Int) {
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

        for guid in toQueue {
            try setStatus(guid: guid, .pending)
        }
        for guid in toDefer {
            try setStatus(guid: guid, .deferred)
        }

        Log.info("Backfill applied", component: "Backfill", context: [
            ("show", showSlug),
            ("mode", policy.mode.rawValue),
            ("queued", "\(toQueue.count)"),
            ("deferred", "\(toDefer.count)"),
        ])

        return (toQueue.count, toDefer.count)
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
