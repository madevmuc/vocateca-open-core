import XCTest
@testable import VocatecaCore

final class BatchEntryTests: XCTestCase {
    func testDefaultsToSelected() {
        let e = BatchEntry(url: "https://youtu.be/abc", title: "T", kind: .youtube)
        XCTAssertTrue(e.selected)
        XCTAssertEqual(e.id, "https://youtu.be/abc")
    }
    func testDeduplicatedByURLKeepsFirstOccurrence() {
        let entries = [
            BatchEntry(url: "https://youtu.be/abc", title: "First", kind: .youtube),
            BatchEntry(url: "https://youtu.be/def", title: "Other", kind: .youtube),
            BatchEntry(url: "https://youtu.be/abc", title: "Duplicate", kind: .youtube),
        ]
        let deduped = entries.deduplicatedByURL()
        XCTAssertEqual(deduped.map(\.title), ["First", "Other"])
    }
    func testAvalancheGuardThresholdBoundary() {
        XCTAssertFalse(BatchAvalancheGuard.needsExplicitConfirmation(count: 50))
        XCTAssertTrue(BatchAvalancheGuard.needsExplicitConfirmation(count: 51))
    }
    func testAvalancheGuardZero() {
        XCTAssertFalse(BatchAvalancheGuard.needsExplicitConfirmation(count: 0))
    }
}
