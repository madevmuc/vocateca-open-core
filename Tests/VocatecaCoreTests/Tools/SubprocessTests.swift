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

    // MARK: - PATH hardening (2026-07-16: GUI-launch minimal-PATH fix)

    /// With no explicit override, the spawned env's PATH must be led by the
    /// Homebrew/MacPorts/managed tool dirs so a child tool (and its children,
    /// e.g. yt-dlp → ffmpeg) can find binaries the login shell would see but a
    /// Finder-launched app's minimal PATH would not.
    func testResolvedEnvironmentPrependsToolDirs() {
        let env = Subprocess.resolvedEnvironment(nil)
        let path = env["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(dirs.prefix(Subprocess.toolSearchDirs.count)),
                       Subprocess.toolSearchDirs,
                       "tool dirs must lead PATH; got \(path)")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
    }

    /// PATH entries are de-duplicated (a tool dir already present in the login
    /// PATH must not appear twice).
    func testResolvedEnvironmentDeduplicatesPath() {
        let env = Subprocess.resolvedEnvironment(nil)
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.count, Set(dirs).count, "PATH has duplicates: \(dirs)")
    }

    /// An explicit environment override is honoured verbatim — the caller owns
    /// the whole environment and PATH is NOT rewritten.
    func testResolvedEnvironmentHonoursOverride() {
        let override = ["PATH": "/only/this", "FOO": "bar"]
        XCTAssertEqual(Subprocess.resolvedEnvironment(override), override)
    }
}
