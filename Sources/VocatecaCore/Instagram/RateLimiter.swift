import Foundation

// MARK: - InstagramRate

/// Rate level for the Instagram drip-feed limiter.
///
/// Maps to the `Settings.instagramRate` YAML value `careful | normal | brisk`.
///
/// Chosen base-delay ranges (full seconds, random-uniform within):
///
/// | Level   | Base range  | Rationale                                         |
/// |---------|-------------|---------------------------------------------------|
/// | careful | 10 – 20 s   | Maximum caution; mimics infrequent manual browsing |
/// | normal  | 6 – 12 s    | gallery-dl's own recommended `sleep-request` range |
/// | brisk   | 4 –  8 s    | Faster, still within human-plausible timing        |
public enum InstagramRate: String, Sendable, CaseIterable {
    case careful
    case normal
    case brisk

    /// Base delay range in seconds for a single inter-request pause.
    public var baseRange: ClosedRange<Double> {
        switch self {
        case .careful: return 10.0 ... 20.0
        case .normal:  return  6.0 ... 12.0
        case .brisk:   return  4.0 ...  8.0
        }
    }
}

// MARK: - ActiveWindowConfig

/// Constrains requests to a slice of the clock-day, mimicking human active hours.
///
/// Outside the window `nextDelay()` returns the number of seconds until the window
/// re-opens (computed via the injected `now` clock — no real sleeping).
///
/// - `startHour` / `endHour`: values in `0 ..< 24` (24-h clock).
///   If `startHour == endHour` the constraint is treated as disabled (all hours OK).
/// - When `endHour < startHour` the window wraps midnight
///   (e.g. start=22, end=06 means 22:00 – 06:00 next day).
public struct ActiveWindowConfig: Sendable {
    public let startHour: Int
    public let endHour: Int
    /// Optional calendar used to decompose `Date` values into hour components.
    /// Defaults to the current calendar. Inject `.current` in tests when needed.
    public let calendar: Calendar

    public init(startHour: Int, endHour: Int, calendar: Calendar = .current) {
        self.startHour = startHour
        self.endHour = endHour
        self.calendar = calendar
    }

    /// Returns `true` if `date` falls inside the allowed window.
    public func isInWindow(_ date: Date) -> Bool {
        guard startHour != endHour else { return true }   // disabled
        let hour = calendar.component(.hour, from: date)
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        } else {
            // Wraps midnight.
            return hour >= startHour || hour < endHour
        }
    }

    /// Seconds from `date` until the window opens, or `0` if already inside.
    public func secondsUntilWindowOpens(from date: Date) -> TimeInterval {
        guard !isInWindow(date) else { return 0 }

        // Walk forward minute by minute up to 24 h.
        var candidate = date
        let step: TimeInterval = 60
        for _ in 0 ..< (24 * 60) {
            candidate = candidate.addingTimeInterval(step)
            if isInWindow(candidate) {
                return candidate.timeIntervalSince(date)
            }
        }
        return 24 * 3600   // safety — should never reach here
    }
}

// MARK: - RateLimiter

/// Drip-feed rate limiter for the Instagram pipeline.
///
/// ## Design
///
/// The limiter computes how long to wait **before** issuing the next request:
///
/// ```
/// nextDelay = max(windowWait, baseDelay × adaptiveMultiplier)
/// ```
///
/// where:
/// - `windowWait` is the time until the active-window opens (0 if already in it).
/// - `baseDelay` is a random value drawn from `rate.baseRange` via the injected
///   `randomDelay` closure.
/// - `adaptiveMultiplier` starts at 1.0, doubles on each `record429()` call
///   (capped at `maxMultiplier`), and decays back toward 1.0 on sustained
///   success (`recordSuccess()` divides by 1.5 after `successCountForDecay`
///   consecutive successes).
///
/// ## Determinism
///
/// All time is read through the injected `now` closure and all random delays
/// come from the injected `randomDelay` closure.  Passing a fixed clock and a
/// constant-returning closure makes every `nextDelay()` call exactly predictable
/// — the gate for "Limiter-Timing mit gemockter Uhr".
///
/// ## Pause-on-challenge
///
/// `pauseForChallenge()` marks the limiter as paused; subsequent calls to
/// `nextDelay()` return `.infinity` until `resume()` is called.
public actor RateLimiter {

    // MARK: - Constants

    /// Maximum adaptive multiplier (caps exponential backoff).
    public static let maxMultiplier: Double = 64.0
    /// Number of consecutive successes needed before the multiplier decays one step.
    public static let successCountForDecay: Int = 5
    /// Decay divisor applied to the multiplier on sustained success.
    public static let decayDivisor: Double = 1.5

    // MARK: - State

    private let rate: InstagramRate
    private let now: @Sendable () -> Date
    private let randomDelay: @Sendable (ClosedRange<Double>) -> Double
    private let activeWindow: ActiveWindowConfig?

    private var adaptiveMultiplier: Double = 1.0
    private var consecutiveSuccesses: Int = 0
    private var paused: Bool = false

    // MARK: - Init

    /// Creates a new `RateLimiter`.
    ///
    /// - Parameters:
    ///   - rate: Base delay tier (`careful | normal | brisk`).
    ///   - now: Clock injection — defaults to `Date.init` (wall clock).
    ///   - randomDelay: Random-in-range injection — defaults to `Double.random(in:)`.
    ///   - activeWindow: Optional time-of-day constraint.  `nil` = unrestricted.
    public init(
        rate: InstagramRate,
        now: @escaping @Sendable () -> Date = { Date() },
        randomDelay: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) },
        activeWindow: ActiveWindowConfig? = nil
    ) {
        self.rate = rate
        self.now = now
        self.randomDelay = randomDelay
        self.activeWindow = activeWindow
    }

    // MARK: - Core API

    /// Computes the delay (seconds) to wait before issuing the next request.
    ///
    /// Returns `.infinity` when the limiter is paused for a challenge.
    /// Returns the active-window wait when outside the allowed hours.
    /// Otherwise returns `baseDelay × adaptiveMultiplier`.
    public func nextDelay() -> TimeInterval {
        guard !paused else { return .infinity }

        let current = now()

        // Active-window gate.
        if let window = activeWindow {
            let windowWait = window.secondsUntilWindowOpens(from: current)
            if windowWait > 0 {
                return windowWait
            }
        }

        let base = randomDelay(rate.baseRange)
        return base * adaptiveMultiplier
    }

    // MARK: - Response recording

    /// Records an HTTP response by status code; routes to `record429()` on 429.
    public func recordResponse(status: Int) {
        if status == 429 {
            record429Internal()
        } else if status >= 200 && status < 300 {
            recordSuccessInternal()
        }
    }

    /// Records a 429 response: doubles the adaptive multiplier (capped).
    public func record429() {
        record429Internal()
    }

    /// Records a successful request: decays the multiplier toward 1.0 after
    /// `successCountForDecay` consecutive successes.
    public func recordSuccess() {
        recordSuccessInternal()
    }

    // MARK: - Pause / resume

    /// Returns `true` if the limiter is currently paused for a challenge.
    public func isPausedForChallenge() -> Bool {
        paused
    }

    /// Pauses the limiter.  Subsequent `nextDelay()` calls return `.infinity`.
    public func pauseForChallenge() {
        paused = true
        consecutiveSuccesses = 0
    }

    /// Resumes the limiter after a challenge has been resolved.
    public func resume() {
        paused = false
    }

    // MARK: - Adaptive multiplier inspection (for tests)

    /// Current adaptive multiplier value.
    public var currentMultiplier: Double { adaptiveMultiplier }

    // MARK: - Private helpers

    private func record429Internal() {
        consecutiveSuccesses = 0
        adaptiveMultiplier = min(adaptiveMultiplier * 2.0, Self.maxMultiplier)
    }

    private func recordSuccessInternal() {
        consecutiveSuccesses += 1
        if consecutiveSuccesses >= Self.successCountForDecay {
            consecutiveSuccesses = 0
            adaptiveMultiplier = max(1.0, adaptiveMultiplier / Self.decayDivisor)
        }
    }
}
