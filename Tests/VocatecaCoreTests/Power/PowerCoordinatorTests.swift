import XCTest
@testable import VocatecaCore

/// Battery spec step 4 — `PowerCoordinator` drives the queue per power transitions.
@MainActor
final class PowerCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeMonitor: PowerSourceMonitoring {
        var currentState: PowerState
        var onChange: (@MainActor (PowerState) -> Void)?
        init(_ initial: PowerState) { currentState = initial }
        func start(onChange: @escaping @MainActor (PowerState) -> Void) { self.onChange = onChange }
        func stop() { onChange = nil }
        func emit(_ state: PowerState) {
            currentState = state
            let cb = onChange
            MainActor.assumeIsolated { cb?(state) }   // tests run on the main actor
        }
    }

    @MainActor
    private final class FakeControl: QueuePowerControlling {
        var isRunning: Bool
        var pauseCount = 0
        var resumeCount = 0
        var stopCount = 0
        init(running: Bool) { isRunning = running }
        func pause() { pauseCount += 1; isRunning = false }
        func resume() { resumeCount += 1; isRunning = true }
        func stop() { stopCount += 1; isRunning = false }
    }

    private func makeCoordinator(
        initial: PowerState, running: Bool, policy: BatteryPolicy
    ) -> (PowerCoordinator, FakeMonitor, FakeControl) {
        let monitor = FakeMonitor(initial)
        let control = FakeControl(running: running)
        let coord = PowerCoordinator(
            monitor: monitor, control: control,
            policyProvider: { policy }
        )
        return (coord, monitor, control)
    }

    // MARK: - Tests

    func testFinishThenPausePausesOnBatteryAndResumesOnMains() {
        let (coord, monitor, control) = makeCoordinator(initial: .mains, running: true, policy: .finishThenPause)
        coord.start()                        // starts on mains → no change
        XCTAssertEqual(control.pauseCount, 0)

        monitor.emit(.battery)               // → pause
        XCTAssertEqual(control.pauseCount, 1)

        monitor.emit(.mains)                 // → resume (we paused it)
        XCTAssertEqual(control.resumeCount, 1)
        XCTAssertTrue(control.isRunning)
    }

    func testMainsOnlyStopsOnBattery() {
        let (coord, monitor, control) = makeCoordinator(initial: .mains, running: true, policy: .mainsOnly)
        coord.start()
        monitor.emit(.battery)
        XCTAssertEqual(control.stopCount, 1)
        XCTAssertEqual(control.pauseCount, 0)
    }

    func testNormalNeverTouchesQueueOnBattery() {
        let (coord, monitor, control) = makeCoordinator(initial: .mains, running: true, policy: .normal)
        coord.start()
        monitor.emit(.battery)
        XCTAssertEqual(control.pauseCount, 0)
        XCTAssertEqual(control.stopCount, 0)
    }

    func testAutoResumeOnlyForPolicyPause() {
        // Queue is NOT running when battery hits → nothing to pause; pausedByPolicy stays false.
        let (coord, monitor, control) = makeCoordinator(initial: .mains, running: false, policy: .finishThenPause)
        coord.start()
        monitor.emit(.battery)
        XCTAssertEqual(control.pauseCount, 0)
        // Back on mains → must NOT resume (we never paused it).
        monitor.emit(.mains)
        XCTAssertEqual(control.resumeCount, 0)
    }

    func testStartAppliesInitialBatteryState() {
        // Initial state is battery + running + mainsOnly → start() stops immediately.
        let (coord, _, control) = makeCoordinator(initial: .battery, running: true, policy: .mainsOnly)
        coord.start()
        XCTAssertEqual(control.stopCount, 1)
    }
}
