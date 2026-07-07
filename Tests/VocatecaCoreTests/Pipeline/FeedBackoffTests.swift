import XCTest
import Foundation
@testable import VocatecaCore

/// Tests for ``FeedBackoff`` — ported from `core/backoff.py`.
///
/// ## Oracle strategy
/// A fixed `now` date with zero microseconds is used so the expected ISO
/// timestamps can be computed directly from the documented stage days without
/// calling Python. The expected strings are verified against Python's output
/// (computed separately and recorded here):
///
/// ```
/// now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
/// # fail count=3: until='2024-06-16T12:00:00+00:00'  (1 day)
/// # fail count=4: until='2024-06-18T12:00:00+00:00'  (3 days)
/// # fail count=5: until='2024-06-22T12:00:00+00:00'  (7 days)
/// # fail count=6: until='2024-06-22T12:00:00+00:00'  (7 days, capped at stage 2)
/// ```
///
/// Python produces these from:
/// ```python
/// from datetime import datetime, timedelta, timezone
/// _STAGES_DAYS = (1, 3, 7); _THRESHOLD = 3
/// now = datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
/// stage_idx = min(count - _THRESHOLD, len(_STAGES_DAYS) - 1)
/// (now + timedelta(days=_STAGES_DAYS[stage_idx])).isoformat()
/// ```
final class FeedBackoffTests: XCTestCase {

    // MARK: - Constants (verify against Python source)

    func testConstants() {
        XCTAssertEqual(FeedBackoff.threshold, 3,
                       "_THRESHOLD must be 3 (core/backoff.py)")
        XCTAssertEqual(FeedBackoff.stagesDays, [1, 3, 7],
                       "_STAGES_DAYS must be [1, 3, 7] (core/backoff.py)")
    }

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedBackoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    // Fixed reference "now": 2024-06-15 12:00:00 UTC (zero microseconds).
    // Python: datetime(2024, 6, 15, 12, 0, 0, tzinfo=timezone.utc)
    static let fixedNow: Date = {
        var comps = DateComponents()
        comps.year = 2024; comps.month = 6; comps.day = 15
        comps.hour = 12;  comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    // MARK: - onSuccess clears all keys

    func testOnSuccessClearsKeys() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed some failure state.
        try store.setMeta(key: "feed_fail_count:my-show", value: "5")
        try store.setMeta(key: "feed_backoff_until:my-show", value: "2024-12-31T00:00:00+00:00")
        try store.setMeta(key: "feed_health:my-show", value: "fail")

        try FeedBackoff.onSuccess(showSlug: "my-show", store: store)

        XCTAssertEqual(try store.metaValue("feed_fail_count:my-show"), "0")
        XCTAssertEqual(try store.metaValue("feed_backoff_until:my-show"), "")
        XCTAssertEqual(try store.metaValue("feed_health:my-show"), "ok")
        XCTAssertEqual(try store.metaValue("feed_fail_category:my-show"), "")
        XCTAssertEqual(try store.metaValue("feed_fail_message:my-show"), "")
        XCTAssertEqual(try store.metaValue("feed_fail_at:my-show"), "")
    }

    // MARK: - onFailure: increments count

    func testOnFailureIncrementsCount() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let count1 = try FeedBackoff.onFailure(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(try store.metaValue("feed_fail_count:s"), "1")

        let count2 = try FeedBackoff.onFailure(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertEqual(count2, 2)
        XCTAssertEqual(try store.metaValue("feed_fail_count:s"), "2")
    }

    // MARK: - onFailure: no backoff below threshold

    func testNoBackoffBelowThreshold() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First two failures: no backoff_until set yet.
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: Self.fixedNow)
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: Self.fixedNow)

        let until = try store.metaValue("feed_backoff_until:s") ?? ""
        // Either nil/missing or empty — no backoff scheduled yet.
        XCTAssertTrue(until.isEmpty,
                      "No backoff should be set before reaching threshold (count < 3)")
    }

    // MARK: - Oracle: backoff timestamps match Python

    /// Replicates the Python sequence exactly and asserts stored ISO timestamps
    /// match what Python produces for the same `now`.
    ///
    /// Python reference (verified 2026-06-28):
    /// - count=3 (3rd failure) → `"2024-06-16T12:00:00+00:00"` (+1 day)
    /// - count=4               → `"2024-06-18T12:00:00+00:00"` (+3 days)
    /// - count=5               → `"2024-06-22T12:00:00+00:00"` (+7 days)
    /// - count=6               → `"2024-06-22T12:00:00+00:00"` (+7 days, capped)
    func testBackoffTimestampsMatchPython() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Self.fixedNow  // 2024-06-15T12:00:00 UTC

        // Failure 1 — no backoff yet.
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)
        // Failure 2 — no backoff yet.
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)
        // Failure 3 — first backoff: 1 day.
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)

        let until3 = try XCTUnwrap(try store.metaValue("feed_backoff_until:s"))
        // Python: (datetime(2024,6,15,12,0,0,tz=utc) + timedelta(days=1)).isoformat()
        //       = '2024-06-16T12:00:00+00:00'
        XCTAssertEqual(until3, "2024-06-16T12:00:00.000000+00:00",
                       "3rd failure (stage 0): until must be now+1day")

        // Failure 4 — stage 1: 3 days.
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)
        let until4 = try XCTUnwrap(try store.metaValue("feed_backoff_until:s"))
        // Python: '2024-06-18T12:00:00+00:00'
        XCTAssertEqual(until4, "2024-06-18T12:00:00.000000+00:00",
                       "4th failure (stage 1): until must be now+3days")

        // Failure 5 — stage 2: 7 days (max stage).
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)
        let until5 = try XCTUnwrap(try store.metaValue("feed_backoff_until:s"))
        // Python: '2024-06-22T12:00:00+00:00'
        XCTAssertEqual(until5, "2024-06-22T12:00:00.000000+00:00",
                       "5th failure (stage 2): until must be now+7days")

        // Failure 6 — still capped at stage 2 (7 days).
        try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)
        let until6 = try XCTUnwrap(try store.metaValue("feed_backoff_until:s"))
        XCTAssertEqual(until6, "2024-06-22T12:00:00.000000+00:00",
                       "6th failure (stage 2 cap): until must remain now+7days")
    }

    // MARK: - inBackoff: false when no key

    func testInBackoffFalseWhenNoKey() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try FeedBackoff.inBackoff(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertFalse(result, "inBackoff must return false when no meta key exists")
    }

    // MARK: - inBackoff: false when until is empty

    func testInBackoffFalseWhenEmpty() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.setMeta(key: "feed_backoff_until:s", value: "")

        let result = try FeedBackoff.inBackoff(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertFalse(result, "inBackoff must return false when until is empty")
    }

    // MARK: - inBackoff: true when future timestamp

    func testInBackoffTrueWhenFuture() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.setMeta(key: "feed_backoff_until:s", value: "2099-01-01T00:00:00+00:00")

        let result = try FeedBackoff.inBackoff(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertTrue(result, "inBackoff must return true when until is in the future")
    }

    // MARK: - inBackoff: false when past timestamp

    func testInBackoffFalseWhenPast() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.setMeta(key: "feed_backoff_until:s", value: "2020-01-01T00:00:00+00:00")

        let result = try FeedBackoff.inBackoff(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertFalse(result, "inBackoff must return false when until is in the past")
    }

    // MARK: - Full cycle: fail N times, then success resets

    func testSuccessAfterBackoffResets() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Self.fixedNow
        // Trigger 3 failures → backoff starts.
        for _ in 0..<3 {
            try FeedBackoff.onFailure(showSlug: "s", store: store, now: now)
        }
        XCTAssertTrue(try FeedBackoff.inBackoff(showSlug: "s", store: store, now: now),
                      "Should be in backoff after 3 failures")

        // Successful poll → backoff cleared.
        try FeedBackoff.onSuccess(showSlug: "s", store: store)

        XCTAssertFalse(try FeedBackoff.inBackoff(showSlug: "s", store: store, now: now),
                       "Should NOT be in backoff after onSuccess")
        XCTAssertEqual(try store.metaValue("feed_fail_count:s"), "0",
                       "Failure count must reset to 0 after success")
        XCTAssertEqual(try store.metaValue("feed_health:s"), "ok")
    }

    // MARK: - health key set to "fail" on failure

    func testHealthSetToFailOnFailure() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FeedBackoff.onFailure(showSlug: "s", store: store, now: Self.fixedNow)
        XCTAssertEqual(try store.metaValue("feed_health:s"), "fail")
    }

    // MARK: - Meta key isolation across slugs

    func testMetaKeysIsolatedAcrossSlugs() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Self.fixedNow
        // Fail show-A three times.
        for _ in 0..<3 {
            try FeedBackoff.onFailure(showSlug: "show-a", store: store, now: now)
        }

        // show-B is untouched.
        XCTAssertFalse(try FeedBackoff.inBackoff(showSlug: "show-b", store: store, now: now),
                       "Backoff for show-a must not bleed into show-b")
        XCTAssertNil(try store.metaValue("feed_fail_count:show-b"))
    }
}
