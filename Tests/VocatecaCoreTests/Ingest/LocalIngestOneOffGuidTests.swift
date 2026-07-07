import XCTest
@testable import VocatecaCore

final class LocalIngestOneOffGuidTests: XCTestCase {
    func testLocalGuidIsOneOff() {
        XCTAssertTrue(LocalIngestService.isOneOffGuid("local:deadbeef"))
    }
    func testNonLocalGuidIsNotOneOff() {
        XCTAssertFalse(LocalIngestService.isOneOffGuid("podcast:123"))
        XCTAssertFalse(LocalIngestService.isOneOffGuid("acq-001"))
    }
}
