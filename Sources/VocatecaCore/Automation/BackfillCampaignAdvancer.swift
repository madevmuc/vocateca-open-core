import Foundation

/// Advances active backfill campaigns one keep-K-in-flight top-up each. Called
/// from the maintenance-loop tick and on run-finished/queue-idle events.
public struct BackfillCampaignAdvancer: Sendable {
    private let store: StateStore
    private let campaignStore: BackfillCampaignStore
    /// Drain-order preference for this pass's top-up batches (`Settings.backfillOrder`).
    /// Defaults to the Settings default so every existing call site keeps compiling
    /// and behaving as newest-first (the default) without being touched.
    private let backfillOrder: String

    public init(store: StateStore, campaignStore: BackfillCampaignStore,
                backfillOrder: String = Settings.defaultBackfillOrder) {
        self.store = store; self.campaignStore = campaignStore; self.backfillOrder = backfillOrder
    }

    /// Advances every active, non-paused campaign whose show is in `shows`.
    /// Returns the slugs whose campaigns COMPLETED this pass (for the caller to
    /// retire the blob + seed a completion notification).
    @discardableResult
    public func advanceAll(shows: [Show]) -> [String] {
        var completed: [String] = []
        for show in shows {
            guard var campaign = (try? campaignStore.read(slug: show.slug)) ?? nil,
                  campaign.active, !campaign.paused else { continue }
            let policy = Self.policy(from: campaign)
            guard let counts = try? store.campaignScopeCounts(showSlug: show.slug, policy: policy),
                  let inFlight = try? store.campaignInFlightCount(showSlug: show.slug) else { continue }

            let n = BackfillPlanner.toEnqueue(
                batchSize: campaign.batchSize, activeCampaignCount: inFlight,
                remainingDeferred: counts.deferredInScope)
            if n > 0, let guids = try? store.oldestDeferredInScope(showSlug: show.slug, policy: policy, limit: n) {
                // Selection stays oldest-in-scope-first (unchanged) — only the
                // DRAIN order of this selected batch respects backfillOrder.
                let pubDates = (try? store.pubDates(guids: guids)) ?? [:]
                let episodesForSeq = guids.map { (guid: $0, pubDate: pubDates[$0] ?? "") }
                let base = (try? store.nextBackfillSeqBase()) ?? 1
                let seqMap = BackfillSeqAssigner.assign(episodes: episodesForSeq, order: backfillOrder, base: base)
                try? store.undeferToComingUp(guids: guids, backfillSeq: seqMap)
            }

            campaign.done = counts.transcribedInScope
            // Re-read steady state AFTER this pass's un-defer: the batch we just queued is
            // now `pending` and must count as in-flight — otherwise we'd retire the campaign
            // while its final batch is still processing. A campaign is complete only when
            // there is nothing left to enqueue (no in-scope deferred) AND nothing still
            // processing (no in-scope pending/in-flight).
            let deferredAfter = max(0, counts.deferredInScope - n)
            let inFlightAfter = (try? store.campaignInFlightCount(showSlug: show.slug)) ?? inFlight
            if deferredAfter == 0 && inFlightAfter == 0 {
                campaign.active = false
                try? campaignStore.write(slug: show.slug, campaign)   // persist final state before retire
                completed.append(show.slug)
                Log.info("Backfill: campaign completed", component: "Backfill",
                         context: [("slug", show.slug), ("done", "\(campaign.done)"), ("total", "\(campaign.total)")])
            } else {
                try? campaignStore.write(slug: show.slug, campaign)
            }
        }
        return completed
    }

    /// Reconstructs the scope policy from the stored campaign fields.
    private static func policy(from c: BackfillCampaign) -> BackfillPolicy {
        BackfillPolicy(mode: BackfillMode(rawValue: c.scope) ?? .all, n: c.scopeN, sinceDate: c.scopeSince, subscribedAt: "")
    }
}
