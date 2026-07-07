import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Detects the machine's power source (AC vs battery) and reports live changes.
/// Kept behind a protocol so `PowerCoordinator` can be unit-tested with a fake.
public protocol PowerSourceMonitoring: AnyObject {
    /// The current power source, read on demand.
    var currentState: PowerState { get }
    /// Begin monitoring. `onChange` is delivered on the main actor on each change.
    func start(onChange: @escaping @MainActor (PowerState) -> Void)
    /// Stop monitoring.
    func stop()
}

/// IOKit-backed power monitor. Polls the providing power-source type on a
/// background timer (5 s) and emits only on change — simple and robust vs. the
/// IOPS run-loop-notification C callback. Not unit-tested (hardware/IOKit);
/// intentionally thin, with a safe `.mains` default on any read failure so the
/// queue never pauses unexpectedly.
public final class IOKitPowerMonitor: PowerSourceMonitoring {

    private let queue = DispatchQueue(label: "com.vocateca.powermonitor")
    private var timer: DispatchSourceTimer?
    private var last: PowerState
    /// When true, macOS Low Power Mode is treated as "battery".
    private let includeLowPowerMode: () -> Bool

    public init(includeLowPowerMode: @escaping () -> Bool = { false }) {
        self.includeLowPowerMode = includeLowPowerMode
        self.last = IOKitPowerMonitor.readState(includeLowPowerMode: includeLowPowerMode())
    }

    public var currentState: PowerState {
        IOKitPowerMonitor.readState(includeLowPowerMode: includeLowPowerMode())
    }

    public func start(onChange: @escaping @MainActor (PowerState) -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let state = Self.readState(includeLowPowerMode: self.includeLowPowerMode())
            guard state != self.last else { return }
            self.last = state
            Log.info("PowerMonitor: power source changed", component: "Power",
                     context: [("state", state.rawValue)])
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange(state) } }
        }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads the current power source. `.mains` on any failure (desktop / API error).
    static func readState(includeLowPowerMode: Bool) -> PowerState {
        if includeLowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .battery
        }
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else {
            return .mains
        }
        return type == (kIOPSBatteryPowerValue as String) ? .battery : .mains
        #else
        return .mains
        #endif
    }
}
