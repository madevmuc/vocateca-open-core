import XCTest
@testable import VocatecaCore

// MARK: - NextStepSuggestionTests
//
// TDD for the Shows pane's persistent „Nächster Schritt"-Leiste decision
// logic (post-subscribe-nba brief §2). Pure function — no DB, no UI.

final class NextStepSuggestionTests: XCTestCase {

    // MARK: - Hidden: no pending work

    func testHiddenWhenNoPendingEpisodes() {
        let state = NextStepSuggestion.compute(
            pendingCount: 0,
            pendingNewestAt: nil,
            dismissedFingerprint: nil,
            queueRunning: false
        )
        XCTAssertEqual(state, .hidden, "Zero pending episodes must never show the bar")
    }

    // MARK: - Hidden: queue already running

    func testHiddenWhenQueueIsRunning() {
        let state = NextStepSuggestion.compute(
            pendingCount: 5,
            pendingNewestAt: "2026-07-04T10:00:00Z",
            dismissedFingerprint: nil,
            queueRunning: true
        )
        XCTAssertEqual(state, .hidden, "The bar's CTA is redundant while the queue is already processing")
    }

    // MARK: - Visible: pending work, queue stopped, nothing dismissed

    func testVisibleWithPendingWorkAndQueueStopped() {
        let state = NextStepSuggestion.compute(
            pendingCount: 7,
            pendingNewestAt: "2026-07-04T10:00:00Z",
            dismissedFingerprint: nil,
            queueRunning: false
        )
        XCTAssertEqual(state, .visible(pendingCount: 7, etaMinutes: nil))
    }

    // MARK: - Visible carries through the ETA when supplied

    func testVisibleCarriesETAWhenSupplied() {
        let state = NextStepSuggestion.compute(
            pendingCount: 3,
            pendingNewestAt: "2026-07-04T10:00:00Z",
            dismissedFingerprint: nil,
            queueRunning: false,
            etaMinutes: 18
        )
        XCTAssertEqual(state, .visible(pendingCount: 3, etaMinutes: 18))
    }

    // MARK: - Hidden: this exact batch was already dismissed

    func testHiddenWhenBatchFingerprintMatchesDismissed() {
        let fp = NextStepSuggestion.fingerprint(pendingCount: 4, pendingNewestAt: "2026-07-04T10:00:00Z")
        let state = NextStepSuggestion.compute(
            pendingCount: 4,
            pendingNewestAt: "2026-07-04T10:00:00Z",
            dismissedFingerprint: fp,
            queueRunning: false
        )
        XCTAssertEqual(state, .hidden, "Dismissing a batch must hide the bar for that exact batch")
    }

    // MARK: - Visible again: a NEW episode arrives after dismissal (count changes)

    func testVisibleAgainWhenPendingCountChangesAfterDismissal() {
        let dismissed = NextStepSuggestion.fingerprint(pendingCount: 4, pendingNewestAt: "2026-07-04T10:00:00Z")
        // A 5th episode has since arrived — same newest-at is impossible in
        // practice (a new episode would also be newer), but count alone
        // already suffices to prove the re-show behaviour.
        let state = NextStepSuggestion.compute(
            pendingCount: 5,
            pendingNewestAt: "2026-07-04T10:00:00Z",
            dismissedFingerprint: dismissed,
            queueRunning: false
        )
        XCTAssertEqual(state, .visible(pendingCount: 5, etaMinutes: nil),
                       "A changed pending count must produce a new fingerprint and re-show the bar")
    }

    // MARK: - Visible again: newest-at changes while count is unchanged (a wash)

    func testVisibleAgainWhenNewestAtChangesWithSameCount() {
        let dismissed = NextStepSuggestion.fingerprint(pendingCount: 4, pendingNewestAt: "2026-07-04T10:00:00Z")
        // One episode finished (left the pending set) while a new one arrived
        // (entered it) — the COUNT nets out unchanged, but the newest pub-date
        // moved, so this must still read as a new batch.
        let state = NextStepSuggestion.compute(
            pendingCount: 4,
            pendingNewestAt: "2026-07-05T09:00:00Z",
            dismissedFingerprint: dismissed,
            queueRunning: false
        )
        XCTAssertEqual(state, .visible(pendingCount: 4, etaMinutes: nil),
                       "A changed newest-pub-date (count-neutral wash) must still re-show the bar")
    }

    // MARK: - Fingerprint determinism + uniqueness

    func testFingerprintIsDeterministic() {
        let a = NextStepSuggestion.fingerprint(pendingCount: 10, pendingNewestAt: "2026-07-04")
        let b = NextStepSuggestion.fingerprint(pendingCount: 10, pendingNewestAt: "2026-07-04")
        XCTAssertEqual(a, b)
    }

    func testFingerprintDiffersOnCount() {
        let a = NextStepSuggestion.fingerprint(pendingCount: 10, pendingNewestAt: "2026-07-04")
        let b = NextStepSuggestion.fingerprint(pendingCount: 11, pendingNewestAt: "2026-07-04")
        XCTAssertNotEqual(a, b)
    }

    func testFingerprintDiffersOnNewestAt() {
        let a = NextStepSuggestion.fingerprint(pendingCount: 10, pendingNewestAt: "2026-07-04")
        let b = NextStepSuggestion.fingerprint(pendingCount: 10, pendingNewestAt: "2026-07-05")
        XCTAssertNotEqual(a, b)
    }

    func testFingerprintHandlesNilNewestAt() {
        // Should not crash and should be stable/distinct from a non-nil value.
        let withNil = NextStepSuggestion.fingerprint(pendingCount: 0, pendingNewestAt: nil)
        let withEmpty = NextStepSuggestion.fingerprint(pendingCount: 0, pendingNewestAt: "")
        XCTAssertEqual(withNil, withEmpty, "nil and empty-string newestAt fold to the same fingerprint")
    }

    // MARK: - Queue-running takes precedence over an un-dismissed batch

    func testQueueRunningHidesEvenWithFreshUndismissedBatch() {
        let state = NextStepSuggestion.compute(
            pendingCount: 20,
            pendingNewestAt: "2026-07-05T00:00:00Z",
            dismissedFingerprint: "totally-unrelated-fingerprint",
            queueRunning: true
        )
        XCTAssertEqual(state, .hidden)
    }

    // MARK: - estimatedTotalMinutes (UX Wave 7 §1: real ETA, seconds→minutes)

    func testEstimatedTotalMinutesNilWhenNoAverageYet() {
        XCTAssertNil(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: nil, pendingCount: 5),
                     "No measured/live estimate yet must omit the ETA, not show a bogus 0")
    }

    func testEstimatedTotalMinutesNilWhenNoPendingWork() {
        XCTAssertNil(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 372, pendingCount: 0))
    }

    func testEstimatedTotalMinutesRoundsToNearestMinute() {
        // 372s/ep × 3 = 1116s = 18.6min → rounds to 19.
        XCTAssertEqual(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 372, pendingCount: 3), 19)
    }

    func testEstimatedTotalMinutesRoundsDownJustBelowHalf() {
        // 60s/ep × 1 = 60s = 1.0min exactly → 1.
        XCTAssertEqual(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 60, pendingCount: 1), 1)
        // 89s = 1.483min → rounds to 1.
        XCTAssertEqual(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 89, pendingCount: 1), 1)
        // 91s = 1.516min → rounds to 2.
        XCTAssertEqual(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 91, pendingCount: 1), 2)
    }

    func testEstimatedTotalMinutesNeverZeroForNonzeroEstimate() {
        // 10s/ep × 1 = 10s = 0.17min → rounds to 0, but a nonzero remaining
        // run must never show "(≈ 0 Min)" — floors to 1.
        XCTAssertEqual(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 10, pendingCount: 1), 1)
    }

    func testEstimatedTotalMinutesScalesWithPendingCount() {
        XCTAssertEqual(NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 60, pendingCount: 10), 10)
    }

    func testEstimatedTotalMinutesFeedsDirectlyIntoCompute() {
        // Integration of the two pure functions: the bar's visible state
        // should carry exactly what estimatedTotalMinutes produced.
        let eta = NextStepSuggestion.estimatedTotalMinutes(avgSecondsPerEpisode: 372, pendingCount: 4)
        let state = NextStepSuggestion.compute(
            pendingCount: 4,
            pendingNewestAt: "2026-07-05T00:00:00Z",
            dismissedFingerprint: nil,
            queueRunning: false,
            etaMinutes: eta
        )
        XCTAssertEqual(state, .visible(pendingCount: 4, etaMinutes: 25)) // 1488s = 24.8min → 25
    }
}
