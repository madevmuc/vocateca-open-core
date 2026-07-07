// swift/Tests/VocatecaCoreTests/AutomationStatusTests.swift
import XCTest
@testable import VocatecaCore

final class AutomationStatusTests: XCTestCase {
    func testRoundTripEncodeDecode() {
        let s = AutomationStatus(
            lastRunAt: "2026-07-03T03:00:00Z", nextRunAt: "2026-07-04T03:00:00Z",
            processed: 12, done: 11, failed: 1, lastSkipReason: .ok)
        let json = s.encoded()
        XCTAssertNotNil(json)
        XCTAssertEqual(AutomationStatus.decode(json!), s)
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(AutomationStatus.decode("not json"))
    }

    func testSkipReasonRawValuesAreStable() {
        XCTAssertEqual(AutomationSkipReason.lowPowerMode.rawValue, "lowPowerMode")
        XCTAssertEqual(AutomationSkipReason.noAutoDownloadShows.rawValue, "noAutoDownloadShows")
    }
}
