import XCTest
@testable import VocatecaCore

final class BackfillAdvanceTests: XCTestCase {
    /// Seeds `n` deferred episodes for a show, oldest-first pub dates.
    private func seedDeferred(_ s: StateStore, slug: String, n: Int) throws {
        for i in 0..<n {
            let guid = "\(slug)-\(i)"
            _ = try s.upsertEpisodeFromFeed(showSlug: slug, guid: guid, title: guid,
                pubDate: String(format: "2020-01-%02d", i + 1), mp3URL: "https://x/\(guid).mp3", durationSec: nil)
            _ = try s.setStatus(guid: guid, .deferred)
        }
    }

    func testFirstAdvanceEnqueuesBatch() throws {
        let store = try StateStore.inMemory()
        try seedDeferred(store, slug: "sh", n: 10)
        let cs = BackfillCampaignStore(store: store)
        let policyAll = BackfillPolicy(mode: .all, n: 0, sinceDate: "", subscribedAt: "")
        let total = try store.campaignScopeCounts(showSlug: "sh", policy: policyAll).deferredInScope
        try cs.write(slug: "sh", BackfillCampaign(active: true, paused: false, batchSize: 3,
            scope: "all", scopeN: 0, scopeSince: "", total: total, done: 0, startedAt: "t"))

        let adv = BackfillCampaignAdvancer(store: store, campaignStore: cs)
        _ = adv.advanceAll(shows: [Show(slug: "sh", title: "SH", rss: "https://x/f")])

        // Exactly batchSize (3) oldest episodes were un-deferred to pending.
        let pending = try store.campaignInFlightCount(showSlug: "sh")
        XCTAssertEqual(pending, 3)
    }

    func testPausedCampaignDoesNotAdvance() throws {
        let store = try StateStore.inMemory()
        try seedDeferred(store, slug: "sh", n: 5)
        let cs = BackfillCampaignStore(store: store)
        try cs.write(slug: "sh", BackfillCampaign(active: true, paused: true, batchSize: 3,
            scope: "all", scopeN: 0, scopeSince: "", total: 5, done: 0, startedAt: "t"))
        let adv = BackfillCampaignAdvancer(store: store, campaignStore: cs)
        _ = adv.advanceAll(shows: [Show(slug: "sh", title: "SH", rss: "https://x/f")])
        XCTAssertEqual(try store.campaignInFlightCount(showSlug: "sh"), 0)
    }

    /// Regression test: a campaign's final batch must not be marked "completed"
    /// while those episodes are still only `pending` (queued, not transcribed).
    /// Completion requires BOTH nothing deferred left AND nothing in-flight,
    /// using a POST-batch in-flight read — not the stale pre-batch count.
    func testDoesNotCompleteWhileFinalBatchPending() throws {
        let store = try StateStore.inMemory()
        try seedDeferred(store, slug: "sh", n: 3)
        let cs = BackfillCampaignStore(store: store)
        let policy = BackfillPolicy(mode: .all, n: 0, sinceDate: "", subscribedAt: "")
        let total = try store.campaignScopeCounts(showSlug: "sh", policy: policy).totalInScope
        try cs.write(slug: "sh", BackfillCampaign(active: true, paused: false, batchSize: 3,
            scope: "all", scopeN: 0, scopeSince: "", total: total, done: 0, startedAt: "t"))
        let adv = BackfillCampaignAdvancer(store: store, campaignStore: cs)
        let show = Show(slug: "sh", title: "SH", rss: "https://x/f")

        // First advance: all 3 un-deferred to pending. Campaign must NOT be complete.
        let completed1 = adv.advanceAll(shows: [show])
        XCTAssertFalse(completed1.contains("sh"))
        XCTAssertEqual(try cs.read(slug: "sh")?.active, true)
        XCTAssertEqual(try store.campaignInFlightCount(showSlug: "sh"), 3)

        // Simulate the 3 finishing transcription.
        for i in 0..<3 { _ = try store.setStatus(guid: "sh-\(i)", .done) }

        // Next advance: nothing deferred, nothing in-flight → now complete.
        let completed2 = adv.advanceAll(shows: [show])
        XCTAssertTrue(completed2.contains("sh"))
        XCTAssertEqual(try cs.read(slug: "sh")?.active, false)
    }
}
