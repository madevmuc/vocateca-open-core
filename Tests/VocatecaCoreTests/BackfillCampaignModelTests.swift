import XCTest
@testable import VocatecaCore

final class BackfillCampaignModelTests: XCTestCase {
    func testToEnqueueTopsUpToBatch() {
        XCTAssertEqual(BackfillPlanner.toEnqueue(batchSize: 3, activeCampaignCount: 1, remainingDeferred: 10), 2)
    }
    func testToEnqueueClampsToRemaining() {
        XCTAssertEqual(BackfillPlanner.toEnqueue(batchSize: 5, activeCampaignCount: 0, remainingDeferred: 2), 2)
    }
    func testToEnqueueNeverNegative() {
        XCTAssertEqual(BackfillPlanner.toEnqueue(batchSize: 3, activeCampaignCount: 5, remainingDeferred: 10), 0)
    }
    func testToEnqueueZeroRemaining() {
        XCTAssertEqual(BackfillPlanner.toEnqueue(batchSize: 3, activeCampaignCount: 0, remainingDeferred: 0), 0)
    }
    func testMetaKey() {
        XCTAssertEqual(BackfillCampaign.metaKey(slug: "abc"), "backfill_campaign:abc")
    }
    func testRoundTrip() throws {
        let c = BackfillCampaign(active: true, paused: false, batchSize: 3, scope: "all",
                                 scopeN: 0, scopeSince: "", total: 42, done: 7, startedAt: "2026-07-03T00:00:00.000Z")
        let json = try XCTUnwrap(c.encoded())
        XCTAssertEqual(BackfillCampaign.decode(json), c)
    }
}
