import XCTest
@testable import VocatecaCore

final class UpNextRankerTests: XCTestCase {
    func testRankIsDescendingAndAboveZero() {
        XCTAssertEqual(UpNextRanker.rank(count: 3), [1_000_002, 1_000_001, 1_000_000])
        XCTAssertEqual(UpNextRanker.rank(count: 0), [])
        let r = UpNextRanker.rank(count: 5)
        XCTAssertEqual(r, r.sorted(by: >))          // strictly descending (top first)
        XCTAssertTrue(r.allSatisfy { $0 > 0 })      // always above the Coming-up band (0)
    }

    func testLaneDerivation() {
        XCTAssertEqual(QueueLane.of(status: "transcribing", priority: 0), .nowTranscribing)
        XCTAssertEqual(QueueLane.of(status: "downloading",  priority: 9), .nowTranscribing)
        XCTAssertEqual(QueueLane.of(status: "pending", priority: 1_000_000), .upNext)
        XCTAssertEqual(QueueLane.of(status: "pending", priority: 0), .comingUp)
        XCTAssertEqual(QueueLane.of(status: "done", priority: 0), .comingUp) // non-active fall-through
    }
}
