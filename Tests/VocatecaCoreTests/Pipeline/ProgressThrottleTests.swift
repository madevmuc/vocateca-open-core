import XCTest
@testable import VocatecaCore

/// Guards the OOM fix: WhisperKit calls the progress callback once per decoded
/// token, so the pipeline must coalesce before emitting events / writing SQLite.
final class ProgressThrottleTests: XCTestCase {

    func testFirstCallAlwaysEmits() {
        let t = ProgressThrottle()
        XCTAssertTrue(t.shouldEmit(0.0))
    }

    /// The incident shape: thousands of near-identical fractions arriving back to
    /// back. All but the first must be swallowed.
    func testTokenRateBurstCollapsesToOneEmit() {
        let t = ProgressThrottle(minDelta: 0.002, minInterval: 0.25)
        XCTAssertTrue(t.shouldEmit(0.10))
        var emitted = 0
        for i in 1...5_000 {
            // Fractions creeping up by 1e-5 — a realistic per-token delta.
            if t.shouldEmit(0.10 + Double(i) * 0.00001) { emitted += 1 }
        }
        XCTAssertEqual(emitted, 0, "a per-token burst must not produce events")
    }

    /// A delta big enough on its own is still gated by the interval — otherwise a
    /// fast decode re-opens the firehose.
    func testLargeDeltaWithinIntervalIsStillThrottled() {
        let t = ProgressThrottle(minDelta: 0.002, minInterval: 10)
        XCTAssertTrue(t.shouldEmit(0.1))
        XCTAssertFalse(t.shouldEmit(0.9))
    }

    /// Real progress must still reach the UI once both gates clear.
    func testEmitsAgainOnceDeltaAndIntervalPass() {
        let t = ProgressThrottle(minDelta: 0.002, minInterval: 0)
        XCTAssertTrue(t.shouldEmit(0.10))
        XCTAssertFalse(t.shouldEmit(0.1001), "below minDelta")
        XCTAssertTrue(t.shouldEmit(0.20))
    }

    func testForceBypassesBothGates() {
        let t = ProgressThrottle(minDelta: 0.5, minInterval: 999)
        XCTAssertTrue(t.shouldEmit(0.1))
        XCTAssertFalse(t.shouldEmit(0.1))
        XCTAssertTrue(t.shouldEmit(0.1, force: true))
    }

    /// A verification-failure re-run legitimately rewinds the bar; that must be
    /// reportable, not swallowed as "no change".
    func testBackwardsJumpIsEmitted() {
        let t = ProgressThrottle(minDelta: 0.002, minInterval: 0)
        XCTAssertTrue(t.shouldEmit(0.80))
        XCTAssertTrue(t.shouldEmit(0.12))
    }

    // MARK: - HeartbeatThrottle

    func testHeartbeatFiresOnceThenGates() {
        let h = HeartbeatThrottle(interval: 30)
        XCTAssertTrue(h.shouldBeat(), "first call must claim the job row immediately")
        for _ in 0..<1_000 { XCTAssertFalse(h.shouldBeat()) }
    }

    func testHeartbeatFiresAgainAfterInterval() {
        let h = HeartbeatThrottle(interval: 0)
        XCTAssertTrue(h.shouldBeat())
        XCTAssertTrue(h.shouldBeat())
    }
}
