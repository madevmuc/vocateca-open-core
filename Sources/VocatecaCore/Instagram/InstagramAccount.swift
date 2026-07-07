import Foundation

// MARK: - InstagramAccount

/// A single row from `instagram_account_pool`.
///
/// Mirrors every column in the table as defined by the `v2_additive` migration
/// in `Schema.swift`.
///
/// ## Warm-up stages
///
/// New accounts go through a staged warm-up before they are treated as fully
/// operational. Each stage has a documented per-stage request budget, applied
/// by the pipeline before allowing the account to issue more requests.
///
/// | Stage | Requests/day | Description                                    |
/// |-------|-------------|------------------------------------------------|
/// | 0     |  5          | Cold start — only probe enumeration runs       |
/// | 1     | 20          | Light browsing — a handful of profile fetches  |
/// | 2     | 60          | Moderate — can serve as a backup               |
/// | 3     | ∞ (normal)  | Fully warmed — acts as a primary or ready backup|
///
/// Stage is advanced by ``AccountPool.advanceWarmup(accountId:)`` after each day
/// the account successfully stays within its budget.
///
/// ## Pool positions
///
/// `poolPosition == 0` is the primary account.  Positions 1 and 2 are backups.
/// There is at most one account per position at any given time.
public struct InstagramAccount: Sendable, Equatable {

    // MARK: - Fields (match instagram_account_pool columns)

    /// Unique identifier for this account (e.g. the Instagram username or a UUID key).
    public var accountId: String
    /// Pool position: 0 = primary, 1 = first backup, 2 = second backup.
    public var poolPosition: Int
    /// `true` when the account was registered as "new" (needs warm-up).
    public var isNew: Bool
    /// Warm-up stage (0 = cold, 3 = fully warmed; see type documentation).
    public var warmupStage: Int
    /// Whether the account is currently active (not disabled/deleted from the pool).
    public var isActive: Bool
    /// Current health classification.
    public var healthStatus: AccountHealthStatus
    /// ISO-8601 UTC timestamp of the last health check, or `nil` if never checked.
    public var lastHealthCheckAt: String?
    /// Consecutive failed attempts in the current health state.
    public var failedAttempts: Int
    /// Instagram profile handles this account is confirmed to follow.
    public var followedProfiles: [String]

    // MARK: - Init

    public init(
        accountId: String,
        poolPosition: Int,
        isNew: Bool = true,
        warmupStage: Int = 0,
        isActive: Bool = true,
        healthStatus: AccountHealthStatus = .ok,
        lastHealthCheckAt: String? = nil,
        failedAttempts: Int = 0,
        followedProfiles: [String] = []
    ) {
        self.accountId = accountId
        self.poolPosition = poolPosition
        self.isNew = isNew
        self.warmupStage = warmupStage
        self.isActive = isActive
        self.healthStatus = healthStatus
        self.lastHealthCheckAt = lastHealthCheckAt
        self.failedAttempts = failedAttempts
        self.followedProfiles = followedProfiles
    }

    // MARK: - Warm-up constants

    /// Maximum warm-up stage — at this stage the account is fully warmed.
    public static let maxWarmupStage: Int = 3

    /// Daily request budget for each warm-up stage.  `nil` = unlimited.
    public static func dailyBudget(forStage stage: Int) -> Int? {
        switch stage {
        case 0:  return 5
        case 1:  return 20
        case 2:  return 60
        default: return nil  // stage 3+ = fully warmed, no artificial limit
        }
    }

    /// Returns `true` when the account has completed warm-up.
    public var isFullyWarmed: Bool { warmupStage >= Self.maxWarmupStage }
}
