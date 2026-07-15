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

    /// `pub_date` for each of `guids` that still exists, keyed by guid. Used by
    /// the backfill-seq assignment step, which needs pubDates for a batch
    /// `oldestDeferredInScope` already selected by guid only.
    public func pubDates(guids: [String]) throws -> [String: String] {
        guard !guids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ", ")
            let rows = try Row.fetchAll(db, SQLRequest(
                sql: "SELECT guid, pub_date FROM episodes WHERE guid IN (\(placeholders))",
                arguments: StatementArguments(guids)))
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["guid"] as String, ($0["pub_date"] as String?) ?? "")
            })
        }
    }

    /// Next strictly-increasing `backfill_seq` base: `MAX(backfill_seq)+1` (0
    /// when no row has one yet). Guarantees two different backfill batches —
    /// different shows, or the same show's next top-up tick — never collide,
    /// and an earlier-promoted batch always fully drains before a later one.
    public func nextBackfillSeqBase() throws -> Int {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT MAX(backfill_seq) AS m FROM episodes")
            let maxSeq = (row?["m"] as Int?) ?? 0
            return maxSeq + 1
        }
    }

    /// Un-defers episodes into Coming up (`pending`, priority unchanged = 0),
    /// optionally stamping each with a `backfill_seq` (see `BackfillSeqAssigner`)
    /// so the batch drains in `backfillOrder` without touching the live
    /// (non-backfill) claim comparator. `backfillSeq` missing an entry for a
    /// guid leaves that row's `backfill_seq` untouched (nil for a fresh promote).
    public func undeferToComingUp(guids: [String], backfillSeq: [String: Int] = [:]) throws {
        for guid in guids {
            try setStatus(guid: guid, .pending)
            if let seq = backfillSeq[guid] {
                try dbQueue.write { db in
                    try db.execute(sql: "UPDATE episodes SET backfill_seq = ? WHERE guid = ?",
                                    arguments: [seq, guid])
                }
            }
        }
        if !guids.isEmpty {
            Log.info("Backfill: campaign advanced", component: "Backfill",
                     context: [("enqueued", "\(guids.count)"),
                                ("withSeq", "\(backfillSeq.count)")])
        }
    }
}
