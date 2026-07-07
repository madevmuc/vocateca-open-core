import Foundation

// MARK: - AccountHealthStatus

/// Health state of a dedicated Instagram account.
///
/// Mirrors the `health_status` column in `instagram_account_pool` and the
/// four states specified in the "Account-Health & Recovery" design section.
///
/// Raw values are the database/YAML string representations.
public enum AccountHealthStatus: String, Sendable, Equatable, CaseIterable {
    /// Cookies valid, fetches proceeding normally.
    case ok = "ok"
    /// Session expired or invalidated — same account, needs fresh cookies.
    case reauthNeeded = "re_auth_needed"
    /// Checkpoint unresolvable or repeated failures after re-auth —
    /// a different account is required.
    case suspended = "suspended"
    /// Transient rate-limit (HTTP 429 or equivalent) — automatic backoff,
    /// no user alarm required.
    case transient = "transient"
}

// MARK: - AccountHealthClassifier

/// Classifies gallery-dl error signals into ``AccountHealthStatus`` values and
/// implements the escalation ladder.
///
/// ## Classification phrases (best-effort pattern matching)
///
/// The classifier inspects the lowercased `errorText` for known substrings and
/// the `httpStatus` code.  Unrecognised signals fall through to `.ok` (safe
/// default — the caller decides what to do with an unexpected state).
///
/// ## Escalation thresholds (greenfield decision)
///
/// | Current state   | `failedAttempts` threshold | → escalates to |
/// |-----------------|---------------------------|----------------|
/// | `.transient`    | ≥ 3  (auto-backoff only)  | `.transient`   |
/// | `.transient`    | ≥ 10 (repeated 429s)      | `.reauthNeeded`|
/// | `.reauthNeeded` | ≥ 3                       | `.suspended`   |
/// | `.suspended`    | any                       | `.suspended`   |
/// | `.ok`           | any                       | `.ok`          |
///
/// Rationale: 3 transient failures before re-auth avoids premature alarms for
/// short bursts; 10 unresolved 429s signals a deeper block.  3 re-auth failures
/// after the user refreshed cookies signals the account is truly compromised.
public enum AccountHealthClassifier {

    // MARK: - Classification phrases

    private static let reauthPhrases: [String] = [
        "login required",
        "login_required",
        "not logged in",
        "401",
        "session expired",
        "session invalid",
        "session_invalid",
        "checkpoint_required",
        "checkpoint required",
        "two factor",
        "2fa",
        "authentication required",
        "please log in",
    ]

    private static let suspendedPhrases: [String] = [
        "account disabled",
        "account suspended",
        "account banned",
        "this account has been disabled",
        "your account has been disabled",
        "violates our terms",
        "permanently banned",
    ]

    // MARK: - Primary classification

    /// Classifies a single gallery-dl response into an ``AccountHealthStatus``.
    ///
    /// Priority order (first match wins):
    /// 1. HTTP 429 → `.transient`
    /// 2. Suspension phrases in `errorText` → `.suspended`
    /// 3. Re-auth / checkpoint phrases → `.reauthNeeded`
    /// 4. Fallthrough → `.ok`
    ///
    /// - Parameters:
    ///   - errorText: The error string from gallery-dl output (may be empty).
    ///   - httpStatus: The HTTP status code; `nil` if not applicable.
    public static func classify(errorText: String, httpStatus: Int?) -> AccountHealthStatus {
        if httpStatus == 429 {
            return .transient
        }

        let lower = errorText.lowercased()

        if suspendedPhrases.contains(where: { lower.contains($0) }) {
            return .suspended
        }

        if reauthPhrases.contains(where: { lower.contains($0) }) {
            return .reauthNeeded
        }

        return .ok
    }

    // MARK: - Escalation

    /// Applies the escalation ladder given the current health state and the
    /// number of consecutive failed attempts for that account.
    ///
    /// This is a **pure function** — it returns the new state without side effects.
    ///
    /// Thresholds (see type-level documentation table):
    /// - `.transient` + `failedAttempts >= 10` → `.reauthNeeded`
    /// - `.reauthNeeded` + `failedAttempts >= 3` → `.suspended`
    /// - All other combinations → `current` unchanged
    ///
    /// - Parameters:
    ///   - current: Current health state of the account.
    ///   - failedAttempts: Total consecutive failed attempts in this state.
    public static func escalate(
        current: AccountHealthStatus,
        failedAttempts: Int
    ) -> AccountHealthStatus {
        switch current {
        case .transient:
            if failedAttempts >= 10 {
                return .reauthNeeded
            }
            return .transient

        case .reauthNeeded:
            if failedAttempts >= 3 {
                return .suspended
            }
            return .reauthNeeded

        case .ok, .suspended:
            return current
        }
    }

    // MARK: - Escalation thresholds (public constants for tests)

    /// `failedAttempts` threshold at which `.transient` escalates to `.reauthNeeded`.
    public static let transientToReauthThreshold: Int = 10
    /// `failedAttempts` threshold at which `.reauthNeeded` escalates to `.suspended`.
    public static let reauthToSuspendedThreshold: Int = 3
}
