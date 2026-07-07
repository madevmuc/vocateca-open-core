import XCTest
@testable import VocatecaCore

/// Regression tests for `Subprocess` — especially the large-output pipe-drain
/// path that previously deadlocked (output read only in `terminationHandler`,
/// which never fired once the child blocked on a full OS pipe buffer).
final class SubprocessTests: XCTestCase {

    /// CRITICAL regression: a child that writes far more than the OS pipe buffer
    /// (~64 KB) must NOT deadlock — both pipes are drained concurrently while the
    /// process runs, so the full payload comes back intact.
    func testLargeStdoutDoesNotDeadlock() async throws {
        // ~1 MB of deterministic data via a temp file + /bin/cat.
        let line = String(repeating: "x", count: 1023) + "\n"  // 1 KB/line
        let payload = String(repeating: line, count: 1024)       // ~1 MB
        XCTAssertGreaterThan(payload.utf8.count, 1_000_000)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("subprocess-large-\(UUID().uuidString).txt")
        try payload.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await Subprocess().run(
            URL(fileURLWithPath: "/bin/cat"), [tmp.path], timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, payload.utf8.count,
                       "large stdout was truncated — pipe drain regression")
        XCTAssertEqual(result.stdout, payload)
    }

    /// Large output on BOTH stdout and stderr concurrently (the classic deadlock:
    /// child blocks writing stderr while we only drain stdout, or vice versa).
    func testLargeStdoutAndStderrConcurrently() async throws {
        // sh: write ~512 KB to stdout and ~512 KB to stderr interleaved.
        let script = """
        n=0
        while [ $n -lt 512 ]; do
          printf '%01024d' $n
          printf '%01024d' $n 1>&2
          n=$((n+1))
        done
        """
        let result = try await Subprocess().run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 512 * 1024)
        XCTAssertEqual(result.stderr.utf8.count, 512 * 1024)
    }

    func testExitCodeAndStderrCaptured() async throws {
        let result = try await Subprocess().run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err 1>&2; exit 3"],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    /// A long-running child must be terminated at the timeout (and not hang).
    func testTimeoutTerminatesChild() async throws {
        let start = Date()
        do {
            _ = try await Subprocess().run(
                URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 1
            )
            XCTFail("expected a timeout error")
        } catch let SubprocessError.timedOut(url, _) {
            XCTAssertEqual(url.path, "/bin/sleep")
        }
        // Should return promptly after the 1s timeout, not after 30s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testLaunchFailureThrows() async throws {
        do {
            _ = try await Subprocess().run(
                URL(fileURLWithPath: "/nonexistent/binary-xyz"), [], timeout: 5
            )
            XCTFail("expected a launch failure")
        } catch is SubprocessError {
            // ok — launchFailed
        }
    }
}
