import Foundation

/// Live power source of the machine.
public enum PowerState: String, Sendable, Equatable {
    case mains
    case battery
}

/// User-facing policy for how the transcription queue behaves on battery.
/// Raw values are the persisted `settings.yaml` strings.
public enum BatteryPolicy: String, Sendable, Equatable, CaseIterable {
    /// Default. On battery: let the in-flight item finish, then pause (claim no new).
    case finishThenPause = "finish_then_pause"
    /// Run on battery and mains alike.
    case normal = "normal"
    /// On battery: pause immediately; the in-flight item is cancelled → `pending`.
    case mainsOnly = "mains_only"

    public static let `default`: BatteryPolicy = .finishThenPause
}

/// What the queue should do in response to a power/policy evaluation.
///
/// Mapping to `QueueController` (done by the coordinator, not here):
/// - `.resume`          → `resume()` / `start()`
/// - `.keepRunning`     → no-op (already running)
/// - `.finishThenPause` → `pause()` (graceful; an item is finishing)
/// - `.pauseNow`        → `pause()` (graceful; nothing in flight)
/// - `.stopAndRevert`   → `stop()`  (hard cancel; in-flight reverts to `pending`)
public enum QueueAction: Sendable, Equatable {
    case resume
    case keepRunning
    case finishThenPause
    case pauseNow
    case stopAndRevert
}

/// Pure policy decision — the single place battery/power logic lives.
public enum BatteryPolicyEvaluator {

    /// Decide the queue action for a given policy, power state, and whether an
    /// item is currently transcribing.
    ///
    /// - On **mains**: always `.resume` (re-run if we had paused; no-op otherwise).
    /// - On **battery**:
    ///   - `.normal` → `.keepRunning`
    ///   - `.finishThenPause` → `.finishThenPause` when an item is in flight, else `.pauseNow`
    ///   - `.mainsOnly` → `.stopAndRevert`
    public static func decide(
        policy: BatteryPolicy,
        powerState: PowerState,
        hasActiveItem: Bool
    ) -> QueueAction {
        switch powerState {
        case .mains:
            return .resume
        case .battery:
            switch policy {
            case .normal:
                return .keepRunning
            case .finishThenPause:
                return hasActiveItem ? .finishThenPause : .pauseNow
            case .mainsOnly:
                return .stopAndRevert
            }
        }
    }
}
