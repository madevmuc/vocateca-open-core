import Foundation

// MARK: - QueueWorker

/// The concurrency backbone that drains the `pending` episode queue through
/// the `Pipeline`, respecting a concurrency cap and emitting run lifecycle events.
///
/// ## Concurrency model
///
/// `QueueWorker` is a Swift `actor`, so all state mutations (draining the claim
/// loop, toggling paused/running) happen serially on the actor's executor.
/// Individual `Pipeline.process` calls run as **child tasks** inside a
/// `withTaskGroup` — up to `concurrencyLimit` tasks in flight simultaneously.
///
/// The concurrency cap is enforced by tracking active task count: when the
/// active count reaches `concurrencyLimit`, the loop waits for one task to
/// complete before claiming the next episode.
///
/// ## Pause / stop
///
/// - `pause()`:  sets `isPaused = true`; the claim loop stops issuing new claims
///   once the in-flight batch finishes (no new work starts while paused; existing
///   tasks complete naturally).
/// - `resume()`: clears `isPaused` and restarts the drain loop.
/// - `stop()`:   cancels the worker `Task` (all child tasks receive cooperative
///   cancellation; in-flight calls to `Pipeline.process` may complete or cancel
///   depending on their `async throws` checkpoints).
///
/// ## Events emitted
///
/// | Event              | When                                          |
/// |--------------------|-----------------------------------------------|
/// | `run.started`      | A drain run begins (transitions idle → active)|
/// | `run.finished`     | Queue drained (no more pending episodes)      |
/// | `queue.paused`     | `pause()` called while running                |
/// | `queue.resumed`    | `resume()` called while paused                |
///
/// ## Design decision: retry-within-run vs re-queue
///
/// The worker does **not** retry transient failures inline. When
/// `Pipeline.process` returns `.pending` (transient retry → re-queued),
/// the episode is left in `pending` state and the next drain iteration will
/// re-claim it if `claimNextPending` returns it again. This avoids sleeping
/// inside a `TaskGroup` child task and keeps `Pipeline` simple. The `attempts`
/// counter prevents infinite re-claims.
public actor QueueWorker {

    // MARK: - State

    /// Whether a drain run is currently active.
    public private(set) var isRunning: Bool = false

    /// Whether the worker is paused (will not claim new work until resumed).
    public private(set) var isPaused: Bool = false

    /// Set by `resume()` when it can't restart the drain itself because the
    /// pause-drain is still winding down (`isRunning` momentarily still true).
    /// Consumed by `runDrain()` right after a `.paused` exit: if set, it re-spawns
    /// the drain so the resume isn't lost. Closes the interleaving race the
    /// `resume()` fast-path alone can't (resume observes `isRunning == true`, the
    /// drain then parks and clears `isRunning`, and nothing restarts it).
    private var resumeRequested: Bool = false

    // MARK: - Configuration

    private let store: StateStore
    private let pipeline: Pipeline
    private let queueOrder: String
    private var concurrencyLimit: Int  // mutable so applyConfig() can update it live
    private let bus: EventBus

    /// Optional allowlist of show slugs passed to `claimNextPending`.
    ///
    /// - `nil` (default) → claim any pending episode (manual queue / legacy behaviour).
    /// - non-empty array → daemon mode: only claim episodes from auto-download shows.
    ///
    /// Set via `init(restrictToSlugs:)` before `start()`. Immutable after init so
    /// the claim loop never observes a mid-run change (daemon restarts a new worker
    /// for each run anyway).
    private let restrictToSlugs: [String]?

    /// Task QoS applied to new drain tasks spawned after an `applyConfig()` call.
    /// Existing tasks are not retroactively re-prioritised (that's not possible).
    private var taskQoS: QualityOfService

    /// M12: optional pre-claim disk-space guard. Returns `true` when free space is
    /// below the configured floor, i.e. the worker should stop claiming new work
    /// and pause. Checked BEFORE every `claimNextPending` so a big backlog can't
    /// fill the disk in the ~6 h gap between maintenance ticks. `nil` (default)
    /// disables the check — most tests and the daemon pass nil; the UI's
    /// `QueueController` injects a real `DiskGuard`-backed closure. Must be pure /
    /// side-effect-free (it's called on the actor).
    private let diskSpaceFull: (@Sendable () -> Bool)?

    // MARK: - Internal drain task handle

    private var drainTask: Task<Void, Never>? = nil

    // MARK: - Initialisation

    /// Creates a `QueueWorker`.
    ///
    /// - Parameters:
    ///   - store: The `StateStore` to claim episodes from.
    ///   - pipeline: The configured `Pipeline` to process each episode.
    ///   - queueOrder: Queue-order preference (`oldest_first`, `newest_first`,
    ///     `shortest_first`). Defaults to `"oldest_first"`.
    ///   - concurrencyLimit: Maximum number of episodes to process in parallel.
    ///     Mirrors `Settings.transcribeConcurrency`. Defaults to 1.
    ///   - bus: The `EventBus` to emit lifecycle events on.
    ///   - restrictToSlugs: Optional show-slug allowlist forwarded to
    ///     `StateStore.claimNextPending`. `nil` (default) = claim any pending
    ///     episode (manual queue behaviour). Non-empty = daemon mode, only
    ///     auto-download shows' episodes are claimed.
    public init(
        store: StateStore,
        pipeline: Pipeline,
        queueOrder: String = "oldest_first",
        concurrencyLimit: Int = 1,
        taskQoS: QualityOfService = .utility,
        bus: EventBus = .shared,
        restrictToSlugs: [String]? = nil,
        diskSpaceFull: (@Sendable () -> Bool)? = nil
    ) {
        self.store = store
        self.pipeline = pipeline
        self.queueOrder = queueOrder
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.taskQoS = taskQoS
        self.bus = bus
        self.restrictToSlugs = restrictToSlugs
        self.diskSpaceFull = diskSpaceFull
        if let slugs = restrictToSlugs, !slugs.isEmpty {
            Log.info("QueueWorker init: daemon-scoped claim",
                     component: "QueueWorker",
                     context: [("shows", slugs.joined(separator: ","))])
        }
    }

    // MARK: - Control API

    /// Why a drain loop exited:
    /// - `.finished`: the queue drained naturally (no more claimable work) →
    ///   emits `run.finished`.
    /// - `.paused`:   a graceful pause parked the loop (work may remain) → no event.
    /// - `.stopped`:  the drain task was cancelled (user Stop / worker replaced) →
    ///   **no `run.finished`**. Emitting one here is a correctness bug: a stale
    ///   finish from a cancelled worker tears down a *newer* run's state, orphaning
    ///   its worker (invisible background drain, blank run stats).
    private enum DrainExit { case finished, paused, stopped }

    /// Starts draining the pending queue. No-op if already running.
    ///
    /// Emits `run.started` and (on genuine completion) `run.finished`.
    public func start() {
        guard !isRunning else {
            Log.debug("QueueWorker.start() called while already running — ignored",
                      component: "QueueWorker")
            return
        }
        Log.info("QueueWorker starting drain",
                 component: "QueueWorker",
                 context: [("concurrency", "\(concurrencyLimit)"),
                            ("qos", "\(taskQoS)"),
                            ("order", queueOrder)])
        isRunning = true
        isPaused = false
        resumeRequested = false
        spawnDrain()
    }

    /// Pauses claiming new work. In-flight tasks continue to completion.
    ///
    /// Emits `queue.paused`. No-op if not running or already paused.
    public func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        Task { await bus.emit(Event(type: EventType.queuePaused)) }
    }

    /// Resumes a paused worker, restarting the drain loop so any episodes left
    /// pending after the pause are processed.
    ///
    /// Emits `queue.resumed`. No-op if not paused. (Previously this gated the
    /// restart on `isRunning`, but the pause-exit clears `isRunning` — that was a
    /// lost-wakeup: resume never restarted and pending work was abandoned.)
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        Task { await bus.emit(Event(type: EventType.queueResumed)) }
        if !isRunning {
            // Fast path: the pause-drain already exited (isRunning cleared) — start
            // a fresh drain right here.
            isRunning = true
            spawnDrain()
        } else {
            // Slow path: the pause-drain is STILL winding down (draining in-flight
            // tasks) so it owns `isRunning`. Record the intent; `runDrain()` will
            // honour it the instant the paused drain exits, otherwise this resume
            // would be silently lost (pending work abandoned).
            resumeRequested = true
        }
    }

    /// Cancels the drain task, stopping the worker.
    ///
    /// In-flight `Pipeline.process` calls receive cooperative cancellation.
    public func stop() {
        drainTask?.cancel()
        drainTask = nil
        isRunning = false
        isPaused = false
        // A pending resume is void once the user Stops — don't let runDrain's
        // exit re-spawn a drain the user explicitly halted.
        resumeRequested = false
    }

    /// Cancels the drain task immediately and emits `queue.paused` — used by the
    /// **second** Pause press (immediate-stop branch of the double-pause state machine).
    ///
    /// Unlike `stop()`, this does NOT clear `isRunning` all the way to idle;
    /// the QueueRunner transitions to `.paused` so the worker can be resumed.
    public func stopImmediately() {
        drainTask?.cancel()
        drainTask = nil
        isRunning = false
        isPaused = true
        Task { await bus.emit(Event(type: EventType.queuePaused)) }
    }

    /// Updates the concurrency limit and task QoS for future drain iterations.
    ///
    /// Called by `QueueRunner.applyConfig(_:)` when the user changes
    /// `AppMode` (Background ↔ Power). Existing in-flight tasks are not
    /// affected — the new config takes effect on the next episode claim.
    public func applyConfig(_ config: WorkerConfig) {
        concurrencyLimit = max(1, config.concurrencyLimit)
        taskQoS = config.taskQoS
    }

    // MARK: - Internal drain loop

    /// Maps a `QualityOfService` to the Swift-concurrency `TaskPriority` the
    /// scheduler should use for pipeline work.
    ///
    /// - Power mode (`.userInitiated`) → `.userInitiated` (high)
    /// - Background mode (`.utility`)  → `.utility` (low, but not discretionary)
    static func taskPriority(for qos: QualityOfService) -> TaskPriority {
        switch qos {
        case .userInitiated, .userInteractive: return .userInitiated
        case .utility:                          return .utility
        default:                                return .background
        }
    }

    private func spawnDrain() {
        drainTask = Task(priority: Self.taskPriority(for: taskQoS)) { [weak self] in
            guard let self = self else { return }
            await self.runDrain()
        }
    }

    /// Runs one drain pass and reconciles run state + the `run.finished` event
    /// with WHY it ended. A pause does NOT emit `run.finished` (the run isn't
    /// finished — it's parked); only a genuine drain-complete / empty / stop does.
    private func runDrain() async {
        let exit = await _drain()
        isRunning = false
        drainTask = nil
        if case .finished = exit {
            await bus.emit(Event(type: EventType.runFinished))
        }
        // Lost-wakeup guard: a `resume()` that arrived while this (paused) drain
        // was still winding down couldn't restart the loop itself (we still owned
        // `isRunning`). Honour that deferred resume now that we've parked, so
        // pending work isn't abandoned. Only meaningful for a `.paused` exit — a
        // `.finished`/`.stopped` run has no work to resume into.
        if case .paused = exit, resumeRequested {
            resumeRequested = false
            Log.info("QueueWorker: honouring deferred resume after pause-drain exit",
                     component: "QueueWorker")
            isRunning = true
            spawnDrain()
        }
    }

    private func _drain() async -> DrainExit {
        await bus.emit(Event(type: EventType.runStarted))

        // We drive concurrency by tracking how many tasks are active and
        // waiting for slots to open up before claiming the next episode.
        // The actor serialises the claim loop; the claim itself is atomic
        // (flips pending→downloading), so no two child tasks get the same row.
        var exit: DrainExit = .finished
        await withTaskGroup(of: PipelineResult.self) { group in
            var activeCount = 0

            while !Task.isCancelled {
                // Wait until a slot is available.
                if activeCount >= concurrencyLimit {
                    if await group.next() != nil {
                        activeCount -= 1
                    } else {
                        break  // group exhausted
                    }
                }

                // Re-check cancellation before claiming. `stop()` may have fired
                // while we were awaiting a slot above (group.next()). The `while`
                // condition is only evaluated at the TOP of each iteration, so
                // without this a cancelled worker claims ONE extra episode here
                // (which then fails as cancelled) before the loop exits. Break so
                // the post-loop cancellation handling marks the exit `.stopped`.
                if Task.isCancelled { break }

                // Don't claim new work while paused: drain in-flight, mark paused.
                if isPaused {
                    for await _ in group { activeCount -= 1 }
                    exit = .paused
                    return
                }

                // M12: proactive disk-full guard — checked BEFORE claiming so a
                // large backlog can't keep downloading past the free-space floor
                // between the ~6 h maintenance ticks. On a hit: drain any in-flight
                // tasks, emit `queueDiskFull` (the UI pauses + banners), and park as
                // `.paused` (not `.finished`) so the user can resume once space is
                // freed without losing the run.
                if let diskSpaceFull, diskSpaceFull() {
                    Log.warn("QueueWorker: disk below free-space floor — pausing before next claim",
                             component: "QueueWorker",
                             context: [("activeCount", "\(activeCount)")])
                    for await _ in group { activeCount -= 1 }
                    isPaused = true
                    await bus.emit(Event(type: EventType.queueDiskFull))
                    await bus.emit(Event(type: EventType.queuePaused))
                    exit = .paused
                    return
                }

                // Atomically claim the next pending episode (flips to downloading).
                // When restrictToSlugs is set (daemon mode), only episodes from
                // those shows are claimed — manual-queue workers pass nil (claim all).
                let episode: Episode?
                do {
                    episode = try store.claimNextPending(
                        queueOrder: queueOrder,
                        restrictToSlugs: restrictToSlugs
                    )
                } catch {
                    Log.error("QueueWorker: DB error claiming next episode — stopping run",
                              component: "QueueWorker",
                              context: [("error", "\(error)")])
                    break  // DB error claiming — stop the run.
                }

                guard let ep = episode else {
                    // Queue empty — drain any remaining in-flight tasks.
                    Log.info("QueueWorker: queue empty — draining in-flight tasks",
                             component: "QueueWorker",
                             context: [("activeCount", "\(activeCount)")])
                    for await _ in group { activeCount -= 1 }
                    break
                }

                Log.info("QueueWorker: claiming episode",
                         component: "QueueWorker",
                         context: [("guid", ep.guid),
                                    ("slug", ep.showSlug),
                                    ("title", ep.title),
                                    ("active", "\(activeCount + 1)/\(concurrencyLimit)")])
                let p = pipeline
                // Spawn each item at the CURRENT QoS (read per-claim) so a mode
                // switch mid-run makes newly-claimed items adopt the new priority
                // immediately — not the drain task's original priority.
                group.addTask(priority: Self.taskPriority(for: taskQoS)) {
                    await p.process(ep)
                }
                activeCount += 1
            }

            if Task.isCancelled {
                group.cancelAll()
                // A cancelled drain was STOPPED, not finished — suppress the
                // spurious run.finished that would otherwise tear down a newer run.
                exit = .stopped
            }
        }

        return exit
    }
}
