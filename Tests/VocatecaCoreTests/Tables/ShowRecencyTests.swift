import XCTest
import Foundation
@testable import VocatecaCore

/// Tables Task 7 — the "New" badge predicate (`Show.isAddedAtRecent`).
final class ShowRecencyTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!

    func testSentinelIsNeverRecent() {
        XCTAssertFalse(Show.isAddedAtRecent(Show.defaultAddedAt, now: now))
    }

    func testTodayIsRecent() {
        // Same calendar day, a few hours before `now`.
        XCTAssertTrue(Show.isAddedAtRecent("2026-07-01", now: now))
    }

    func testTwoDaysAgoIsNotRecent() {
        XCTAssertFalse(Show.isAddedAtRecent("2026-06-29", now: now))
    }

    func testFullISOWithinWindowIsRecent() {
        XCTAssertTrue(Show.isAddedAtRecent("2026-07-01T02:00:00Z", now: now))
    }

    func testFullISOOutsideWindowIsNotRecent() {
        XCTAssertFalse(Show.isAddedAtRecent("2026-06-30T02:00:00Z", now: now))
    }

    func testFutureDateIsNotRecent() {
        XCTAssertFalse(Show.isAddedAtRecent("2026-07-05", now: now))
    }

    func testUnparseableIsNotRecent() {
        XCTAssertFalse(Show.isAddedAtRecent("not-a-date", now: now))
    }
}
