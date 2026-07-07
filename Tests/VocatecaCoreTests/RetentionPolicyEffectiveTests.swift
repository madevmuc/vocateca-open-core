import XCTest
@testable import VocatecaCore

final class RetentionPolicyEffectiveTests: XCTestCase {
    private func eff(_ o: Int, _ g: Int, _ del: Bool) -> Int? {
        RetentionPolicy.effectiveMediaRetentionDays(
            showOverride: o, globalDays: g, globalDeleteAfterTranscribe: del)
    }

    func testKeepForever() {
        XCTAssertNil(eff(0, 30, true))   // override 0 wins even if global would delete
        XCTAssertNil(eff(0, 0, false))
    }
    func testExplicitDays() {
        XCTAssertEqual(eff(7, 30, true), 7)
        XCTAssertEqual(eff(1, 0, false), 1)
    }
    func testFollowGlobal_deleteAfterTranscribe() {
        XCTAssertEqual(eff(-1, 30, true), 0)   // delete-after-transcribe = reclaim at 0 days
        XCTAssertEqual(eff(-1, 0, true), 0)
    }
    func testFollowGlobal_ageOut() {
        XCTAssertEqual(eff(-1, 30, false), 30)
    }
    func testFollowGlobal_disabled() {
        XCTAssertNil(eff(-1, 0, false))    // no delete, no positive age → keep
        XCTAssertNil(eff(-1, -5, false))
    }
}
