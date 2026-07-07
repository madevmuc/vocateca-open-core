import XCTest
@testable import VocatecaCore

/// Tests for the shared `withTimeout` helper (H6) that bounds each engine's
/// lazy model load/download. Timings are deliberately tiny so the suite stays
/// fast and deterministic.
final class TimeoutTests: XCTestCase {

    // MARK: - Fast operation returns its value

    func testReturnsValueWhenOperationBeatsTimeout() async throws {
        let result = try await withTimeout(seconds: 5.0) {
            42
        }
        XCTAssertEqual(result, 42)
    }

    func testReturnsValueForBriefWorkUnderDeadline() async throws {
        let result: String = try await withTimeout(seconds: 5.0) {
            try await Task.sleep(nanoseconds: 10_000_000)   // 10 ms << 5 s
            return "done"
        }
        XCTAssertEqual(result, "done")
    }

    // MARK: - Slow operation times out

    func testThrowsTimeoutErrorWhenOperationExceedsDeadline() async {
        do {
            _ = try await withTimeout(seconds: 0.05) {
                // Would take ~10 s — far past the 50 ms deadline. The timeout
                // fires and cancels this sleep.
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return 1
            }
            XCTFail("expected a TimeoutError")
        } catch let timeout as TimeoutError {
            XCTAssertEqual(timeout.seconds, 0.05, accuracy: 0.0001)
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    func testTimeoutErrorDescriptionMentionsSeconds() {
        XCTAssertEqual(TimeoutError(seconds: 600).description,
                       "operation timed out after 600s")
    }

    // MARK: - Non-positive deadline disables the timeout

    func testNonPositiveDeadlineRunsOperationToCompletion() async throws {
        // A 0 (or negative) deadline must NOT instantly fail — it disables the
        // timeout so a misconfigured value never fails every load.
        let zero = try await withTimeout(seconds: 0) { 7 }
        XCTAssertEqual(zero, 7)
        let negative = try await withTimeout(seconds: -1) { 9 }
        XCTAssertEqual(negative, 9)
    }

    // MARK: - Operation errors propagate unchanged

    func testOperationErrorPropagates() async {
        struct Boom: Error, Equatable {}
        do {
            _ = try await withTimeout(seconds: 5.0) { throw Boom() }
            XCTFail("expected Boom")
        } catch is TimeoutError {
            XCTFail("should have surfaced the operation's own error, not a timeout")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Model-load timeout constant

    func testModelLoadTimeoutIsTenMinutes() {
        XCTAssertEqual(modelLoadTimeoutSeconds, 600, accuracy: 0.0001)
    }
}
