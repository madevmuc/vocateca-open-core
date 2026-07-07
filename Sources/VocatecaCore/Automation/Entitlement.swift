import Foundation

// MARK: - EntitlementStatus

/// The entitlement state of a Pro subscription, mirroring the `pro_entitlement_status`
/// setting values from the Python Settings model.
public enum EntitlementStatus: String, Sendable, Codable {
    case active
    case expired
    case cancelled
    case unknown
}

// MARK: - EntitlementProvider

/// Source-of-truth for the current Pro entitlement. Implementations may read
/// from a local cache, from Settings, or from a hosted backend. The concrete
/// backend-backed provider lives in the proprietary Vocateca app, not here.
public protocol EntitlementProvider: Sendable {
    func current() async -> EntitlementStatus
}

// MARK: - LocalStubEntitlementProvider

/// Phase-3 local stub. Returns a fixed status given at init.
///
/// Default is `.active` for development convenience. Pass `.unknown` to test
/// the fail-open grace path, or `.expired`/`.cancelled` to test the gate.
///
/// In the proprietary app this stub is replaced by a real backend-backed provider.
public struct LocalStubEntitlementProvider: EntitlementProvider {

    private let status: EntitlementStatus

    public init(status: EntitlementStatus = .active) {
        self.status = status
    }

    public func current() async -> EntitlementStatus {
        return status
    }
}

// MARK: - isAutomationAllowed

/// Returns `true` when the entitlement status permits the automation runner to start.
///
/// ## Fail-open semantics (freemium rule)
///
/// The automation runner fails **open**: if the entitlement server is unreachable,
/// the cached status is `.unknown`, and `.unknown` is treated as allowed. This
/// ensures a temporary network outage never silently disables automation for a
/// paying user.
///
/// Only when the subscription is definitively not active (`.expired` or `.cancelled`)
/// does the automation runner pause. Manual paths in `VocatecaCore` are always
/// available regardless of entitlement — only the automation runner is gated.
///
/// | Status       | Automation allowed | Reason                            |
/// |--------------|-------------------|-----------------------------------|
/// | `.active`    | YES               | Valid Pro subscription            |
/// | `.unknown`   | YES (fail-open)   | Server unreachable — grace mode   |
/// | `.expired`   | NO                | Subscription definitively ended   |
/// | `.cancelled` | NO                | Subscription definitively ended   |
///
/// This matches the spec: "fail-open: server weg → weiterlaufen;
/// eindeutig nicht berechtigt → Automatik pausiert".
public func isAutomationAllowed(_ status: EntitlementStatus) -> Bool {
    switch status {
    case .active, .unknown:
        return true
    case .expired, .cancelled:
        return false
    }
}
