import XCTest
@testable import VocatecaCore

final class BackfillCampaignStoreTests: XCTestCase {
    func testRoundTripAndAbsent() throws {
        let store = try StateStore.inMemory()
        let s = BackfillCampaignStore(store: store)
        XCTAssertNil(try s.read(slug: "x"))
        let c = BackfillCampaign(active: true, paused: false, batchSize: 3, scope: "all",
                                 scopeN: 0, scopeSince: "", total: 10, done: 0, startedAt: "t")
        try s.write(slug: "x", c)
        XCTAssertEqual(try s.read(slug: "x"), c)
    }
    func testDelete() throws {
        let store = try StateStore.inMemory()
        let s = BackfillCampaignStore(store: store)
        let c = BackfillCampaign(active: true, paused: false, batchSize: 3, scope: "all",
                                 scopeN: 0, scopeSince: "", total: 10, done: 0, startedAt: "t")
        try s.write(slug: "x", c)
        try s.delete(slug: "x")
        XCTAssertNil(try s.read(slug: "x"))
    }
}
