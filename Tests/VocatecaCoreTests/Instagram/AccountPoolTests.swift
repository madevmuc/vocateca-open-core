import XCTest
import Foundation
@testable import VocatecaCore

/// Tests for ``AccountPool`` + ``InstagramAccount``.
///
/// All tests use a temporary in-memory `StateStore` (temp SQLite file) so
/// nothing touches the production database.
final class AccountPoolTests: XCTestCase {

    // MARK: - Helpers

    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountPoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }

    private func makePrimary() -> InstagramAccount {
        InstagramAccount(
            accountId: "primary-account",
            poolPosition: 0,
            isNew: false,
            warmupStage: InstagramAccount.maxWarmupStage,
            isActive: true,
            healthStatus: .ok,
            failedAttempts: 0,
            followedProfiles: ["profile_a", "profile_b"]
        )
    }

    private func makeBackup1() -> InstagramAccount {
        InstagramAccount(
            accountId: "backup-1",
            poolPosition: 1,
            isNew: true,
            warmupStage: 2,   // partially warmed
            isActive: true,
            healthStatus: .ok,
            failedAttempts: 0,
            followedProfiles: ["profile_a"]
        )
    }

    private func makeBackup2() -> InstagramAccount {
        InstagramAccount(
            accountId: "backup-2",
            poolPosition: 2,
            isNew: true,
            warmupStage: 1,   // less warmed than backup-1
            isActive: true,
            healthStatus: .ok,
            failedAttempts: 0,
            followedProfiles: []
        )
    }

    // MARK: - Add + all

    func testAddAndReadAll() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let primary = makePrimary()
        let backup1 = makeBackup1()
        try AccountPool.add(primary, in: store)
        try AccountPool.add(backup1, in: store)

        let all = try AccountPool.all(in: store)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].accountId, "primary-account")
        XCTAssertEqual(all[1].accountId, "backup-1")
    }

    func testAddIsIdempotent() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var primary = makePrimary()
        try AccountPool.add(primary, in: store)

        // Modify and re-add — should update, not duplicate.
        primary.warmupStage = 2
        try AccountPool.add(primary, in: store)

        let all = try AccountPool.all(in: store)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].warmupStage, 2)
    }

    // MARK: - activePrimary

    func testActivePrimary() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)
        try AccountPool.add(makeBackup1(), in: store)

        let primary = try AccountPool.activePrimary(in: store)
        XCTAssertNotNil(primary)
        XCTAssertEqual(primary?.accountId, "primary-account")
    }

    func testActivePrimaryNilWhenEmpty() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(try AccountPool.activePrimary(in: store))
    }

    // MARK: - Followed profiles round-trip

    func testFollowedProfilesRoundTrip() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = makePrimary()
        try AccountPool.add(account, in: store)

        let retrieved = try AccountPool.all(in: store).first!
        XCTAssertEqual(retrieved.followedProfiles, ["profile_a", "profile_b"])
    }

    // MARK: - Health marking

    func testMarkHealthPersists() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)
        try AccountPool.markHealth(
            accountId: "primary-account",
            status: .transient,
            at: "2024-01-15T10:00:00Z",
            in: store
        )

        let updated = try AccountPool.all(in: store).first!
        XCTAssertEqual(updated.healthStatus, .transient)
        XCTAssertEqual(updated.lastHealthCheckAt, "2024-01-15T10:00:00Z")
        XCTAssertEqual(updated.failedAttempts, 0, "failedAttempts should NOT reset on transient mark")
    }

    func testMarkHealthOkResetsFailedAttempts() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var account = makePrimary()
        account.failedAttempts = 5
        try AccountPool.add(account, in: store)

        try AccountPool.markHealth(
            accountId: "primary-account",
            status: .ok,
            at: "2024-01-15T10:00:00Z",
            in: store
        )

        let updated = try AccountPool.all(in: store).first!
        XCTAssertEqual(updated.healthStatus, .ok)
        XCTAssertEqual(updated.failedAttempts, 0, "failedAttempts must reset to 0 on OK mark")
    }

    // MARK: - Increment failure

    func testIncrementFailurePersists() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)
        let count1 = try AccountPool.incrementFailure(accountId: "primary-account", in: store)
        let count2 = try AccountPool.incrementFailure(accountId: "primary-account", in: store)
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 2)

        let account = try AccountPool.all(in: store).first!
        XCTAssertEqual(account.failedAttempts, 2)
    }

    // MARK: - Warm-up advance

    func testAdvanceWarmupIncrements() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makeBackup1(), in: store)  // warmupStage = 2
        try AccountPool.advanceWarmup(accountId: "backup-1", in: store)

        let account = try AccountPool.all(in: store).first!
        XCTAssertEqual(account.warmupStage, 3)
    }

    func testAdvanceWarmupCapsAtMax() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)  // warmupStage = maxWarmupStage = 3
        try AccountPool.advanceWarmup(accountId: "primary-account", in: store)

        let account = try AccountPool.all(in: store).first!
        XCTAssertEqual(account.warmupStage, InstagramAccount.maxWarmupStage)
    }

    // MARK: - Failover

    func testFailoverSuspendsPrimaryAndPromotesBestBackup() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Primary (stage 3) + backup-1 (stage 2) + backup-2 (stage 1).
        try AccountPool.add(makePrimary(), in: store)
        try AccountPool.add(makeBackup1(), in: store)
        try AccountPool.add(makeBackup2(), in: store)

        let newPrimary = try AccountPool.failover(in: store)

        // The old primary must now be suspended + inactive.
        let all = try AccountPool.all(in: store)
        let oldPrimary = all.first { $0.accountId == "primary-account" }!
        XCTAssertEqual(oldPrimary.healthStatus, .suspended)
        XCTAssertFalse(oldPrimary.isActive)

        // The new primary should be backup-1 (highest warmup stage among backups).
        XCTAssertNotNil(newPrimary)
        XCTAssertEqual(newPrimary?.accountId, "backup-1")
        XCTAssertEqual(newPrimary?.poolPosition, 0)
    }

    func testFailoverReturnsNilWhenNoBackupAvailable() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)  // only a primary, no backups

        let result = try AccountPool.failover(in: store)
        XCTAssertNil(result, "Failover with no backups must return nil")
    }

    func testFailoverWhenNoPrimaryIsNoOp() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No primary in the pool.
        let result = try AccountPool.failover(in: store)
        XCTAssertNil(result)
    }

    // MARK: - Follow recording

    func testRecordFollowAppends() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var account = makePrimary()
        account.followedProfiles = []
        try AccountPool.add(account, in: store)

        try AccountPool.recordFollow(accountId: "primary-account", profile: "new_profile", in: store)

        let updated = try AccountPool.all(in: store).first!
        XCTAssertTrue(updated.followedProfiles.contains("new_profile"))
    }

    func testRecordFollowIsIdempotent() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)

        // profile_a is already in followedProfiles — adding again must not duplicate.
        try AccountPool.recordFollow(accountId: "primary-account", profile: "profile_a", in: store)

        let updated = try AccountPool.all(in: store).first!
        let count = updated.followedProfiles.filter { $0 == "profile_a" }.count
        XCTAssertEqual(count, 1, "Duplicate follows must be filtered")
    }

    func testRecordFollowPreservesExistingProfiles() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try AccountPool.add(makePrimary(), in: store)  // already has profile_a, profile_b
        try AccountPool.recordFollow(accountId: "primary-account", profile: "profile_c", in: store)

        let updated = try AccountPool.all(in: store).first!
        XCTAssertTrue(updated.followedProfiles.contains("profile_a"))
        XCTAssertTrue(updated.followedProfiles.contains("profile_b"))
        XCTAssertTrue(updated.followedProfiles.contains("profile_c"))
    }

    // MARK: - Warm-up stage budget constants

    func testWarmupStageBudgets() {
        XCTAssertEqual(InstagramAccount.dailyBudget(forStage: 0), 5)
        XCTAssertEqual(InstagramAccount.dailyBudget(forStage: 1), 20)
        XCTAssertEqual(InstagramAccount.dailyBudget(forStage: 2), 60)
        XCTAssertNil(InstagramAccount.dailyBudget(forStage: 3), "Stage 3 = unlimited")
    }

    func testIsFullyWarmed() {
        var account = makePrimary()
        account.warmupStage = InstagramAccount.maxWarmupStage
        XCTAssertTrue(account.isFullyWarmed)

        account.warmupStage = 2
        XCTAssertFalse(account.isFullyWarmed)
    }
}
