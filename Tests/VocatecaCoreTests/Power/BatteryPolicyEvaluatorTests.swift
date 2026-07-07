import XCTest
@testable import VocatecaCore

/// Battery spec step 1 — the pure decision matrix
/// (3 policies × {mains, battery} × {activeItem, noActiveItem}).
final class BatteryPolicyEvaluatorTests: XCTestCase {

    private func decide(_ p: BatteryPolicy, _ s: PowerState, _ active: Bool) -> QueueAction {
        BatteryPolicyEvaluator.decide(policy: p, powerState: s, hasActiveItem: active)
    }

    func testMainsAlwaysResumesRegardlessOfPolicy() {
        for policy in BatteryPolicy.allCases {
            for active in [true, false] {
                XCTAssertEqual(decide(policy, .mains, active), .resume,
                               "\(policy) on mains (active=\(active)) must resume")
            }
        }
    }

    func testNormalKeepsRunningOnBattery() {
        XCTAssertEqual(decide(.normal, .battery, true), .keepRunning)
        XCTAssertEqual(decide(.normal, .battery, false), .keepRunning)
    }

    func testFinishThenPauseOnBattery() {
        XCTAssertEqual(decide(.finishThenPause, .battery, true), .finishThenPause)
        XCTAssertEqual(decide(.finishThenPause, .battery, false), .pauseNow)
    }

    func testMainsOnlyStopsAndRevertsOnBattery() {
        XCTAssertEqual(decide(.mainsOnly, .battery, true), .stopAndRevert)
        XCTAssertEqual(decide(.mainsOnly, .battery, false), .stopAndRevert)
    }

    func testDefaultPolicyIsFinishThenPause() {
        XCTAssertEqual(BatteryPolicy.default, .finishThenPause)
        XCTAssertEqual(BatteryPolicy.default.rawValue, "finish_then_pause")
    }
}
