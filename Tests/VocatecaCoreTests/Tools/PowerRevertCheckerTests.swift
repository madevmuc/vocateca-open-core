import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - PowerRevertCheckerTests
//
// Tests for PowerRevertChecker — the Core-layer policy/expiry helper.
// All timestamps are injected (no Date() calls) so these tests are deterministic
// and run without any async machinery.

final class PowerRevertCheckerTests: XCTestCase {

    // MARK: - Baseline

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000) // arbitrary reference

    // MARK: - after24h

    func testAfter24hNotExpiredAt23h() {
        let start = t0
        let now   = t0.addingTimeInterval(23 * 3600)
        XCTAssertFalse(
            PowerRevertChecker.isExpired(
                policy: .after24h, sessionStart: start,
                revertTime: t0, now: now
            ),
            "Should NOT be expired after 23 h"
        )
    }

    func testAfter24hExpiredAtExactly24h() {
        let start = t0
        let now   = t0.addingTimeInterval(86_400)   // exactly 24 h
        XCTAssertTrue(
            PowerRevertChecker.isExpired(
                policy: .after24h, sessionStart: start,
                revertTime: t0, now: now
            ),
            "Should be expired at exactly 24 h"
        )
    }

    func testAfter24hExpiredAt25h() {
        let start = t0
        let now   = t0.addingTimeInterval(25 * 3600)
        XCTAssertTrue(
            PowerRevertChecker.isExpired(
                policy: .after24h, sessionStart: start,
                revertTime: t0, now: now
            ),
            "Should be expired after 25 h"
        )
    }

    func testAfter24hRemainingSecondsPositive() {
        let start = t0
        let now   = t0.addingTimeInterval(2 * 3600)  // 2 h in
        let remaining = PowerRevertChecker.remainingSeconds(
            policy: .after24h, sessionStart: start, revertTime: t0, now: now
        )
        XCTAssertNotNil(remaining)
        XCTAssertEqual(remaining!, 22 * 3600, accuracy: 1,
                       "Remaining should be 22 h at 2 h in")
    }

    func testAfter24hRemainingSecondsNegativeWhenExpired() {
        let start = t0
        let now   = t0.addingTimeInterval(25 * 3600)  // expired
        let remaining = PowerRevertChecker.remainingSeconds(
            policy: .after24h, sessionStart: start, revertTime: t0, now: now
        )
        XCTAssertNotNil(remaining)
        XCTAssertLessThan(remaining!, 0, "Remaining should be negative when expired")
    }

    // MARK: - customTime

    func testCustomTimeNotExpiredBefore() {
        let revertTime = t0.addingTimeInterval(3600)  // 1 h from now
        let now        = t0
        XCTAssertFalse(
            PowerRevertChecker.isExpired(
                policy: .customTime, sessionStart: t0,
                revertTime: revertTime, now: now
            ),
            "Should NOT be expired before custom revert time"
        )
    }

    func testCustomTimeExpiredAtTime() {
        let revertTime = t0.addingTimeInterval(3600)
        let now        = revertTime  // exactly at revert time
        XCTAssertTrue(
            PowerRevertChecker.isExpired(
                policy: .customTime, sessionStart: t0,
                revertTime: revertTime, now: now
            ),
            "Should be expired at the custom revert time"
        )
    }

    func testCustomTimeExpiredAfterTime() {
        let revertTime = t0.addingTimeInterval(3600)
        let now        = t0.addingTimeInterval(2 * 3600)
        XCTAssertTrue(
            PowerRevertChecker.isExpired(
                policy: .customTime, sessionStart: t0,
                revertTime: revertTime, now: now
            ),
            "Should be expired after the custom revert time"
        )
    }

    func testCustomTimeRemainingSeconds() {
        let revertTime = t0.addingTimeInterval(3600)
        let now        = t0.addingTimeInterval(1800)  // 30 min in
        let remaining = PowerRevertChecker.remainingSeconds(
            policy: .customTime, sessionStart: t0, revertTime: revertTime, now: now
        )
        XCTAssertNotNil(remaining)
        XCTAssertEqual(remaining!, 1800, accuracy: 1,
                       "Remaining should be 30 min")
    }

    // MARK: - untilQueueDone

    func testUntilQueueDoneNeverExpiresAutomatically() {
        // Even if 48 h have passed, untilQueueDone never expires by time alone.
        let now = t0.addingTimeInterval(48 * 3600)
        XCTAssertFalse(
            PowerRevertChecker.isExpired(
                policy: .untilQueueDone, sessionStart: t0,
                revertTime: t0, now: now
            ),
            "untilQueueDone should never expire by time"
        )
    }

    func testUntilQueueDoneRemainingSecondsIsNil() {
        let remaining = PowerRevertChecker.remainingSeconds(
            policy: .untilQueueDone, sessionStart: t0, revertTime: t0, now: t0
        )
        XCTAssertNil(remaining,
                     "untilQueueDone policy should return nil remaining seconds (event-driven)")
    }

    // MARK: - WorkerConfig factory

    func testWorkerConfigBackgroundAuto() {
        let cfg = WorkerConfig.from(
            isPowerMode: false,
            concurrencyAuto: true,
            manualConcurrency: 4,
            perfCores: 12
        )
        XCTAssertEqual(cfg.taskQoS, .utility,
                       "Background mode → .utility QoS (never .background: that tier makes network downloads discretionary)")
        // Auto + Background → "balanced" → always 1
        XCTAssertEqual(cfg.concurrencyLimit, 1,
                       "Background auto concurrency = 1")
    }

    func testWorkerConfigPowerAutoHighCore() {
        let cfg = WorkerConfig.from(
            isPowerMode: true,
            concurrencyAuto: true,
            manualConcurrency: 1,
            perfCores: 12   // ≥ 8 → "full" yields 2
        )
        XCTAssertEqual(cfg.taskQoS, .userInitiated,
                       "Power mode → .userInitiated QoS")
        XCTAssertEqual(cfg.concurrencyLimit, 2,
                       "Power auto on ≥8-core Mac = 2")
    }

    func testWorkerConfigPowerAutoLowCore() {
        let cfg = WorkerConfig.from(
            isPowerMode: true,
            concurrencyAuto: true,
            manualConcurrency: 1,
            perfCores: 4   // < 8 → "full" still yields 1
        )
        XCTAssertEqual(cfg.taskQoS, .userInitiated)
        XCTAssertEqual(cfg.concurrencyLimit, 1,
                       "Power auto on <8-core Mac = 1")
    }

    func testWorkerConfigManualOverrideBackground() {
        let cfg = WorkerConfig.from(
            isPowerMode: false,
            concurrencyAuto: false,
            manualConcurrency: 3,
            perfCores: 12
        )
        XCTAssertEqual(cfg.taskQoS, .utility,
                       "Background mode → .utility QoS regardless of manual concurrency")
        XCTAssertEqual(cfg.concurrencyLimit, 3,
                       "Manual override must be honoured for concurrency")
    }

    func testWorkerConfigManualOverridePower() {
        let cfg = WorkerConfig.from(
            isPowerMode: true,
            concurrencyAuto: false,
            manualConcurrency: 5,
            perfCores: 12
        )
        XCTAssertEqual(cfg.taskQoS, .userInitiated)
        XCTAssertEqual(cfg.concurrencyLimit, 5,
                       "Manual override with Power mode must honour user's choice")
    }
}
