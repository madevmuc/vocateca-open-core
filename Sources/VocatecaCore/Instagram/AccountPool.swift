import Foundation
import GRDB

// MARK: - AccountPool

/// Manages the Instagram account pool stored in `instagram_account_pool`.
///
/// The pool holds 1 primary account (`pool_position = 0`) plus up to 2 backups
/// (`pool_position = 1` and `2`).  All mutations go through `StateStore`
/// so they are durable and atomic.
///
/// ## Failover
///
/// ``failover(in:)`` suspends the current primary (sets `health_status` to
/// `"suspended"`, `is_active = 0`) and promotes the backup with the highest
/// warm-up stage to `pool_position = 0`.  If no warmed backup exists the
/// function returns `nil` and the caller must alert the user.
///
/// ## Follow tracking
///
/// ``recordFollow(accountId:profile:in:)`` appends `profile` to the
/// `followed_profiles` JSON array for the given account and persists the change.
public struct AccountPool {

    // MARK: - Read

    /// Returns all accounts in the pool, regardless of health or active status.
    public static func all(in store: StateStore) throws -> [InstagramAccount] {
        try store.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: "SELECT * FROM instagram_account_pool ORDER BY pool_position ASC")
            )
            return try rows.map { try AccountPool.account(from: $0) }
        }
    }

    /// Returns the active primary account (`pool_position = 0`, `is_active = 1`),
    /// or `nil` when none exists.
    public static func activePrimary(in store: StateStore) throws -> InstagramAccount? {
        try store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT * FROM instagram_account_pool
                    WHERE pool_position = 0 AND is_active = 1
                    LIMIT 1
                """)
            ) else { return nil }
            return try AccountPool.account(from: row)
        }
    }

    // MARK: - Write: add

    /// Inserts `account` into the pool, replacing any existing row with the same
    /// `account_id` (idempotent upsert).
    public static func add(_ account: InstagramAccount, in store: StateStore) throws {
        let profilesJSON = try AccountPool.encodeProfiles(account.followedProfiles)
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instagram_account_pool
                        (account_id, pool_position, is_new, warmup_stage, is_active,
                         health_status, last_health_check_at, failed_attempts, followed_profiles)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        pool_position        = excluded.pool_position,
                        is_new               = excluded.is_new,
                        warmup_stage         = excluded.warmup_stage,
                        is_active            = excluded.is_active,
                        health_status        = excluded.health_status,
                        last_health_check_at = excluded.last_health_check_at,
                        failed_attempts      = excluded.failed_attempts,
                        followed_profiles    = excluded.followed_profiles
                """,
                arguments: [
                    account.accountId,
                    account.poolPosition,
                    account.isNew ? 1 : 0,
                    account.warmupStage,
                    account.isActive ? 1 : 0,
                    account.healthStatus.rawValue,
                    account.lastHealthCheckAt,
                    account.failedAttempts,
                    profilesJSON,
                ]
            )
        }
    }

    // MARK: - Write: health

    /// Updates the `health_status` and `last_health_check_at` for `accountId`.
    ///
    /// Also resets `failed_attempts` to 0 when `status` is `.ok` (recovery).
    public static func markHealth(
        accountId: String,
        status: AccountHealthStatus,
        at timestamp: String,
        in store: StateStore
    ) throws {
        try store.dbQueue.write { db in
            let resetAttempts = (status == .ok) ? 1 : 0
            try db.execute(
                sql: """
                    UPDATE instagram_account_pool
                    SET health_status = ?,
                        last_health_check_at = ?,
                        failed_attempts = CASE WHEN ? = 1 THEN 0 ELSE failed_attempts END
                    WHERE account_id = ?
                """,
                arguments: [status.rawValue, timestamp, resetAttempts, accountId]
            )
        }
    }

    /// Atomically increments `failed_attempts` for `accountId` and returns the
    /// new count.
    @discardableResult
    public static func incrementFailure(accountId: String, in store: StateStore) throws -> Int {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE instagram_account_pool
                    SET failed_attempts = failed_attempts + 1
                    WHERE account_id = ?
                """,
                arguments: [accountId]
            )
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT failed_attempts FROM instagram_account_pool WHERE account_id = ?",
                           arguments: [accountId])
            )
            return row?["failed_attempts"] ?? 1
        }
    }

    // MARK: - Write: warm-up

    /// Advances the warm-up stage for `accountId` by one step (max = `InstagramAccount.maxWarmupStage`).
    public static func advanceWarmup(accountId: String, in store: StateStore) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE instagram_account_pool
                    SET warmup_stage = MIN(warmup_stage + 1, ?)
                    WHERE account_id = ?
                """,
                arguments: [InstagramAccount.maxWarmupStage, accountId]
            )
        }
    }

    // MARK: - Write: failover

    /// Suspends the current primary and promotes the best available backup.
    ///
    /// "Best available backup" = active backup with the highest `warmup_stage`.
    ///
    /// Steps:
    /// 1. Find the current primary (`pool_position = 0`, `is_active = 1`).
    /// 2. Set its `health_status = "suspended"` and `is_active = 0`.
    /// 3. Find the active backup with the highest `warmup_stage`.
    /// 4. Set that backup's `pool_position = 0`.
    ///
    /// - Returns: The new primary account after failover, or `nil` when no
    ///   suitable backup exists (caller must alert the user).
    @discardableResult
    public static func failover(in store: StateStore) throws -> InstagramAccount? {
        // Locate primary and best backup in a single read.
        let (primaryId, backupId) = try store.dbQueue.read { db -> (String?, String?) in
            let primaryRow = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT account_id FROM instagram_account_pool
                    WHERE pool_position = 0 AND is_active = 1
                    LIMIT 1
                """)
            )
            let backupRow = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT account_id FROM instagram_account_pool
                    WHERE pool_position != 0 AND is_active = 1
                    ORDER BY warmup_stage DESC, pool_position ASC
                    LIMIT 1
                """)
            )
            let primary: String? = primaryRow?["account_id"]
            let backup: String? = backupRow?["account_id"]
            return (primary, backup)
        }

        guard let oldPrimaryId = primaryId else { return nil }

        // Suspend the old primary.
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE instagram_account_pool
                    SET health_status = 'suspended', is_active = 0
                    WHERE account_id = ?
                """,
                arguments: [oldPrimaryId]
            )
        }

        guard let newPrimaryId = backupId else { return nil }

        // Promote the backup to pool_position 0.
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE instagram_account_pool
                    SET pool_position = 0
                    WHERE account_id = ?
                """,
                arguments: [newPrimaryId]
            )
        }

        // Return the freshly promoted account.
        return try store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT * FROM instagram_account_pool WHERE account_id = ?
                """, arguments: [newPrimaryId])
            ) else { return nil }
            return try AccountPool.account(from: row)
        }
    }

    // MARK: - Write: follow recording

    /// Records that `accountId` now follows `profile`.
    ///
    /// Appends `profile` to the JSON array in `followed_profiles` (idempotent —
    /// duplicates are silently filtered before writing).
    public static func recordFollow(
        accountId: String,
        profile: String,
        in store: StateStore
    ) throws {
        try store.dbQueue.write { db in
            // Read current list.
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT followed_profiles FROM instagram_account_pool
                    WHERE account_id = ?
                """, arguments: [accountId])
            )
            let existing: [String]
            if let jsonStr: String = row?["followed_profiles"],
               let data = jsonStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                existing = decoded
            } else {
                existing = []
            }

            // Deduplicate.
            var updated = existing
            if !updated.contains(profile) {
                updated.append(profile)
            }

            let newJSON = try AccountPool.encodeProfiles(updated)
            try db.execute(
                sql: """
                    UPDATE instagram_account_pool
                    SET followed_profiles = ?
                    WHERE account_id = ?
                """,
                arguments: [newJSON, accountId]
            )
        }
    }

    // MARK: - Private helpers

    /// Decodes a `Row` from `instagram_account_pool` into an `InstagramAccount`.
    private static func account(from row: Row) throws -> InstagramAccount {
        let accountId: String = row["account_id"]
        let poolPosition: Int = row["pool_position"]
        let isNew: Bool = (row["is_new"] as Int?) == 1
        let warmupStage: Int = row["warmup_stage"]
        let isActive: Bool = (row["is_active"] as Int?) == 1
        let healthRaw: String = row["health_status"] ?? "ok"
        let health = AccountHealthStatus(rawValue: healthRaw) ?? .ok
        let lastCheck: String? = row["last_health_check_at"]
        let failedAttempts: Int = row["failed_attempts"] ?? 0

        let followedProfiles: [String]
        if let jsonStr: String = row["followed_profiles"],
           let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            followedProfiles = decoded
        } else {
            followedProfiles = []
        }

        return InstagramAccount(
            accountId: accountId,
            poolPosition: poolPosition,
            isNew: isNew,
            warmupStage: warmupStage,
            isActive: isActive,
            healthStatus: health,
            lastHealthCheckAt: lastCheck,
            failedAttempts: failedAttempts,
            followedProfiles: followedProfiles
        )
    }

    /// JSON-encodes a `[String]` array for storage in `followed_profiles`.
    private static func encodeProfiles(_ profiles: [String]) throws -> String {
        let data = try JSONEncoder().encode(profiles)
        return String(decoding: data, as: UTF8.self)
    }
}
