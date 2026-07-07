import Foundation

/// A read-only Instagram account-pool health report (feature D / `ig-doctor`).
/// Pure assembly from `[InstagramAccount]` so it is unit-testable; the CLI and a
/// future in-app panel render the same struct.
public struct IGDiagnosticsReport: Sendable, Equatable {

    public struct AccountLine: Sendable, Equatable {
        public let accountId: String
        public let status: String        // AccountHealthStatus rawValue
        public let lastCheck: String?
        public let failedAttempts: Int
        public let isActive: Bool
    }

    public let accounts: [AccountLine]
    /// False when any account is suspended or needs re-auth (script-friendly).
    public let healthy: Bool

    /// A short human-readable multi-line summary for the CLI / panel.
    public var summary: String {
        if accounts.isEmpty { return "Instagram: no accounts in the pool." }
        var lines = ["Instagram account pool (\(accounts.count) account(s)) — \(healthy ? "healthy" : "ATTENTION NEEDED"):"]
        for a in accounts {
            let flag = (a.status == "ok") ? "·" : "!"
            lines.append("  \(flag) \(a.accountId)  status=\(a.status)  active=\(a.isActive)  failedAttempts=\(a.failedAttempts)  lastCheck=\(a.lastCheck ?? "—")")
        }
        return lines.joined(separator: "\n")
    }
}

public enum IGDiagnostics {

    /// Assembles the report; `healthy` is false if any account is suspended or
    /// needs re-authentication (transient failures don't flip it).
    public static func assemble(accounts: [InstagramAccount]) -> IGDiagnosticsReport {
        let lines = accounts.map {
            IGDiagnosticsReport.AccountLine(
                accountId: $0.accountId,
                status: $0.healthStatus.rawValue,
                lastCheck: $0.lastHealthCheckAt,
                failedAttempts: $0.failedAttempts,
                isActive: $0.isActive
            )
        }
        let healthy = !accounts.contains {
            $0.healthStatus == .suspended || $0.healthStatus == .reauthNeeded
        }
        return IGDiagnosticsReport(accounts: lines, healthy: healthy)
    }
}
