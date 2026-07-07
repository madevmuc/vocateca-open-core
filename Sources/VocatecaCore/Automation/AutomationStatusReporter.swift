import Foundation

/// Reads/writes the single `AutomationStatus` blob in StateStore meta — the one
/// source of truth for the menu bar, the Settings status card, and `vocateca-cli status`.
public struct AutomationStatusReporter: Sendable {
    private let store: StateStore
    public init(store: StateStore) { self.store = store }

    public func write(_ status: AutomationStatus) throws {
        guard let json = status.encoded() else { return }
        try store.setMeta(key: AutomationStatus.metaKey, value: json)
        Log.debug("Automation status written", component: "Automation",
                  context: [("skip", status.lastSkipReason.rawValue),
                             ("done", "\(status.done)"), ("failed", "\(status.failed)")])
    }

    /// Returns the persisted status, or a default (`.ok`, no runs) when absent/corrupt.
    public func read() throws -> AutomationStatus {
        guard let json = try store.metaValue(AutomationStatus.metaKey),
              let status = AutomationStatus.decode(json) else { return AutomationStatus() }
        return status
    }
}
