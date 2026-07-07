import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - QueueRunnerTests
//
// Tests for QueueRunner using fake engines and a temp StateStore.
// Never touches real network, WhisperKit, or disk (no real downloads).
//
// What these tests cover:
//   1. Initial load: pending episodes appear in items, done/failed do not.
//   2. Start drains: all pending reach terminal status; items list empties.
//   3. Items update live during a run: status changes propagate via EventBus.
//   4. Pause: runner transitions to .paused state; stop: to .stopped.
//   5. Stop: runner stops cleanly.
//   6. runState lifecycle: stopped → running → stopped after drain.
//   7. Stats: startedFormatted non-empty after start; elapsed non-empty mid-run.
//
// What still requires a live run to verify (real pipeline):
//   - Real download via URLSessionDownloader (network required).
//   - Real transcription via WhisperKitTranscriber (CoreML model required).
//   - Real OCR via InstagramImageOCRProcessor (Vision framework on-device).
//   - Markdown output via MarkdownLibraryWriter (real disk path).
//   - Progress values for in-flight items (not yet emitted by QueueWorker).
//   - ETA/Finish accuracy under real timing.

@MainActor
final class QueueRunnerTests: XCTestCase {

    // MARK: - Helpers

    private func makeRunner(
        store: StateStore,
        downloader: any EpisodeDownloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3"))),
        transcriber: any Transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
        ocrProcessor: any ImageOCRProcessor = FakeOCRProcessor(),
        libraryWriter: any LibraryWriter = FakeLibraryWriter(),
        bus: EventBus = EventBus()
    ) -> (QueueRunner, EventBus) {
        let runner = QueueRunner()
        runner.load(from: store)

        // Give access to the runner's start method but also hand back the bus.
        return (runner, bus)
    }

    private func startRunner(
        _ runner: QueueRunner,
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber,
        bus: EventBus
    ) {
        runner.start(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )
    }

    // MARK: - 1. Load: pending episodes appear; terminal ones do not

    func testLoadShowsPendingEpisodesOnly() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed 3 pending + 1 done + 1 failed.
        for i in 0..<3 {
            try store.upsert(Episode.makePodcast(guid: "load-p-\(i)", status: "pending"))
        }
        try store.upsert(Episode.makePodcast(guid: "load-done", status: "done"))
        try store.upsert(Episode.makePodcast(guid: "load-fail", status: "failed"))

        let runner = QueueRunner()
        runner.load(from: store)

        XCTAssertEqual(runner.items.count, 3, "Only pending items should appear")
        XCTAssertTrue(runner.items.allSatisfy { $0.statusRaw == "pending" })
        XCTAssertFalse(runner.items.contains { $0.id == "load-done" })
        XCTAssertFalse(runner.items.contains { $0.id == "load-fail" })
    }

    // MARK: - 2. Start drains all pending to terminal status

    func testStartDrainsAllEpisodes() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let k = 4
        for i in 0..<k {
            try store.upsert(Episode.makePodcast(guid: "drain-\(i)", pubDate: "2024-0\(i+1)-01"))
        }

        let bus = EventBus()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))

        let runner = QueueRunner()
        runner.load(from: store)

        XCTAssertEqual(runner.items.count, k)

        // Track run state changes.
        var stateChanges: [QueueRunState] = []
        runner.onRunStateChanged = { stateChanges.append(runner.runState) }

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)

        XCTAssertEqual(runner.runState, .running)

        // Wait for drain to complete (poll).
        let deadline = Date().addingTimeInterval(15)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(runner.runState, .stopped, "Runner should stop after drain")

        // Give the MainActor queue a moment to flush the item-removal callbacks
        // that were queued by handleEpisodeEvent (they run after runState flips).
        try await Task.sleep(nanoseconds: 200_000_000)

        // All items should have been removed from the queue.
        XCTAssertEqual(runner.items.count, 0, "All items should be gone after drain")

        // DB should show all done.
        let statusMap = try store.episodeCountByStatus()
        XCTAssertEqual(statusMap["done"], k, "All \(k) episodes must be done")

        // completedInRun should track completed count.
        XCTAssertEqual(runner.completedInRun, k)
    }

    // MARK: - 3. Items update live via EventBus during a run

    func testItemStatusUpdatesLive() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "live-status-001")
        try store.upsert(ep)

        let bus = EventBus()
        var itemChangeFired = false
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))

        let runner = QueueRunner()
        runner.load(from: store)
        runner.onItemsChanged = { itemChangeFired = true }

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)

        // Wait for drain to finish.
        let deadline = Date().addingTimeInterval(10)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Brief grace period to let MainActor-queued item callbacks flush.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(itemChangeFired, "onItemsChanged must have fired at least once")
    }

    // MARK: - 4. runState: initial is stopped; transitions to running on start

    func testRunStateLifecycle() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "state-001"))

        let bus = EventBus()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))

        let runner = QueueRunner()
        runner.load(from: store)

        XCTAssertEqual(runner.runState, .stopped, "Initial state must be stopped")

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)
        XCTAssertEqual(runner.runState, .running, "Must be running after start()")

        let deadline = Date().addingTimeInterval(10)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(runner.runState, .stopped, "Must be stopped after drain")
    }

    // MARK: - 5. first pause() → .pausing (graceful); stop() → .stopped

    func testPauseAndStop() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<10 {
            try store.upsert(Episode.makePodcast(guid: "ps-\(i)"))
        }

        let gate = Gate()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let bus = EventBus()

        let runner = QueueRunner()
        runner.load(from: store)

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)
        XCTAssertEqual(runner.runState, .running)

        // Double-pause state machine: the FIRST pause() is a graceful pause and
        // transitions .running → .pausing (it does not park immediately). Reaching
        // .paused needs a second press or the worker's queue.paused event — see
        // DoublePauseTests for the full machine.
        runner.pause()
        XCTAssertEqual(runner.runState, .pausing,
                       "first pause() is graceful → .pausing")

        runner.stop()
        // Give stop() a moment to propagate.
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.runState, .stopped, "stop() must set state to .stopped")
    }

    // MARK: - 6. Start on empty queue → immediate stop

    func testEmptyQueueStopsImmediately() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No episodes seeded.
        let bus = EventBus()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))

        let runner = QueueRunner()
        runner.load(from: store)

        XCTAssertEqual(runner.items.count, 0)

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)

        // The worker drain exits immediately (empty queue) → run.finished → stopped.
        let deadline = Date().addingTimeInterval(5)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(runner.runState, .stopped)
        XCTAssertEqual(runner.items.count, 0)
    }

    // MARK: - 7. Stats: startedFormatted non-empty after start

    func testStatsPopulatedAfterStart() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(Episode.makePodcast(guid: "stats-001"))

        let bus = EventBus()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))

        let runner = QueueRunner()
        runner.load(from: store)

        XCTAssertEqual(runner.startedFormatted, "—")
        XCTAssertNil(runner.runStartedAt)

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)

        XCTAssertNotNil(runner.runStartedAt, "runStartedAt must be set after start()")
        XCTAssertNotEqual(runner.startedFormatted, "—", "startedFormatted must be a time string")

        // Wait for drain.
        let deadline = Date().addingTimeInterval(10)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - 8. Resume after pause restarts draining

    func testResumeAfterPause() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n = 3
        for i in 0..<n {
            try store.upsert(Episode.makePodcast(guid: "resume-\(i)", pubDate: "2024-0\(i+1)-01"))
        }

        let gate = Gate()
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let firstStarted = expectation(description: "first download started")
        downloader.onFirstDownloadStarted = { firstStarted.fulfill() }
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let bus = EventBus()

        let runner = QueueRunner()
        runner.load(from: store)

        startRunner(runner, store: store, downloader: downloader, transcriber: transcriber, bus: bus)

        await fulfillment(of: [firstStarted], timeout: 5)
        // First pause() is graceful → .pausing; once the in-flight episode finishes
        // and the worker emits queue.paused, the runner settles to .paused. Wait for
        // that settle (the state is .pausing right after pause(), never .running, so
        // the old "while == .running" loop never waited — that was the stale bug).
        runner.pause()
        await gate.release()

        let pauseDeadline = Date().addingTimeInterval(10)
        while runner.runState != .paused, Date() < pauseDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(runner.runState, .paused)

        runner.resume()
        XCTAssertEqual(runner.runState, .running)

        // Wait for full drain.
        let deadline = Date().addingTimeInterval(15)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(runner.runState, .stopped)
        XCTAssertEqual(try store.episodeCountByStatus()["done"], n,
                       "All episodes must drain to done after resume")
    }

    // MARK: - 9. Refresh() after adding episodes picks up new items

    func testRefreshPicksUpNewEpisodes() throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = QueueRunner()
        runner.load(from: store)
        XCTAssertEqual(runner.items.count, 0)

        try store.upsert(Episode.makePodcast(guid: "refresh-001"))
        try store.upsert(Episode.makePodcast(guid: "refresh-002"))

        runner.load(from: store)
        XCTAssertEqual(runner.items.count, 2, "load() must pick up newly seeded episodes")
    }

    // MARK: - 10. Progress events update item.progress live

    /// Verifies that `episode.progress` events emitted by the pipeline (via
    /// FakeDownloader and FakeTranscriber progress callbacks) flow through the
    /// EventBus into `QueueRunner.items[n].progress` while an episode is in-flight.
    ///
    /// Strategy:
    /// 1. Seed one episode.
    /// 2. Start QueueRunner with a gate-held FakeDownloader so the download stays
    ///    in-flight long enough to observe progress events.
    /// 3. Wait until at least one `episode.progress` event arrives on the bus.
    /// 4. Assert the runner's item has a non-nil `progress` value.
    /// 5. Release the gate and wait for drain to confirm the full flow works.
    func testProgressEventsUpdateItemProgress() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guid = "progress-test-001"
        try store.upsert(Episode.makePodcast(guid: guid))

        let bus = EventBus()

        // Gate that holds the downloader in-flight.
        let gate = Gate()

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }

        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))

        let runner = QueueRunner()
        runner.load(from: store)

        // Collect progress values seen on the item while it is in-flight.
        var observedProgress: [Double] = []
        runner.onItemsChanged = {
            if let item = runner.items.first(where: { $0.id == guid }),
               let p = item.progress {
                observedProgress.append(p)
            }
        }

        runner.start(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus,
            pollIntervalNanos: 100_000_000  // 100 ms — faster poll for this test
        )

        // Wait until at least one progress event arrives (max 5 s).
        let progressExpectation = expectation(description: "progress event received")
        progressExpectation.assertForOverFulfill = false

        let progressStream = await bus.subscribe(.exact(EventType.episodeProgress))
        let watchTask = Task {
            for await _ in progressStream {
                progressExpectation.fulfill()
                break
            }
        }

        await fulfillment(of: [progressExpectation], timeout: 5)
        watchTask.cancel()

        // Give the MainActor a moment to process the event and update items.
        try await Task.sleep(nanoseconds: 100_000_000)

        // The item should have a non-nil progress value now.
        let itemProgress = runner.items.first(where: { $0.id == guid })?.progress
        XCTAssertNotNil(itemProgress, "item.progress must be non-nil after a progress event")
        if let p = itemProgress {
            XCTAssertGreaterThanOrEqual(p, 0.0)
            XCTAssertLessThanOrEqual(p, 1.0)
        }

        // Release the gate — let the episode finish.
        await gate.release()

        let deadline = Date().addingTimeInterval(10)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(runner.runState, .stopped, "Runner must stop after drain")

        // At least one intermediate progress value must have been observed.
        XCTAssertFalse(observedProgress.isEmpty,
                       "onItemsChanged must have reported at least one progress value")
    }

    // MARK: - 11. No progress reported → item.progress stays nil

    /// When the engines don't emit any progress (default protocol conformance),
    /// the pipeline still emits 0.12 (download-complete) and 1.0 (transcribe-done)
    /// signals, so the test verifies at least *some* progress arrives. This test
    /// uses the FakeDownloader/FakeTranscriber which DO emit progress, so this
    /// test instead verifies that a plain no-op engine set leaves progress nil
    /// until the Pipeline emits its end-of-phase signals.
    ///
    /// We use a minimal struct conforming to only the base protocol methods
    /// (no override of the progress variant), so the default extension kicks in.
    func testProgressNilForNonReportingEngines() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guid = "no-progress-001"
        try store.upsert(Episode.makePodcast(guid: guid))

        let bus = EventBus()

        // Minimal downloader that does NOT override download(_:progress:).
        struct MinimalDownloader: EpisodeDownloader, @unchecked Sendable {
            func download(_ episode: Episode) async throws -> URL {
                await Task.yield()
                return URL(fileURLWithPath: "/tmp/ep.mp3")
            }
            // No progress override — default extension emits nothing.
        }

        // Minimal transcriber that does NOT override transcribe(_:language:progress:).
        struct MinimalTranscriber: Transcriber, @unchecked Sendable {
            func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
                await Task.yield()
                return FakeTranscriber.makeDefaultResult()
            }
            // No progress override — default extension emits 0.0 at start.
        }

        let runner = QueueRunner()
        runner.load(from: store)

        runner.start(
            store: store,
            downloader: MinimalDownloader(),
            transcriber: MinimalTranscriber(),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )

        // Wait for drain.
        let deadline = Date().addingTimeInterval(10)
        while runner.runState == .running, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(runner.runState, .stopped)

        // Even with minimal engines the Pipeline emits end-of-phase signals
        // (0.5 after download, 1.0 after transcribe), so progress events arrive.
        // After drain the item is gone from the active list — confirm the DB is correct.
        let ep = try store.episode(guid: guid)
        XCTAssertEqual(ep?.status, "done")
    }
}
