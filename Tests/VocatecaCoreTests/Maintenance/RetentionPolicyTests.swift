import XCTest
@testable import VocatecaCore

/// Tests for the pure maintenance/retention policies (fixed clocks, no I/O).
final class RetentionPolicyTests: XCTestCase {

    private let now = "2026-07-01T12:00:00.000000+00:00"

    // MARK: - mp3 deletion

    func testNoLocalFileNeverDeletes() {
        XCTAssertFalse(RetentionPolicy.shouldDeleteMp3(
            status: "done", completedAtISO: now, hasLocalFile: false,
            deleteAfterTranscribe: true, retentionDays: 7, nowISO: now))
    }

    func testNonDoneNeverDeletes() {
        XCTAssertFalse(RetentionPolicy.shouldDeleteMp3(
            status: "pending", completedAtISO: now, hasLocalFile: true,
            deleteAfterTranscribe: true, retentionDays: 7, nowISO: now))
        XCTAssertFalse(RetentionPolicy.shouldDeleteMp3(
            status: "failed", completedAtISO: now, hasLocalFile: true,
            deleteAfterTranscribe: true, retentionDays: 0, nowISO: now))
    }

    func testDeleteAfterTranscribeDeletesImmediately() {
        XCTAssertTrue(RetentionPolicy.shouldDeleteMp3(
            status: "done", completedAtISO: now, hasLocalFile: true,
            deleteAfterTranscribe: true, retentionDays: 7, nowISO: now))
    }

    func testAgeOutAfterRetentionDays() {
        let eightDaysAgo = "2026-06-23T12:00:00.000000+00:00"
        let sixDaysAgo   = "2026-06-25T12:00:00.000000+00:00"
        // deleteAfterTranscribe off → only delete once older than retentionDays (7)
        XCTAssertTrue(RetentionPolicy.shouldDeleteMp3(
            status: "done", completedAtISO: eightDaysAgo, hasLocalFile: true,
            deleteAfterTranscribe: false, retentionDays: 7, nowISO: now))
        XCTAssertFalse(RetentionPolicy.shouldDeleteMp3(
            status: "done", completedAtISO: sixDaysAgo, hasLocalFile: true,
            deleteAfterTranscribe: false, retentionDays: 7, nowISO: now))
    }

    func testRetentionZeroKeepsForever() {
        let yearAgo = "2025-07-01T12:00:00.000000+00:00"
        XCTAssertFalse(RetentionPolicy.shouldDeleteMp3(
            status: "done", completedAtISO: yearAgo, hasLocalFile: true,
            deleteAfterTranscribe: false, retentionDays: 0, nowISO: now))
    }

    // MARK: - event cutoff

    func testEventCutoff() {
        let cutoff = RetentionPolicy.eventCutoffISO(nowISO: now, retentionDays: 30)
        XCTAssertNotNil(cutoff)
        // 30 days before 2026-07-01 is 2026-06-01.
        XCTAssertTrue(cutoff!.hasPrefix("2026-06-01"), "got \(cutoff!)")
    }

    func testEventCutoffDisabled() {
        XCTAssertNil(RetentionPolicy.eventCutoffISO(nowISO: now, retentionDays: 0))
    }

    // MARK: - disk guard

    func testDiskGuard() {
        XCTAssertTrue(DiskGuard.shouldPause(freeBytes: 1_000_000_000, minFreeGb: 5, enabled: true))
        XCTAssertFalse(DiskGuard.shouldPause(freeBytes: 10_000_000_000, minFreeGb: 5, enabled: true))
        XCTAssertFalse(DiskGuard.shouldPause(freeBytes: 1, minFreeGb: 5, enabled: false))
        XCTAssertFalse(DiskGuard.shouldPause(freeBytes: 1, minFreeGb: 0, enabled: true))
    }

    // MARK: - M12: pre-claim path-based guard

    func testDiskGuardPathToCheckDisabledOrNoFloorNeverPauses() {
        // Disabled or a non-positive floor short-circuit BEFORE any stat — so the
        // path is irrelevant and the queue is never falsely paused.
        XCTAssertFalse(DiskGuard.shouldPause(pathToCheck: "/", minFreeGb: 5, enabled: false))
        XCTAssertFalse(DiskGuard.shouldPause(pathToCheck: "/", minFreeGb: 0, enabled: true))
    }

    func testDiskGuardPathToCheckHugeFloorTrips() {
        // A floor larger than any real volume's free space → the guard trips
        // (proving the path→freeBytes→shouldPause wiring is live). `/` exists, so
        // freeBytes returns a real (finite) value well below an exabyte floor.
        let exabyteGb = 1_000_000_000  // 1e9 GB ≈ 1e18 bytes, larger than any disk
        XCTAssertTrue(DiskGuard.shouldPause(pathToCheck: "/", minFreeGb: exabyteGb, enabled: true))
    }

    func testDiskGuardFreeBytesFailsOpenOnMissingPath() {
        // A path whose parent also doesn't exist → stat fails → `.max` free → the
        // guard must NOT falsely pause (fail-open).
        let bogus = "/no/such/path/\(UUID().uuidString)/media"
        XCTAssertEqual(DiskGuard.freeBytes(atPath: bogus, fileManager: .default), .max)
        XCTAssertFalse(DiskGuard.shouldPause(pathToCheck: bogus, minFreeGb: 5, enabled: true))
    }

    // MARK: - local duration guard

    func testLocalDurationGuard() {
        XCTAssertTrue(LocalDurationGuard.isTooLong(durationSec: 5 * 3600, maxHours: 4))
        XCTAssertFalse(LocalDurationGuard.isTooLong(durationSec: 3 * 3600, maxHours: 4))
        XCTAssertFalse(LocalDurationGuard.isTooLong(durationSec: 99 * 3600, maxHours: 0))
        XCTAssertFalse(LocalDurationGuard.isTooLong(durationSec: nil, maxHours: 4))
    }
}
