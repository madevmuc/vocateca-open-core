import XCTest
@testable import VocatecaCore

final class BackfillSeqAssignerTests: XCTestCase {
    private let batch: [(guid: String, pubDate: String)] = [
        (guid: "mid",  pubDate: "2024-06-01"),
        (guid: "old",  pubDate: "2023-01-01"),
        (guid: "new",  pubDate: "2025-01-01"),
    ]

    func testNewestFirstAssignsAscendingSeqToNewestPubDate() {
        let seq = BackfillSeqAssigner.assign(episodes: batch, order: "newest_first", base: 100)
        // Lower seq == drains first == newest pubDate under newest_first.
        XCTAssertLessThan(seq["new"]!, seq["mid"]!)
        XCTAssertLessThan(seq["mid"]!, seq["old"]!)
    }

    func testOldestFirstAssignsAscendingSeqToOldestPubDate() {
        let seq = BackfillSeqAssigner.assign(episodes: batch, order: "oldest_first", base: 100)
        XCTAssertLessThan(seq["old"]!, seq["mid"]!)
        XCTAssertLessThan(seq["mid"]!, seq["new"]!)
    }

    func testUnknownOrderFallsBackToNewestFirst() {
        let seq = BackfillSeqAssigner.assign(episodes: batch, order: "bogus", base: 0)
        XCTAssertLessThan(seq["new"]!, seq["old"]!)
    }

    func testValuesAreDenseFromBase() {
        let seq = BackfillSeqAssigner.assign(episodes: batch, order: "newest_first", base: 50)
        XCTAssertEqual(Set(seq.values), Set([50, 51, 52]))
    }

    func testEmptyBatchReturnsEmptyMap() {
        XCTAssertTrue(BackfillSeqAssigner.assign(episodes: [], order: "newest_first", base: 0).isEmpty)
    }
}
