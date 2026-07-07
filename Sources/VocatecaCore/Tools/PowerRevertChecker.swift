import Foundation

// MARK: - PowerRevertPolicy (Core-layer)

/// The auto-revert policy for Power mode.
///
/// This enum lives in `VocatecaCore` so the expiry computation can be unit-tested
/// without touching `VocatecaUI`. `AppModeController` (in VocatecaUI) uses the
/// same raw-string values — they stay in sync via the `rawValue` convention.
///
/// Raw-value strings must match `AppModeController.PowerRevertPolicy.rawValue`.
public enum CorePowerRevertPolicy: String, Sendable {
    /// Auto-revert after 24 hours from when Power was activated.
    case after24h       = "after24h"
    /// Auto-revert when the current queue finishes processing (event-driven only).
    case untilQueueDone = "untilQueueDone"
    /// Auto-revert at a user-specified wall-clock time.
    case customTime     = "customTime"
}

// MARK: - PowerRevertChecker

/// Pure-function helper that determines whether a Power session has expired.
///
/// All inputs (policy, session start, revert time, now) are passed explicitly
/// so this type is trivially testable without date mocking.
///
/// `AppModeController` delegates to this type for the policy computation so the
/// logic is exercised by `VocatecaCoreTests` without a VocatecaUI dependency.
public enum PowerRevertChecker {

    /// Returns `true` when the Power session should auto-revert to Background.
    ///
    /// - Parameters:
    ///   - policy:      The active revert policy.
    ///   - sessionStart: When the Power session began.
    ///   - revertTime:   The custom revert wall-clock time (only used for `.customTime`).
    ///   - now:          The current date (injectable for tests).
    public static func isExpired(
        policy: CorePowerRevertPolicy,
        sessionStart: Date,
        revertTime: Date,
        now: Date
    ) -> Bool {
        switch policy {
        case .after24h:
            return now.timeIntervalSince(sessionStart) >= 86_400   // 24 × 3600 s
        case .customTime:
            return now >= revertTime
        case .untilQueueDone:
            // Event-driven only — never expires by time alone.
            return false
        }
    }

    /// Remaining seconds until expiry, or `nil` when the policy is event-driven.
    ///
    /// A negative return value means the session has already expired.
    public static func remainingSeconds(
        policy: CorePowerRevertPolicy,
        sessionStart: Date,
        revertTime: Date,
        now: Date
    ) -> Double? {
        switch policy {
        case .after24h:
            let elapsed = now.timeIntervalSince(sessionStart)
            return 86_400 - elapsed
        case .customTime:
            return revertTime.timeIntervalSince(now)
        case .untilQueueDone:
            return nil
        }
    }
}
