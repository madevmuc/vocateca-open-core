import Foundation

/// The queue-control surface the `PowerCoordinator` drives. `QueueController`
/// (UI) conforms to this; tests use a fake. `@MainActor` because the real
/// QueueController mutates `@Published` UI state.
@MainActor
public protocol QueuePowerControlling: AnyObject {
    /// Whether the queue is actively draining (an item may be in flight).
    var isRunning: Bool { get }
    /// Graceful pause — in-flight completes, no new claims.
    func pause()
    /// Resume a paused drain.
    func resume()
    /// Hard stop — cancels the worker; in-flight reverts to `pending`.
    func stop()
}

/// Reacts to power-source transitions by applying the user's `BatteryPolicy` to
/// the transcription queue. All policy logic lives in `BatteryPolicyEvaluator`;
/// this type is the thin bridge: monitor → evaluate → queue control + status.
///
/// Auto-resume only re-runs a queue **we** paused (`pausedByPolicy`), never one
/// the user stopped/paused manually.
@MainActor
public final class PowerCoordinator {

    private let monitor: PowerSourceMonitoring
    private let control: QueuePowerControlling
    /// Reads the live policy each transition (so Settings changes take effect).
    private let policyProvider: () -> BatteryPolicy
    /// Notifies the UI of an applied action + the power state (for status entries).
    private let onAction: (QueueAction, PowerState) -> Void

    private var pausedByPolicy = false

    public init(
        monitor: PowerSourceMonitoring,
        control: QueuePowerControlling,
        policyProvider: @escaping () -> BatteryPolicy,
        onAction: @escaping (QueueAction, PowerState) -> Void = { _, _ in }
    ) {
        self.monitor = monitor
        self.control = control
        self.policyProvider = policyProvider
        self.onAction = onAction
    }

    /// Start monitoring and apply the current power state immediately.
    public func start() {
        monitor.start { [weak self] state in self?.handle(state) }
        handle(monitor.currentState)
    }

    public func stop() {
        monitor.stop()
    }

    /// Evaluate a power state and apply the resulting action. Exposed for tests.
    func handle(_ state: PowerState) {
        let policy = policyProvider()
        let action = BatteryPolicyEvaluator.decide(
            policy: policy, powerState: state, hasActiveItem: control.isRunning
        )
        apply(action)
        Log.info("PowerCoordinator applied action", component: "Power",
                 context: [("state", state.rawValue), ("policy", policy.rawValue),
                           ("action", "\(action)"), ("pausedByPolicy", "\(pausedByPolicy)")])
        onAction(action, state)
    }

    private func apply(_ action: QueueAction) {
        switch action {
        case .resume:
            if pausedByPolicy {
                control.resume()
                pausedByPolicy = false
            }
        case .keepRunning:
            break
        case .finishThenPause, .pauseNow:
            if control.isRunning {
                control.pause()
                pausedByPolicy = true
            }
        case .stopAndRevert:
            if control.isRunning {
                control.stop()
                pausedByPolicy = true
            }
        }
    }
}
