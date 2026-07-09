import Foundation

// MARK: - QueueRunnerItem

/// A snapshot of an episode's queue state, suitable for display.
///
/// This is the Core-layer representation — no SwiftUI dependency.
/// The UI layer maps this to `QueueViewModel.QueueItem`.
public struct QueueRunnerItem: Sendable, Identifiable {
    /// Episode GUID (stable identity for list diffing).
    public let id: String
    public let showSlug: String
    public let title: String
    /// The episode's current lifecycle status string (e.g. "pending", "downloading").
    public let statusRaw: String
    /// The episode's raw queue priority (0 = backlog/Coming-up, >0 = Up Next).
    public let priority: Int
    /// Progress 0.0–1.0 for in-flight episodes, or `nil` when unknown.
    ///
    /// Note: the current pipeline does not emit progress events per segment;
    /// this is `nil` for all items until a progress-reporting engine is wired.
    public let progress: Double?
    /// The pipeline's current progress `phase` string (e.g. `"downloading"`,
    /// `"transcribing"`, or `Pipeline.modelLoadingPhase` — `"modelLoading"`),
    /// carried straight from the last `episode.progress` event. `nil` until at
    /// least one progress event has arrived for this episode (e.g. right after
    /// `claimNextPending` flips it to `downloading` in the DB, before the
    /// pipeline's first `emitProgress` call lands). The UI uses this — not
    /// `statusRaw` — to detect the model-load step, since `statusRaw` stays
    /// `"transcribing"` throughout (download/model-load/transcribe are all
    /// sub-phases of one DB status).
    public let phase: String?

    public init(
        id: String,
        showSlug: String,
        title: String,
        statusRaw: String,
        priority: Int,
        progress: Double? = nil,
        phase: String? = nil
    ) {
        self.id = id
        self.showSlug = showSlug
        self.title = title
        self.statusRaw = statusRaw
        self.priority = priority
        self.progress = progress
        self.phase = phase
    }
}

// MARK: - QueueRunState (Core)

/// The run-state of the queue processor, shared between Core and UI.
///
/// ## Double-pause state machine
///
/// The queue supports two-stage pause semantics:
///
/// 1. **First Pause press** (`.running` → `.pausing`): the worker stops claiming
///    new items but lets any currently-in-flight episode finish. While in this
///    state the UI shows "Pausing…".
///
/// 2. **Second Pause press** (`.pausing` → `.paused` immediately): cancels the
///    in-flight work now (cooperative cancellation) and parks immediately.
///
/// `resume()` and `stop()` work from any non-stopped state.
public enum QueueRunState: Sendable, Equatable {
    case stopped
    case running
    /// Graceful pause in progress — no new items claimed; current item finishes.
    case pausing
    case paused
}

// MARK: - QueueRunner

/// Observable orchestrator that bridges `QueueWorker` → UI.
///
/// `QueueRunner` lives in `VocatecaCore` so it can be unit-tested without
/// any SwiftUI dependency. The UI layer wraps it in a thin `@MainActor`
/// `ObservableObject` (`QueueController`) that re-publishes its state.
///
/// ## Lifecycle
///
/// 1. Call `load(from:)` to snapshot the live pending/in-flight episodes
///    from the database into `items`.
/// 2. Call `start(store:engines:bus:)` to launch the drain. The worker is
///    built lazily here — heavy engines (WhisperKit) are never instantiated
///    at `init` time.
/// 3. Subscribe to `onItemsChanged` and `onRunStateChanged` callbacks to drive
///    the UI. These are called on the MainActor.
/// 4. Call `pause()` / `stop()` to pause or cancel the drain.
///
/// ## Live updates strategy
///
/// The existing `Pipeline` does not emit episode lifecycle events to the
/// `EventBus` — it only writes them to the DB via `StateStore.setStatus` →
/// `appendEvent`. Therefore `QueueRunner` uses two mechanisms:
///
/// - **EventBus** (run lifecycle): subscribes to `run.*` and `queue.*` events
///   emitted by `QueueWorker` to track running/paused/stopped transitions and
///   know when the queue drains naturally (`run.finished`).
///
/// - **DB polling** (item status): polls the DB every ~0.5s while running to
///   refresh item statuses live (pending → downloading → transcribing → done).
///   This is intentionally simple and avoids modifying `Pipeline`. When a
///   future phase adds EventBus emissions to `Pipeline`, the polling interval
///   can be increased or removed.
@MainActor
public final class QueueRunner {

    // MARK: - Published state (set from MainActor; read by observers)

    /// Current snapshot of queue items (pending + in-flight).
    public private(set) var items: [QueueRunnerItem] = []

    /// Current run state.
    public private(set) var runState: QueueRunState = .stopped

    // MARK: - Stats band

    /// Wall-clock time when the current run started, or `nil`.
    public private(set) var runStartedAt: Date? = nil

    /// Number of episodes that have reached a terminal status in the current run.
    public private(set) var completedInRun: Int = 0

    // MARK: - Observer callbacks (all called on MainActor)

    /// Called (on MainActor) whenever `items` changes.
    public var onItemsChanged: (@MainActor () -> Void)?

    /// Called (on MainActor) whenever `runState` changes.
    public var onRunStateChanged: (@MainActor () -> Void)?

    // MARK: - Private

    private var worker: QueueWorker?
    /// Listens to EventBus run/queue lifecycle events.
    private var lifecycleTask: Task<Void, Never>?
    /// Listens to per-episode progress events.
    private var progressTask: Task<Void, Never>?
    /// Polls the DB for item status updates while running.
    private var pollTask: Task<Void, Never>?
    /// Store reference kept for polling.
    private var activeStore: StateStore?
    /// Live per-guid progress values (0.0–1.0) received from EventBus.
    /// Cleared when an episode reaches terminal status.
    private var progressByGuid: [String: Double] = [:]
    /// Live per-guid progress `phase` strings (e.g. "downloading",
    /// "transcribing", "modelLoading") received alongside `progressByGuid`.
    /// Cleared the same way (see `cancelBackgroundTasks` / the active-guid
    /// cleanup in `refreshItemsFromDB`).
    private var phaseByGuid: [String: String] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - Load items from DB

    /// Loads the current pending + in-flight episodes from `store` into `items`.
    ///
    /// Safe to call before `start()`, or at any time to refresh the list
    /// (e.g. after the user adds new episodes).
    public func load(from store: StateStore) {
        // L9: a DB read failure here previously fell silently to an EMPTY list, so
        // the queue looked drained when it wasn't (no signal at all). Log the error
        // so a busy/locked DB is visible in the in-app log; the fallback is still an
        // empty snapshot (nothing else is safe), but no longer invisible.
        let all: [Episode]
        do {
            all = try store.allEpisodes()
        } catch {
            Log.error("QueueRunner.load: DB read failed — showing an empty queue this pass",
                      component: "QueueRunner", context: [("error", "\(error)")])
            all = []
        }
        let activeStatuses: Set<String> = ["pending", "downloading", "downloaded", "transcribing"]
        let queued = all.filter { activeStatuses.contains($0.status) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return a.pubDate < b.pubDate
            }
        items = queued.map { ep in
            QueueRunnerItem(
                id: ep.guid,
                showSlug: ep.showSlug,
                title: ep.title,
                statusRaw: ep.status,
                priority: ep.priority
            )
        }
        Log.debug("QueueRunner loaded items from DB",
                  component: "QueueRunner",
                  context: [("active", "\(items.count)"),
                             ("total", "\(all.count)")])
        onItemsChanged?()
    }

    // MARK: - Control

    /// Starts draining the queue using the provided engines.
    ///
    /// Building the Pipeline / QueueWorker here (not at init) keeps expensive
    /// engine init (WhisperKit model load) deferred until the user presses Start.
    ///
    /// - Parameters:
    ///   - store:  The `StateStore` to claim episodes from.
    ///   - downloader: Injected download engine.
    ///   - transcriber: Injected transcription engine.
    ///   - ocrProcessor: Injected OCR engine.
    ///   - libraryWriter: Injected library writer.
    ///   - queueOrder: Queue-order preference. Defaults to `"oldest_first"`.
    ///   - config: Worker configuration (concurrency + QoS). Defaults to background/1.
    ///   - bus: Event bus to receive lifecycle events from. Defaults to `.shared`.
    ///   - pollInterval: DB poll interval in nanoseconds. Default 0.5 s.
    ///   - restrictToSlugs: Optional show-slug allowlist forwarded to the worker's
    ///     claim loop. `nil` (default) = claim any pending episode (manual queue).
    ///     Non-empty = daemon mode, only auto-download shows' episodes are claimed.
    ///   - diarizer: Optional speaker-diarization engine (Package D) forwarded to
    ///     the `Pipeline`. `nil` (default) = no diarization (tests/preview); the
    ///     real app + CLI inject a `FluidAudioDiarizer`.
    ///   - excludedSlugsProvider: Optional live-evaluated denylist of paused
    ///     shows' slugs (QA item 9), forwarded to `QueueWorker`. `nil` (default)
    ///     = no exclusion.
    public func start(
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber,
        ocrProcessor: any ImageOCRProcessor,
        libraryWriter: any LibraryWriter,
        queueOrder: String = "oldest_first",
        config: WorkerConfig = WorkerConfig(concurrencyLimit: 1, taskQoS: .utility),
        bus: EventBus = .shared,
        pollIntervalNanos: UInt64 = 500_000_000,
        restrictToSlugs: [String]? = nil,
        diskSpaceFull: (@Sendable () -> Bool)? = nil,
        diarizer: (any Diarizer)? = nil,
        excludedSlugsProvider: (@Sendable () -> [String])? = nil
    ) {
        guard runState != .running else { return }

        let pipeline = Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: ocrProcessor,
            libraryWriter: libraryWriter,
            bus: bus,
            diarizer: diarizer
        )
        let newWorker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: queueOrder,
            concurrencyLimit: config.concurrencyLimit,
            taskQoS: config.taskQoS,
            bus: bus,
            restrictToSlugs: restrictToSlugs,
            diskSpaceFull: diskSpaceFull,
            excludedSlugsProvider: excludedSlugsProvider
        )
        worker = newWorker
        activeStore = store
        runState = .running
        runStartedAt = Date()
        completedInRun = 0
        Log.info("Queue run started",
                 component: "QueueRunner",
                 context: [("concurrency", "\(config.concurrencyLimit)"),
                            ("qos", "\(config.taskQoS)"),
                            ("order", queueOrder),
                            ("pending", "\(items.count)")])
        onRunStateChanged?()

        // Listen to run/queue lifecycle events from the EventBus.
        subscribeToLifecycleEvents(bus: bus)

        // Listen to per-episode progress events from the EventBus.
        subscribeToProgressEvents(bus: bus)

        // Poll the DB for live item status updates.
        startPolling(store: store, pollIntervalNanos: pollIntervalNanos)

        Task {
            await newWorker.start()
        }
    }

    /// Pauses the drain — double-pause semantics:
    ///
    /// - First call (`.running` → `.pausing`): graceful — stop claiming new items,
    ///   let the currently in-flight episode finish naturally, then park.
    /// - Second call (`.pausing` → immediate `.paused`): cancel the in-flight work
    ///   now (cooperative cancellation via `worker.stopImmediately()`).
    public func pause() {
        switch runState {
        case .running:
            // First pause: graceful. Tell the worker to stop claiming new work
            // but finish what it is currently doing.
            guard let w = worker else { return }
            runState = .pausing
            Log.info("Queue pausing (graceful)", component: "QueueRunner")
            onRunStateChanged?()
            Task { await w.pause() }

        case .pausing:
            // Second pause: immediate. Cancel the worker's drain task now.
            guard let w = worker else { return }
            runState = .paused
            Log.info("Queue paused (immediate stop)", component: "QueueRunner")
            onRunStateChanged?()
            Task { await w.stopImmediately() }

        default:
            break
        }
    }

    /// Resumes a paused (or gracefully-pausing) drain.
    public func resume() {
        guard (runState == .paused || runState == .pausing), let w = worker else { return }
        runState = .running
        Log.info("Queue resumed", component: "QueueRunner")
        onRunStateChanged?()
        Task { await w.resume() }
    }

    /// Stops the drain (cancels the worker; in-flight tasks get cooperative cancellation).
    public func stop() {
        Log.info("Queue stopped by user",
                 component: "QueueRunner",
                 context: [("completed", "\(completedInRun)")])
        cancelBackgroundTasks()
        let w = worker
        worker = nil
        activeStore = nil
        runState = .stopped
        onRunStateChanged?()
        if let w { Task { await w.stop() } }
    }

    // MARK: - Mode application

    /// Applies a ``WorkerConfig`` (QoS + effective concurrency) to the running
    /// worker. No-op when the runner is stopped — the config is read at `start()`.
    ///
    /// Called by `QueueController` whenever `AppModeController.mode` changes.
    /// This is the only entry-point from the UI layer into Core for mode effects —
    /// it keeps `VocatecaCore` free of any `VocatecaUI` import.
    public func applyConfig(_ config: WorkerConfig) {
        Task { [weak self] in
            await self?.worker?.applyConfig(config)
        }
    }

    // MARK: - EventBus lifecycle subscription

    private func subscribeToLifecycleEvents(bus: EventBus) {
        lifecycleTask?.cancel()

        lifecycleTask = Task { [weak self] in
            let runStream = await bus.subscribe(.prefix("run."))
            let queueStream = await bus.subscribe(.prefix("queue."))

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in runStream {
                        guard !Task.isCancelled else { break }
                        await self?.handleRunEvent(event)
                    }
                }
                group.addTask {
                    for await event in queueStream {
                        guard !Task.isCancelled else { break }
                        await self?.handleQueueEvent(event)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func handleRunEvent(_ event: Event) {
        switch event.type {
        case EventType.runFinished:
            // Worker drained the queue naturally. Do a final DB refresh to
            // pick up any terminal episodes, then transition to stopped.
            Log.info("Queue drained naturally",
                     component: "QueueRunner",
                     context: [("completed", "\(completedInRun)")])
            if let store = activeStore {
                refreshItemsFromDB(store: store)
            }
            cancelBackgroundTasks()
            worker = nil
            activeStore = nil
            runState = .stopped
            onRunStateChanged?()
        default:
            break
        }
    }

    private func handleQueueEvent(_ event: Event) {
        switch event.type {
        case EventType.queuePaused:
            // The worker finished its in-flight tasks during a graceful pause
            // and is now truly parked. Transition .pausing → .paused.
            // If we're already in .paused (from a second-press immediate stop)
            // this is a no-op.
            if runState == .pausing || runState == .running {
                runState = .paused
                onRunStateChanged?()
            }
        case EventType.queueResumed:
            if runState != .running {
                runState = .running
                onRunStateChanged?()
            }
        default:
            break
        }
    }

    // MARK: - Progress event subscription

    /// Subscribes to `episode.progress` events and updates the matching item's
    /// `progress` value in `items`.
    ///
    /// Progress events are NOT persisted to the DB — they are purely in-process
    /// signals emitted by the pipeline engines. When the episode finishes (leaves
    /// the active set) `refreshItemsFromDB` rebuilds items without a progress value
    /// and `progressByGuid` is cleared in `cancelBackgroundTasks`.
    private func subscribeToProgressEvents(bus: EventBus) {
        progressTask?.cancel()

        progressTask = Task { [weak self] in
            let progressStream = await bus.subscribe(.exact(EventType.episodeProgress))
            for await event in progressStream {
                guard !Task.isCancelled else { break }
                self?.handleProgressEvent(event)
            }
        }
    }

    private func handleProgressEvent(_ event: Event) {
        guard
            let guid = event.guid,
            case .number(let fraction) = event.payload["fraction"]
        else { return }

        // Clamp to [0, 1].
        let clamped = max(0.0, min(1.0, fraction))
        progressByGuid[guid] = clamped
        let phase: String? = {
            guard case .string(let p) = event.payload["phase"] else { return nil }
            return p
        }()
        if let phase { phaseByGuid[guid] = phase }

        // Update the matching item in-place without a full DB round-trip.
        if let idx = items.firstIndex(where: { $0.id == guid }) {
            let old = items[idx]
            items[idx] = QueueRunnerItem(
                id: old.id,
                showSlug: old.showSlug,
                title: old.title,
                statusRaw: old.statusRaw,
                priority: old.priority,
                progress: clamped,
                phase: phaseByGuid[guid]
            )
            onItemsChanged?()
        }
    }

    // MARK: - DB polling for live item updates

    private func startPolling(store: StateStore, pollIntervalNanos: UInt64) {
        pollTask?.cancel()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                guard !Task.isCancelled else { break }
                self?.refreshItemsFromDB(store: store)
            }
        }
    }

    /// Re-reads the pending/in-flight episodes from the DB and merges updates
    /// into `items`. Tracks newly-terminal episodes to update `completedInRun`.
    private func refreshItemsFromDB(store: StateStore) {
        // L9: log a DB read failure instead of silently emptying the live list mid-run
        // (which would drop every in-flight row from the UI with no explanation). The
        // poll returns early on error so the LAST good snapshot stays on screen rather
        // than flashing empty.
        let all: [Episode]
        do {
            all = try store.allEpisodes()
        } catch {
            Log.error("QueueRunner.refresh: DB read failed — keeping last snapshot",
                      component: "QueueRunner", context: [("error", "\(error)")])
            return
        }
        let activeStatuses: Set<String> = ["pending", "downloading", "downloaded", "transcribing"]
        let terminalStatuses: Set<String> = ["done", "failed", "skipped", "deferred", "deleted"]

        // Count how many of our previously-tracked items have gone terminal.
        let prevIDs = Set(items.map { $0.id })
        let nowActiveIDs = Set(all.filter { activeStatuses.contains($0.status) }.map { $0.guid })
        let nowTerminalFromPrev = prevIDs.subtracting(nowActiveIDs)
        completedInRun += nowTerminalFromPrev.filter { id in
            // Only count as completed if the DB shows terminal (not just disappeared)
            let ep = all.first(where: { $0.guid == id })
            return ep.map { terminalStatuses.contains($0.status) } ?? false
        }.count

        // Rebuild items list from active episodes.
        // Carry forward any cached progress values from in-flight progress events
        // so a DB poll doesn't reset the progress bar mid-download/transcribe.
        let queued = all.filter { activeStatuses.contains($0.status) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return a.pubDate < b.pubDate
            }
        let newItems = queued.map { ep in
            QueueRunnerItem(
                id: ep.guid,
                showSlug: ep.showSlug,
                title: ep.title,
                statusRaw: ep.status,
                priority: ep.priority,
                progress: progressByGuid[ep.guid],
                phase: phaseByGuid[ep.guid]
            )
        }

        // Clean up progress/phase caches for episodes that are no longer active.
        let activeGUIDs = Set(queued.map { $0.guid })
        for guid in progressByGuid.keys where !activeGUIDs.contains(guid) {
            progressByGuid.removeValue(forKey: guid)
        }
        for guid in phaseByGuid.keys where !activeGUIDs.contains(guid) {
            phaseByGuid.removeValue(forKey: guid)
        }

        // Only fire callback if something changed (compare id + status + progress + phase).
        let newSig = newItems.map { "\($0.id)\($0.statusRaw)\($0.progress.map { String(format: "%.4f", $0) } ?? "nil")\($0.phase ?? "nil")" }
        let oldSig = items.map { "\($0.id)\($0.statusRaw)\($0.progress.map { String(format: "%.4f", $0) } ?? "nil")\($0.phase ?? "nil")" }
        if newSig != oldSig {
            items = newItems
            onItemsChanged?()
        }
    }

    // MARK: - Helpers

    private func cancelBackgroundTasks() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        progressTask?.cancel()
        progressTask = nil
        pollTask?.cancel()
        pollTask = nil
        progressByGuid.removeAll()
        phaseByGuid.removeAll()
    }

    // MARK: - Computed stats

    /// Elapsed seconds since the run started, or `nil` when stopped.
    public var elapsedSeconds: TimeInterval? {
        guard let start = runStartedAt, runState != .stopped else { return nil }
        return Date().timeIntervalSince(start)
    }

    /// Average seconds per completed episode in the current run, or `nil`.
    public var avgSecondsPerEpisode: Double? {
        guard completedInRun > 0, let elapsed = elapsedSeconds else { return nil }
        return elapsed / Double(completedInRun)
    }

    /// Formatted elapsed string, e.g. "41m" or "1h 3m".
    public var elapsedFormatted: String {
        guard let secs = elapsedSeconds else { return "—" }
        return Self.formatDuration(Int(secs))
    }

    /// Progress fraction (0–1) of the currently in-flight episode, if any.
    /// The pipeline emits `episode.progress` events that populate `progressByGuid`.
    private var currentProgressFraction: Double? { progressByGuid.values.max() }

    /// Estimated seconds for ONE episode. Prefers the measured average over
    /// COMPLETED episodes; before any episode completes (e.g. a single one-off
    /// import) it falls back to a LIVE estimate from the in-flight episode's
    /// progress (run elapsed ÷ fraction — valid because the in-flight episode is
    /// the first when nothing has completed yet).
    public var estimatedSecondsPerEpisode: Double? {
        if let avg = avgSecondsPerEpisode { return avg }
        guard let el = elapsedSeconds, let f = currentProgressFraction, f >= 0.05 else { return nil }
        return el / f
    }

    /// Estimated remaining seconds for the whole run, or nil when not estimable.
    /// Measured average × pending once episodes have completed; otherwise the live
    /// in-flight estimate (remaining of the current episode + pending × estimate).
    public var etaSeconds: Double? {
        let pending = items.filter { $0.statusRaw == "pending" }.count
        if let avg = avgSecondsPerEpisode {
            guard pending > 0 else { return nil }
            return avg * Double(pending)
        }
        guard let el = elapsedSeconds, let f = currentProgressFraction, f >= 0.05 else { return nil }
        let estTotal = el / f
        let inFlightRemaining = max(0, estTotal - el)
        return inFlightRemaining + Double(pending) * estTotal
    }

    /// Formatted average-per-episode string, e.g. "6m 12s".
    public var avgPerEpisodeFormatted: String {
        guard let avg = estimatedSecondsPerEpisode else { return "—" }
        return Self.formatDuration(Int(avg))
    }

    /// Estimated remaining time (run-level), live even for the first/only episode.
    public var etaFormatted: String {
        guard let eta = etaSeconds, eta > 0 else { return "—" }
        return Self.formatDuration(Int(eta))
    }

    /// Per-row ETA: remaining time for one in-flight episode given its progress
    /// fraction, using the per-episode estimate. "—" until there's enough signal.
    public func rowEtaFormatted(progress: Double?) -> String {
        guard let p = progress, p > 0.05, p < 1.0,
              let est = estimatedSecondsPerEpisode else { return "—" }
        let remaining = est * (1 - p)
        return remaining > 0 ? Self.formatDuration(Int(remaining)) : "—"
    }

    /// Estimated finish wall-clock string, e.g. "Fri 9:01 AM" or "Fr. 09:01"
    /// (locale-aware 12h/24h per system preference).
    public var finishFormatted: String {
        guard let eta = etaSeconds, eta > 0 else { return "—" }
        let now = Date()
        let finishDate = now.addingTimeInterval(eta)
        let df = DateFormatter()
        df.locale = .current
        // A bare weekday is ambiguous once the finish is more than a few days
        // out ("Fri" could be this week or next). Beyond 3 days, show an explicit
        // date; within 3 days, the weekday is clear enough.
        if finishDate.timeIntervalSince(now) > 3 * 86_400 {
            df.setLocalizedDateFormatFromTemplate("dMMMjmm")  // e.g. "10 Jul 16:02"
        } else {
            df.setLocalizedDateFormatFromTemplate("EEEjmm")   // e.g. "Fri 16:02"
        }
        return df.string(from: finishDate)
    }

    /// Estimated finish, TIME ONLY (no weekday/date) — locale-aware 12h/24h,
    /// e.g. "16:02" or "4:02 PM". Distinct from `finishFormatted` (which the
    /// stats band uses and includes the day when the finish is not "now"):
    /// this feeds the header's glanceable "Fertig ca. HH:MM" pill, where a
    /// bare time reads faster than a day-qualified string. `nil` when there
    /// is no estimate yet (mirrors `finishFormatted`'s "—" gate).
    public var finishTimeFormatted: String? {
        guard let eta = etaSeconds, eta > 0 else { return nil }
        let finishDate = Date().addingTimeInterval(eta)
        let df = DateFormatter()
        df.locale = .current
        df.setLocalizedDateFormatFromTemplate("jmm")
        return df.string(from: finishDate)
    }

    /// "Started" formatted as locale-aware hour:minute (12h/24h per system preference).
    public var startedFormatted: String {
        guard let s = runStartedAt else { return "—" }
        let df = DateFormatter()
        df.locale = .current
        df.setLocalizedDateFormatFromTemplate("jmm") // 'j' → locale's 12/24h hour
        return df.string(from: s)
    }

    // MARK: - Formatting helpers

    private static func formatDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
