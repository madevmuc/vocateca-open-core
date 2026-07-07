import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - Thread-safe event collector for tests

/// Collects event type strings from `EventBus` callback subscriptions.
/// Using an actor ensures the `@Sendable` callback closure can mutate state
/// safely (Swift 6 forbids mutating captured `var` in `@Sendable` closures).
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ type: String) {
        lock.withLock { _events.append(type) }
    }

    var events: [String] { lock.withLock { _events } }
    func contains(_ type: String) -> Bool { lock.withLock { _events.contains(type) } }
}

// MARK: - Gate (one-shot release for in-flight tasks)

/// Lets the test hold downloads in-flight until `release()` is called.
actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        for w in waiters { w.resume() }
        waiters = []
    }
}

// MARK: - QueueWorkerTests

/// Tests for `QueueWorker` drain behaviour, pause/stop, and concurrency cap.
///
/// All tests use fake engines and a temp `StateStore`. The `EventBus` is
/// a fresh (non-shared) instance for isolation — each test gets its own bus.
final class QueueWorkerTests: XCTestCase {

    // MARK: - Helper: build a standard pipeline with given engines

    private func makePipeline(
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber
    ) -> Pipeline {
        Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter()
        )
    }

    // MARK: - 1. QueueWorker drain: all episodes reach terminal status

    func testWorkerDrainsAllEpisodes() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        // Seed K=5 pending episodes.
        let k = 5
        var guids: [String] = []
        for i in 0..<k {
            let ep = Episode.makePodcast(guid: "ep-\(i)", pubDate: "2024-0\(i+1)-01")
            try store.upsert(ep)
            guids.append(ep.guid)
        }

        let mediaURL    = URL(fileURLWithPath: "/tmp/ep.mp3")
        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        // Collect run.started + run.finished events.
        let runEvents = EventCollector()
        await bus.subscribeCallback(.prefix("run.")) { event in
            runEvents.append(event.type)
        }

        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 2,
            bus: bus
        )

        await worker.start()

        // Wait for drain to complete (poll with a timeout).
        let deadline = Date().addingTimeInterval(10)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let stillRunning = await worker.isRunning
        XCTAssertFalse(stillRunning, "Worker must finish draining within timeout")

        // All episodes must be in a terminal status.
        for guid in guids {
            let ep = try XCTUnwrap(store.episode(guid: guid))
            let terminal: Set<String> = ["done", "failed", "skipped", "deferred"]
            XCTAssertTrue(terminal.contains(ep.status),
                          "Episode \(guid) must be in a terminal status, got '\(ep.status)'")
        }

        // run.started + run.finished must have been emitted.
        XCTAssertTrue(runEvents.contains(EventType.runStarted),
                      "run.started must be emitted")
        XCTAssertTrue(runEvents.contains(EventType.runFinished),
                      "run.finished must be emitted")
    }


    // MARK: - 2. Concurrency cap respected

    /// Seeds episodes and uses a FakeDownloader that records concurrent calls.
    /// Asserts max concurrent calls ≤ concurrencyLimit.
    func testConcurrencyCapRespected() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        // Seed 6 episodes.
        for i in 0..<6 {
            let ep = Episode.makePodcast(guid: "cap-\(i)", pubDate: "2024-0\(i+1)-01")
            try store.upsert(ep)
        }

        let mediaURL    = URL(fileURLWithPath: "/tmp/ep.mp3")
        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let cap = 2
        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: cap,
            bus: bus
        )

        await worker.start()

        let deadline = Date().addingTimeInterval(15)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // The downloader records peak concurrency.
        XCTAssertLessThanOrEqual(
            downloader.maxConcurrentCalls, cap,
            "Peak concurrent downloader calls (\(downloader.maxConcurrentCalls)) must not exceed cap (\(cap))"
        )
    }

    // MARK: - 3. Pause halts new claims

    func testPausePreventsNewClaims() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        // Seed a large batch so the worker can't drain before we pause.
        for i in 0..<10 {
            let ep = Episode.makePodcast(guid: "pause-\(i)", pubDate: "2024-0\(i % 9 + 1)-01")
            try store.upsert(ep)
        }

        // Pause events collector.
        let pauseEvents = EventCollector()
        await bus.subscribeCallback(.exact(EventType.queuePaused)) { event in
            pauseEvents.append(event.type)
        }

        let mediaURL    = URL(fileURLWithPath: "/tmp/ep.mp3")
        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 1,
            bus: bus
        )

        await worker.start()
        // Immediately pause.
        await worker.pause()

        let isPaused = await worker.isPaused
        XCTAssertTrue(isPaused, "Worker must be paused after calling pause()")

        // Give it a moment for the event to flush.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(pauseEvents.contains(EventType.queuePaused),
                      "queue.paused event must be emitted")


        await worker.stop()
    }

    // MARK: - 4. Stop cancels the worker

    func testStopCancels() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        for i in 0..<5 {
            let ep = Episode.makePodcast(guid: "stop-\(i)")
            try store.upsert(ep)
        }

        let mediaURL    = URL(fileURLWithPath: "/tmp/ep.mp3")
        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 1,
            bus: bus
        )

        await worker.start()
        await worker.stop()

        let isRunning = await worker.isRunning
        XCTAssertFalse(isRunning, "Worker must not be running after stop()")
    }

    /// Regression: a worker STOPPED mid-drain must NOT emit `run.finished`.
    ///
    /// A cancelled drain was stopped, not finished. If it emits `run.finished`,
    /// a stale finish tears down a *newer* run's state in `QueueRunner`,
    /// orphaning that run's worker (it keeps draining the queue invisibly while
    /// the UI shows a stopped run with blank stats). Observed in the field when
    /// the user pressed Stop and then immediately started a one-off transcribe.
    func testStopMidDrainDoesNotEmitRunFinished() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()
        for i in 0..<5 {
            try store.upsert(Episode.makePodcast(guid: "stopmid-\(i)"))
        }

        let runEvents = EventCollector()
        await bus.subscribeCallback(.prefix("run.")) { event in
            runEvents.append(event.type)
        }

        // Hold the first download in-flight at a gate so the worker is genuinely
        // mid-drain when we stop it.
        let gate = Gate()
        let started = XCTestExpectation(description: "first download started")
        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        downloader.onFirstDownloadStarted = { started.fulfill() }

        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)
        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 1,
            bus: bus
        )

        await worker.start()
        await fulfillment(of: [started], timeout: 2.0)

        // Stop while the first episode is held in-flight, then release the gate
        // so the cancelled task can unwind and the drain loop returns.
        await worker.stop()
        await gate.release()

        // Give the drain a moment to return and any (erroneous) event to flush.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(runEvents.contains(EventType.runStarted),
                      "run.started should still be emitted")
        XCTAssertFalse(runEvents.contains(EventType.runFinished),
                       "a stopped (cancelled) drain must NOT emit run.finished")
    }

    // MARK: - 5. Resume after pause restarts draining

    func testResumeAfterPause() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        let ep = Episode.makePodcast(guid: "resume-001")
        try store.upsert(ep)

        let resumeEvents = EventCollector()
        await bus.subscribeCallback(.exact(EventType.queueResumed)) { event in
            resumeEvents.append(event.type)
        }

        let mediaURL    = URL(fileURLWithPath: "/tmp/ep.mp3")
        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 1,
            bus: bus
        )

        await worker.start()
        await worker.pause()
        await worker.resume()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(resumeEvents.contains(EventType.queueResumed),
                      "queue.resumed event must be emitted")

        // Wait for drain.
        let deadline = Date().addingTimeInterval(10)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        await worker.stop()
    }

    // MARK: - 7. Exactly-once processing at concurrency > 1 (C1 regression)

    /// With concurrency > 1 and a non-atomic claim, the same pending row would be
    /// claimed and processed twice before its status flipped. The atomic claim
    /// (UPDATE … RETURNING flipping pending→downloading) must guarantee each guid
    /// is processed EXACTLY once, while still reaching the concurrency cap.
    func testExactlyOnceProcessingAtConcurrency() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = EventBus()

        let n = 6
        for i in 0..<n {
            try store.upsert(Episode.makePodcast(guid: "once-\(i)", pubDate: "2024-0\(i+1)-01"))
        }

        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.holdNanos = 120_000_000  // 120ms hold so tasks genuinely overlap
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let cap = 3
        let worker = QueueWorker(store: store, pipeline: pipeline,
                                 queueOrder: "oldest_first", concurrencyLimit: cap, bus: bus)
        await worker.start()
        let deadline = Date().addingTimeInterval(15)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let stillRunning = await worker.isRunning
        XCTAssertFalse(stillRunning, "worker must finish")
        XCTAssertEqual(downloader.maxPerGuidCount, 1,
                       "each episode must be downloaded exactly once (no double-claim)")
        XCTAssertEqual(downloader.callCount, n,
                       "total downloads must equal episode count (got \(downloader.callCount))")
        XCTAssertLessThanOrEqual(downloader.maxConcurrentCalls, cap, "must not exceed cap")
        XCTAssertGreaterThanOrEqual(downloader.maxConcurrentCalls, 2,
                                    "must actually run in parallel (peak \(downloader.maxConcurrentCalls))")
        let counts = try store.episodeCountByStatus()
        XCTAssertEqual(counts["done"], n, "all episodes must be done exactly once")
    }

    // MARK: - 8. Pause mid-drain then resume drains all (C2 regression)

    /// pause() while a download is in-flight must NOT abandon the remaining
    /// pending episodes: resume() restarts the drain and ALL reach done. (The
    /// old code set isRunning=false on pause-exit and resume gated on isRunning,
    /// so resume never restarted — a lost wakeup.)
    func testPauseMidDrainThenResumeDrainsAll() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = EventBus()

        let n = 4
        for i in 0..<n {
            try store.upsert(Episode.makePodcast(guid: "pr-\(i)", pubDate: "2024-0\(i+1)-01"))
        }

        let gate = Gate()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let firstStarted = expectation(description: "first download started")
        downloader.onFirstDownloadStarted = { firstStarted.fulfill() }

        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(store: store, pipeline: pipeline,
                                 queueOrder: "oldest_first", concurrencyLimit: 1, bus: bus)
        await worker.start()

        // Wait until the first download is in-flight, then pause.
        await fulfillment(of: [firstStarted], timeout: 5)
        await worker.pause()
        await gate.release()  // let the in-flight download (and any later ones) proceed

        // Worker drains the in-flight episode, then exits paused (isRunning=false).
        let pauseDeadline = Date().addingTimeInterval(10)
        while await worker.isRunning, Date() < pauseDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let afterPause = try store.episodeCountByStatus()
        XCTAssertLessThan(afterPause["done"] ?? 0, n,
                          "pause must have stopped the drain before all episodes finished")
        XCTAssertGreaterThan(afterPause["pending"] ?? 0, 0,
                             "episodes must remain pending after pause-exit")

        // Resume — the lost-wakeup bug would leave these pending forever.
        await worker.resume()
        let deadline = Date().addingTimeInterval(15)
        while (try store.episodeCountByStatus()["done"] ?? 0) < n, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await worker.stop()

        let final = try store.episodeCountByStatus()
        XCTAssertEqual(final["done"], n, "resume must drain ALL remaining episodes to done")
        XCTAssertEqual(downloader.maxPerGuidCount, 1, "still exactly-once across pause/resume")
    }

    // MARK: - 8b. Resume DURING pause-drain wind-down (M7 interleaving race)

    /// The harder lost-wakeup: `resume()` is called while the pause-drain is STILL
    /// winding down (in-flight download held at a gate → `isRunning` momentarily
    /// still true). The `resume()` fast-path (`if !isRunning`) can't restart here;
    /// only the `resumeRequested` flag consumed at the paused drain's exit saves
    /// it. Without that flag, the remaining episodes are abandoned pending forever.
    func testResumeWhilePauseDrainWindingDownIsNotLost() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = EventBus()

        let n = 3
        for i in 0..<n {
            try store.upsert(Episode.makePodcast(guid: "rr-\(i)", pubDate: "2024-0\(i+1)-01"))
        }

        let gate = Gate()
        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let firstStarted = expectation(description: "first download started")
        downloader.onFirstDownloadStarted = { firstStarted.fulfill() }

        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(store: store, pipeline: pipeline,
                                 queueOrder: "oldest_first", concurrencyLimit: 1, bus: bus)
        await worker.start()

        // First download is in-flight and HELD at the gate.
        await fulfillment(of: [firstStarted], timeout: 5)
        await worker.pause()
        // Resume BEFORE releasing the gate: the pause-drain hasn't exited, so the
        // worker is still running → resume takes the slow path (records intent).
        await worker.resume()
        // Now release — the paused drain exits and must honour the deferred resume.
        await gate.release()

        let deadline = Date().addingTimeInterval(15)
        while (try store.episodeCountByStatus()["done"] ?? 0) < n, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await worker.stop()

        XCTAssertEqual(try store.episodeCountByStatus()["done"], n,
                       "a resume issued mid-wind-down must still drain ALL episodes")
        XCTAssertEqual(downloader.maxPerGuidCount, 1, "exactly-once preserved")
    }

    // MARK: - 6. Empty queue → run.started + run.finished, no crash

    func testEmptyQueueEmitsRunEvents() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        let runEvents = EventCollector()
        await bus.subscribeCallback(.prefix("run.")) { event in
            runEvents.append(event.type)
        }

        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 1,
            bus: bus
        )

        await worker.start()

        let deadline = Date().addingTimeInterval(5)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        try await Task.sleep(nanoseconds: 100_000_000)  // let events flush

        XCTAssertTrue(runEvents.contains(EventType.runStarted),  "run.started must fire even on empty queue")
        XCTAssertTrue(runEvents.contains(EventType.runFinished), "run.finished must fire even on empty queue")
    }

    // MARK: - M12: pre-claim disk-full guard

    /// When the injected disk-space guard reports full, the worker must NOT claim
    /// any pending episode (they stay `pending`, the downloader is never called)
    /// and must emit `queueDiskFull` + `queuePaused` so the UI pauses + banners.
    func testDiskFullGuardPreventsClaimsAndEmitsEvents() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()

        // Seed pending work.
        for i in 0..<3 {
            try store.upsert(Episode.makePodcast(guid: "disk-ep-\(i)", pubDate: "2024-0\(i+1)-01"))
        }

        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let events = EventCollector()
        await bus.subscribeCallback(.prefix("queue.")) { events.append($0.type) }

        // Disk guard reports full from the very first claim.
        let worker = QueueWorker(
            store: store,
            pipeline: pipeline,
            queueOrder: "oldest_first",
            concurrencyLimit: 1,
            bus: bus,
            diskSpaceFull: { true }
        )

        await worker.start()

        // Wait for the drain to park.
        let deadline = Date().addingTimeInterval(5)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // No episode was claimed — the downloader was never called.
        XCTAssertEqual(downloader.callCount, 0, "no episode may be claimed while the disk is full")
        for i in 0..<3 {
            let ep = try XCTUnwrap(store.episode(guid: "disk-ep-\(i)"))
            XCTAssertEqual(ep.status, "pending", "episodes must stay pending — not claimed")
        }

        try await Task.sleep(nanoseconds: 100_000_000)  // let events flush
        XCTAssertTrue(events.contains(EventType.queueDiskFull), "queue.disk_full must be emitted")
        XCTAssertTrue(events.contains(EventType.queuePaused), "queue.paused must be emitted")
    }

    /// Regression guard: a guard reporting NOT full must not interfere — the queue
    /// drains normally.
    func testDiskGuardNotFullDrainsNormally() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bus = EventBus()
        for i in 0..<3 {
            try store.upsert(Episode.makePodcast(guid: "ok-ep-\(i)", pubDate: "2024-0\(i+1)-01"))
        }
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline    = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let worker = QueueWorker(
            store: store, pipeline: pipeline, queueOrder: "oldest_first",
            concurrencyLimit: 1, bus: bus, diskSpaceFull: { false })
        await worker.start()

        let deadline = Date().addingTimeInterval(10)
        while await worker.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for i in 0..<3 {
            let ep = try XCTUnwrap(store.episode(guid: "ok-ep-\(i)"))
            XCTAssertTrue(["done", "failed", "skipped", "deferred"].contains(ep.status),
                          "episode must reach terminal status when disk is not full, got '\(ep.status)'")
        }
    }
}
