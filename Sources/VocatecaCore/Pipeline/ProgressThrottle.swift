import Foundation

// MARK: - ProgressThrottle
//
// Coalesces an ASR progress firehose down to a UI-useful rate.
//
// WhisperKit invokes its `TranscriptionCallback` once per decoded TOKEN (see
// `TextDecoder.decodeText`, which fires the callback from inside the decoding
// loop), not once per 30 s window. On a 2 h episode that is O(10^4–10^5) calls,
// each of which used to emit an `episode.progress` event AND write a SQLite job
// heartbeat. Two things went wrong with that:
//
//   * `PipelineEventEmitter`'s buffer was `.unbounded`, so when its single
//     consumer task was starved (the cooperative pool saturated by the decode
//     plus WhisperKit's per-token `Task.detached` callbacks) the queued events
//     grew without limit — an out-of-application-memory incident with tens of GB
//     resident on 2026-07-16.
//   * A synchronous SQLite write per token put real I/O on the decode's hot path.
//
// The bar only needs to move a few times per second, so gate on BOTH a minimum
// fraction delta and a minimum interval. Terminal-ish values are never throttled:
// `force` lets a caller push the final fraction through unconditionally.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minDelta: Double
    private let minInterval: TimeInterval
    private var lastFraction = -Double.infinity
    private var lastEmit = Date.distantPast

    /// - Parameters:
    ///   - minDelta: Minimum change in the 0…1 fraction before re-emitting.
    ///   - minInterval: Minimum wall-clock gap between emissions.
    init(minDelta: Double = 0.002, minInterval: TimeInterval = 0.25) {
        self.minDelta = minDelta
        self.minInterval = minInterval
    }

    /// Returns `true` when `fraction` should be emitted. Advancing backwards is
    /// reported (a re-run legitimately rewinds the bar), hence `abs`.
    func shouldEmit(_ fraction: Double, force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard !force else {
            lastFraction = fraction
            lastEmit = now
            return true
        }
        guard abs(fraction - lastFraction) >= minDelta,
              now.timeIntervalSince(lastEmit) >= minInterval else { return false }
        lastFraction = fraction
        lastEmit = now
        return true
    }
}

// MARK: - HeartbeatThrottle

/// Gates the per-episode job heartbeat. The ownership row only needs to look
/// fresh relative to the reclaim window, so one write every `interval` seconds is
/// plenty — versus one SQLite write per decoded token before this existed.
final class HeartbeatThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(interval: TimeInterval = 30) { self.interval = interval }

    func shouldBeat() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
