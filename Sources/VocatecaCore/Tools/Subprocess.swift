import Foundation

// MARK: - Subprocess result

/// The collected output of a completed subprocess.
public struct SubprocessResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

// MARK: - Errors

public enum SubprocessError: Error, Sendable {
    case launchFailed(String)
    case timedOut(URL, [String])
}

// MARK: - Runner

/// A lightweight, Sendable subprocess runner built on `Foundation.Process`.
///
/// All output is buffered in memory and returned when the process exits.
/// Phase 2/3 will drive yt-dlp / gallery-dl / ffmpeg through this helper.
///
/// On timeout the OS process is terminated via `Process.terminate()` so it
/// does not linger after the caller's Swift task group cancels. This is
/// critical for yt-dlp which can run for minutes when rate-limited.
public struct Subprocess: Sendable {

    public init() {}

    // MARK: - Environment / PATH hardening
    //
    // A Finder/Launchpad-launched macOS app inherits launchd's MINIMAL PATH
    // (`/usr/bin:/bin:/usr/sbin:/sbin`) — it does NOT read the user's shell
    // rc, so `/opt/homebrew/bin` is absent. Any child tool we spawn (and its
    // grandchildren — e.g. yt-dlp shelling out to ffmpeg/ffprobe) then can't
    // find Homebrew/MacPorts binaries the user clearly installed. That was the
    // root cause of "ffprobe and ffmpeg not found" despite `brew install`
    // (2026-07-16). We prepend the well-known tool dirs to PATH for every
    // spawned process so the app never silently depends on the login PATH.

    /// Directories prepended to a spawned process's `PATH`: Homebrew (Apple
    /// Silicon + Intel), MacPorts, and our own managed-binary dir.
    public static var toolSearchDirs: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
         Paths.userDataDir().appendingPathComponent("bin", isDirectory: true).path]
    }

    /// The environment a spawned process should run with. An explicit `override`
    /// is used verbatim (callers that pass one own the whole environment);
    /// otherwise the current process environment is returned with
    /// ``toolSearchDirs`` prepended to `PATH` (duplicates removed, order kept).
    /// Pure + `nil`-safe so it can be unit-tested without spawning anything.
    static func resolvedEnvironment(_ override: [String: String]?) -> [String: String] {
        if let override { return override }
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var seen = Set<String>()
        let merged = (toolSearchDirs + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Run `executable` with `args` and return combined output.
    ///
    /// - Parameters:
    ///   - executable: Full path to the binary.
    ///   - args: Command-line arguments (not including argv[0]).
    ///   - timeout: Wall-clock timeout in seconds. If exceeded the process is
    ///     terminated with SIGTERM and `SubprocessError.timedOut` is thrown.
    ///   - environment: Optional environment override. When `nil` the current
    ///     process environment is inherited.
    @discardableResult
    public func run(
        _ executable: URL,
        _ args: [String],
        timeout: TimeInterval = 60,
        environment: [String: String]? = nil
    ) async throws -> SubprocessResult {
        // Central subprocess instrumentation: every external-binary invocation
        // (yt-dlp / ffmpeg / gallery-dl / whisper-cli …) flows through here, so a
        // single log point gives a complete, greppable trail of what ran, how long
        // it took, and why it failed. `bin` is the binary name only (args may carry
        // URLs — non-secret — but are logged as a count to avoid noise/leaks).
        let bin = executable.lastPathComponent
        let start = Date()
        Log.debug("Subprocess launch", component: "Subprocess",
                  context: [("bin", bin), ("args", "\(args.count)"),
                             ("timeout", "\(Int(timeout))")])
        do {
            let result = try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
                // Launch the process. `launchAndWait` registers a cancellation handler
                // that terminates the OS process when the Swift task is cancelled.
                group.addTask {
                    try await Self.launchAndWait(
                        executable: executable,
                        args: args,
                        environment: environment
                    )
                }
                // Timeout task: fires after `timeout` seconds.
                let timedOutError = SubprocessError.timedOut(executable, args)
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw timedOutError
                }
                // The first task to complete wins.
                // `group.cancelAll()` cancels the sibling task, which — for the
                // subprocess task — triggers the `withTaskCancellationHandler`
                // registered inside `launchAndWait`, which calls `process.terminate()`.
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if result.exitCode == 0 {
                Log.debug("Subprocess done", component: "Subprocess",
                          context: [("bin", bin), ("exit", "0"), ("ms", "\(ms)"),
                                     ("out", "\(result.stdout.utf8.count)"),
                                     ("err", "\(result.stderr.utf8.count)")])
            } else {
                // Non-zero exit: surface the stderr tail so failures are debuggable
                // from the log alone (never a bare "exit N" with no context).
                Log.warn("Subprocess non-zero exit", component: "Subprocess",
                         context: [("bin", bin), ("exit", "\(result.exitCode)"),
                                    ("ms", "\(ms)"),
                                    ("stderr", String(result.stderr.suffix(300)))])
            }
            return result
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Log.error("Subprocess failed", component: "Subprocess",
                      context: [("bin", bin), ("ms", "\(ms)"), ("error", "\(error)")])
            throw error
        }
    }

    // MARK: - Private helpers

    /// Launches the process, registers a cancellation handler that terminates
    /// the OS process, and awaits the termination continuation.
    ///
    /// ## Pipe draining (deadlock safety)
    /// stdout and stderr are drained **concurrently while the process runs**, via
    /// `readabilityHandler`s that append into lock-protected buffers. This is
    /// mandatory: a child that fills the ~64 KB OS pipe buffer on one stream
    /// blocks in `write()` and never exits — so reading the pipes only *after*
    /// exit (in `terminationHandler`) would deadlock on any large output (e.g.
    /// `yt-dlp --flat-playlist --dump-json` on a big channel emits megabytes).
    /// The continuation resumes only once BOTH streams hit EOF AND the process
    /// has terminated.
    private static func launchAndWait(
        executable: URL,
        args: [String],
        environment: [String: String]?
    ) async throws -> SubprocessResult {
        // Shared, lock-protected state. The lock makes the @unchecked Sendable
        // honest: every field is only ever touched while holding `lock`, whether
        // from a readability/termination handler (arbitrary GCD threads), the
        // launch path, or the cancellation handler. All finish/resume logic lives
        // here as methods so the @Sendable handler closures capture only `state`.
        // (CheckedContinuation is itself Sendable, so storing it here is fine.)
        final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?
            private var continuation: CheckedContinuation<SubprocessResult, Error>?
            private var outData = Data()
            private var errData = Data()
            private var outEOF = false
            private var errEOF = false
            private var terminated = false
            private var exitCode: Int32 = 0
            private var resumed = false

            func setContinuation(_ c: CheckedContinuation<SubprocessResult, Error>) {
                lock.lock(); continuation = c; lock.unlock()
            }
            func setProcess(_ p: Process) {
                lock.lock(); process = p; lock.unlock()
            }
            func terminateProcess() {
                lock.lock(); let p = process; lock.unlock()
                guard let p else { return }
                // SIGTERM first (graceful). A well-behaved child exits and its
                // pipes hit EOF, resuming the continuation.
                p.terminate()
                // SIGKILL fallback: a wedged child (e.g. an ffmpeg stuck in a
                // D-state uninterruptible wait) ignores SIGTERM and would hang
                // `run()` — and thus the whole queue — forever despite the
                // "timeout". After a 5 s grace period, if it's still running, send
                // SIGKILL, which the kernel delivers unconditionally. Detached so
                // the cancellation/timeout path returns immediately. The closure
                // captures only `self` (the lock-guarded, Sendable `State`) — never
                // the non-Sendable `Process` directly.
                Task.detached(priority: .utility) { [self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let pid = runningPidLocked(), pid > 0 else { return }
                    Log.warn("Subprocess: SIGTERM ignored — sending SIGKILL",
                             component: "Subprocess",
                             context: [("pid", "\(pid)")])
                    kill(pid, SIGKILL)
                }
            }
            /// The process's pid if it's STILL running, else nil (it already
            /// exited — `terminationHandler` fired). Read under the lock so the
            /// non-Sendable `Process` never escapes the `State` box.
            private func runningPidLocked() -> pid_t? {
                lock.lock(); defer { lock.unlock() }
                guard let p = process, p.isRunning else { return nil }
                return p.processIdentifier
            }
            func appendOut(_ d: Data) { lock.lock(); outData.append(d); lock.unlock() }
            func appendErr(_ d: Data) { lock.lock(); errData.append(d); lock.unlock() }
            func markOutEOF() { lock.lock(); outEOF = true; finishIfReadyLocked(); lock.unlock() }
            func markErrEOF() { lock.lock(); errEOF = true; finishIfReadyLocked(); lock.unlock() }
            func markTerminated(_ code: Int32) {
                lock.lock(); terminated = true; exitCode = code; finishIfReadyLocked(); lock.unlock()
            }
            func failLaunch(_ message: String) {
                lock.lock()
                let c = consumeContinuationLocked()
                lock.unlock()
                c?.resume(throwing: SubprocessError.launchFailed(message))
            }
            /// Resume exactly once, when both pipes are drained AND the process
            /// exited. Caller must hold `lock`.
            private func finishIfReadyLocked() {
                guard outEOF, errEOF, terminated, let c = consumeContinuationLocked() else { return }
                let result = SubprocessResult(
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    exitCode: exitCode
                )
                c.resume(returning: result)
            }
            /// Returns the continuation once (nil thereafter). Caller holds `lock`.
            private func consumeContinuationLocked() -> CheckedContinuation<SubprocessResult, Error>? {
                guard !resumed, let c = continuation else { return nil }
                resumed = true
                continuation = nil
                return c
            }
        }
        let state = State()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)

                let process = Process()
                process.executableURL = executable
                process.arguments = args
                process.environment = Self.resolvedEnvironment(environment)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.markOutEOF()
                    } else {
                        state.appendOut(chunk)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.markErrEOF()
                    } else {
                        state.appendErr(chunk)
                    }
                }

                process.terminationHandler = { p in
                    state.markTerminated(p.terminationStatus)
                }

                state.setProcess(process)

                do {
                    try process.run()
                } catch {
                    state.failLaunch(error.localizedDescription)
                }
            }
        } onCancel: {
            // Timeout / parent cancellation: terminate the OS process. Its pipes
            // then hit EOF and `terminationHandler` fires, draining + resuming.
            state.terminateProcess()
        }
    }
}
