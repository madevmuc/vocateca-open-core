import Foundation

/// Assigns dense, ascending `backfill_seq` values to a batch of episodes being
/// promoted from `.deferred` to `.pending` (Coming-up, priority 0) by
/// `BackfillCampaignAdvancer`.
///
/// Lower `backfill_seq` == claimed earlier == drains first (see
/// `StateStore.claimNextPending`'s backfill-aware ORDER BY tier). Pure and
/// I/O-free so the ordering logic is directly unit-testable without a DB.
///
/// `base` must be a value that keeps separate batches (different shows, or the
/// same show's next top-up tick) from colliding — callers pass
/// `StateStore.nextBackfillSeqBase()` (`MAX(backfill_seq)+1`), so an EARLIER
/// batch always fully drains before a LATER one, preserving the order batches
/// were promoted in across shows/ticks.
public enum BackfillSeqAssigner {
    public static func assign(
        episodes: [(guid: String, pubDate: String)],
        order: String,
        base: Int
    ) -> [String: Int] {
        guard !episodes.isEmpty else { return [:] }
        let sorted: [(guid: String, pubDate: String)]
        switch order {
        case "oldest_first":
            sorted = episodes.sorted { $0.pubDate < $1.pubDate }
        default:
            // "newest_first" and any unrecognised value fall back to the
            // Settings default (newest_first) — never throws on a stale/typo'd
            // settings.yaml value.
            sorted = episodes.sorted { $0.pubDate > $1.pubDate }
        }
        var result: [String: Int] = [:]
        for (offset, ep) in sorted.enumerated() {
            result[ep.guid] = base + offset
        }
        return result
    }
}
