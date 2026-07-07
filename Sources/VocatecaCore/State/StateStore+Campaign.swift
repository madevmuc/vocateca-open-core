import Foundation
import GRDB

// MARK: - StateStore+Campaign

/// Campaign-advancement primitives on `StateStore` — the DB-facing support
/// for `BackfillCampaignAdvancer`'s keep-K-in-flight top-up loop.
///
/// These replicate the small `(guid, pub_date, status) WHERE show_slug=?` +
/// `BackfillPolicy.inScopeGuids` scoping pattern used by `StateStore+Backfill`
/// (whose `scopedGuids` helper is `private` there) rather than reusing it.
extension StateStore {

    /// Show episodes currently occupying the queue (keep-K denominator) — a
    /// running campaign owns the show's in-flight activity.
    ///
    /// Counts ALL of the show's pending/downloading/downloaded/transcribing
    /// episodes, not only campaign-enqueued ones — a deliberate, self-correcting
    /// approximation of the keep-K denominator.
    public func campaignInFlightCount(showSlug: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM episodes
                WHERE show_slug = ? AND status IN ('pending','downloading','downloaded','transcribing')
            """, arguments: [showSlug]) ?? 0
        }
    }

    /// Scope-relative counts for progress + remaining work.
    public func campaignScopeCounts(showSlug: String, policy: BackfillPolicy) throws
        -> (deferredInScope: Int, transcribedInScope: Int, totalInScope: Int) {
        let rows: [(guid: String, pubDate: String, status: String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT guid, pub_date, status FROM episodes WHERE show_slug = ?",
                              arguments: [showSlug]).map {
                (guid: $0["guid"] as String, pubDate: ($0["pub_date"] as String?) ?? "", status: $0["status"] as String)
            }
        }
        let inScope = policy.inScopeGuids(episodes: rows.map { (guid: $0.guid, pubDate: $0.pubDate) })
        let scoped = rows.filter { inScope.contains($0.guid) }
        return (
            deferredInScope: scoped.filter { $0.status == "deferred" }.count,
            transcribedInScope: scoped.filter { $0.status == "done" }.count,
            totalInScope: scoped.count
        )
    }

    /// Up to `limit` of the show's in-scope `.deferred` guids, oldest `pub_date` first.
    public func oldestDeferredInScope(showSlug: String, policy: BackfillPolicy, limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        let rows: [(guid: String, pubDate: String, status: String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT guid, pub_date, status FROM episodes WHERE show_slug = ?",
                              arguments: [showSlug]).map {
                (guid: $0["guid"] as String, pubDate: ($0["pub_date"] as String?) ?? "", status: $0["status"] as String)
            }
        }
        let inScope = policy.inScopeGuids(episodes: rows.map { (guid: $0.guid, pubDate: $0.pubDate) })
        return rows.filter { $0.status == "deferred" && inScope.contains($0.guid) }
            .sorted { $0.pubDate < $1.pubDate }
            .prefix(limit).map(\.guid)
    }

    /// Un-defers episodes into Coming up (`pending`, priority unchanged = 0).
    /// Thin wrapper over `setStatus` for intent + logging.
    public func undeferToComingUp(guids: [String]) throws {
        for guid in guids { try setStatus(guid: guid, .pending) }
        if !guids.isEmpty {
            Log.info("Backfill: campaign advanced", component: "Backfill",
                     context: [("enqueued", "\(guids.count)")])
        }
    }
}
