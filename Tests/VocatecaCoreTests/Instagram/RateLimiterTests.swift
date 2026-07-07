import XCTest
@testable import VocatecaCore

/// Tests for ``RateLimiter`` — THE gate for deterministic timing.
///
/// All tests inject a fixed `now` closure and a constant-returning `randomDelay`
/// closure so every computed delay is exactly predictable.  No real `sleep` calls
/// are made.
final class RateLimiterTests: XCTestCase {

    // MARK: - Helpers

    /// Fixed epoch date used as the injected clock in tests.
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// Creates a `RateLimiter` with a fixed clock and a constant random-delay stub.
    private func makeLimiter(
        rate: InstagramRate,
        constantDelay: Double,
        activeWindow: ActiveWindowConfig? = nil
    ) -> RateLimiter {
        RateLimiter(
            rate: rate,
            now: { Self.fixedNow },
            randomDelay: { _ in constantDelay },
            activeWindow: activeWindow
        )
    }

    // MARK: - Per-rate-level base delay

    func testCarefulBaseDelay() async {
        let limiter = makeLimiter(rate: .careful, constantDelay: 15.0)
        let delay = await limiter.nextDelay()
        // constantDelay=15.0, multiplier=1.0 → expect exactly 15.0
        XCTAssertEqual(delay, 15.0, accuracy: 1e-9)
    }

    func testNormalBaseDelay() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 9.0)
        let delay = await limiter.nextDelay()
        XCTAssertEqual(delay, 9.0, accuracy: 1e-9)
    }

    func testBriskBaseDelay() async {
        let limiter = makeLimiter(rate: .brisk, constantDelay: 6.0)
        let delay = await limiter.nextDelay()
        XCTAssertEqual(delay, 6.0, accuracy: 1e-9)
    }

    // MARK: - Rate ranges

    func testCarefulRangeValues() {
        XCTAssertEqual(InstagramRate.careful.baseRange, 10.0 ... 20.0)
    }

    func testNormalRangeValues() {
        XCTAssertEqual(InstagramRate.normal.baseRange, 6.0 ... 12.0)
    }

    func testBriskRangeValues() {
        XCTAssertEqual(InstagramRate.brisk.baseRange, 4.0 ... 8.0)
    }

    // MARK: - Active-window gating

    /// The fixed epoch 2023-11-15 corresponds to 06:13 UTC.
    /// A window of 08:00–22:00 UTC means we are currently OUTSIDE.
    func testActiveWindowGatingOutsideWindow() async {
        // fixedNow is 06:13 UTC — outside 08:00–22:00
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let window = ActiveWindowConfig(startHour: 8, endHour: 22, calendar: utcCalendar)
        let limiter = makeLimiter(rate: .normal, constantDelay: 9.0, activeWindow: window)
        let delay = await limiter.nextDelay()

        // We are at 06:13 UTC; window opens at 08:00 → wait ≈ 1h47m = 6420 s.
        // The exact value depends on the number of seconds until the next :00 minute
        // boundary. We only verify it is positive and greater than 60 s.
        XCTAssertGreaterThan(delay, 60.0,
            "Outside the active window the delay should be the wait until window opens (>>60 s)")
        XCTAssertLessThanOrEqual(delay, 24 * 3600,
            "Wait should never exceed 24 h")
    }

    func testActiveWindowGatingInsideWindow() async {
        // Move the clock into the window (14:00 UTC = 50400 s after midnight).
        // Build a date that falls on hour=14.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 15
        comps.hour = 14; comps.minute = 0; comps.second = 0
        let insideDate = utcCalendar.date(from: comps)!
        let window = ActiveWindowConfig(startHour: 8, endHour: 22, calendar: utcCalendar)

        let limiter = RateLimiter(
            rate: .normal,
            now: { insideDate },
            randomDelay: { _ in 9.0 },
            activeWindow: window
        )
        let delay = await limiter.nextDelay()
        // Inside the window → base delay applies, no window wait.
        XCTAssertEqual(delay, 9.0, accuracy: 1e-9)
    }

    // MARK: - Adaptive backoff: 429 sequence

    func testAdaptiveBackoffDoubles() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)

        // Initial delay.
        let d0 = await limiter.nextDelay()
        XCTAssertEqual(d0, 6.0, accuracy: 1e-9, "Initial: 6.0 × 1.0")

        // After first 429.
        await limiter.record429()
        let d1 = await limiter.nextDelay()
        XCTAssertEqual(d1, 12.0, accuracy: 1e-9, "After 1st 429: 6.0 × 2.0")

        // After second 429.
        await limiter.record429()
        let d2 = await limiter.nextDelay()
        XCTAssertEqual(d2, 24.0, accuracy: 1e-9, "After 2nd 429: 6.0 × 4.0")

        // After third 429.
        await limiter.record429()
        let d3 = await limiter.nextDelay()
        XCTAssertEqual(d3, 48.0, accuracy: 1e-9, "After 3rd 429: 6.0 × 8.0")
    }

    func testAdaptiveBackoffCappedAtMaxMultiplier() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)

        // Drive multiplier to the cap: start=1, need log2(64)=6 doublings.
        for _ in 0 ..< 10 {
            await limiter.record429()
        }
        let multiplier = await limiter.currentMultiplier
        XCTAssertEqual(multiplier, RateLimiter.maxMultiplier,
                       "Multiplier must be capped at maxMultiplier (\(RateLimiter.maxMultiplier))")

        let delay = await limiter.nextDelay()
        XCTAssertEqual(delay, 6.0 * RateLimiter.maxMultiplier, accuracy: 1e-9)
    }

    // MARK: - Adaptive decay on success

    func testSuccessDecayAfterThreshold() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)

        // One 429 → multiplier = 2.
        await limiter.record429()
        let afterBackoff = await limiter.currentMultiplier
        XCTAssertEqual(afterBackoff, 2.0, accuracy: 1e-9)

        // Record successCountForDecay−1 successes — multiplier must NOT decay yet.
        for _ in 0 ..< (RateLimiter.successCountForDecay - 1) {
            await limiter.recordSuccess()
        }
        let beforeDecay = await limiter.currentMultiplier
        XCTAssertEqual(beforeDecay, 2.0, accuracy: 1e-9,
                       "Multiplier must not decay before successCountForDecay successes")

        // One more success → decay step fires.
        await limiter.recordSuccess()
        let afterDecay = await limiter.currentMultiplier
        // Expected: max(1.0, 2.0 / 1.5) ≈ 1.3333…
        let expected = max(1.0, 2.0 / RateLimiter.decayDivisor)
        XCTAssertEqual(afterDecay, expected, accuracy: 1e-9,
                       "After successCountForDecay successes, multiplier should decay by decayDivisor")
    }

    func testSuccessDecayNeverBelowOne() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)

        // Fire many successes on a fresh limiter (multiplier starts at 1.0).
        for _ in 0 ..< (RateLimiter.successCountForDecay * 5) {
            await limiter.recordSuccess()
        }
        let m = await limiter.currentMultiplier
        XCTAssertGreaterThanOrEqual(m, 1.0, "Multiplier must never decay below 1.0")
    }

    // MARK: - recordResponse routing

    func testRecordResponse429RoutesCorrectly() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)
        await limiter.recordResponse(status: 429)
        let m = await limiter.currentMultiplier
        XCTAssertEqual(m, 2.0, accuracy: 1e-9, "429 response must trigger backoff")
    }

    func testRecordResponse200RoutesCorrectly() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)

        // Put multiplier at 2.0 first.
        await limiter.record429()

        // Record successCountForDecay successes via recordResponse.
        for _ in 0 ..< RateLimiter.successCountForDecay {
            await limiter.recordResponse(status: 200)
        }
        let m = await limiter.currentMultiplier
        // Should have decayed at least once.
        XCTAssertLessThan(m, 2.0, "200 response must eventually decay the multiplier")
    }

    // MARK: - Pause / resume

    func testPauseReturnsInfinity() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 9.0)

        let before = await limiter.nextDelay()
        XCTAssertFalse(before.isInfinite, "Not paused yet — delay must be finite")

        await limiter.pauseForChallenge()
        let paused = await limiter.nextDelay()
        XCTAssertTrue(paused.isInfinite, "Paused limiter must return .infinity")
        let isPaused = await limiter.isPausedForChallenge()
        XCTAssertTrue(isPaused)
    }

    func testResumeRestoresNormalDelay() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 9.0)
        await limiter.pauseForChallenge()
        await limiter.resume()

        let delay = await limiter.nextDelay()
        XCTAssertFalse(delay.isInfinite, "Resumed limiter must return finite delay")
        let isPaused = await limiter.isPausedForChallenge()
        XCTAssertFalse(isPaused)
        XCTAssertEqual(delay, 9.0, accuracy: 1e-9)
    }

    func testPauseClearsConsecutiveSuccesses() async {
        let limiter = makeLimiter(rate: .normal, constantDelay: 6.0)

        // Accumulate successes close to threshold.
        for _ in 0 ..< (RateLimiter.successCountForDecay - 1) {
            await limiter.recordSuccess()
        }

        // Pausing must reset consecutive success counter.
        await limiter.pauseForChallenge()
        await limiter.resume()

        // Now record exactly threshold−1 more — multiplier must not decay
        // (counter reset by pause means we start fresh).
        await limiter.record429()  // set multiplier to 2.0
        for _ in 0 ..< (RateLimiter.successCountForDecay - 1) {
            await limiter.recordSuccess()
        }
        let m = await limiter.currentMultiplier
        XCTAssertEqual(m, 2.0, accuracy: 1e-9,
                       "Counter reset by pause: decay must not fire before threshold")
    }
}
