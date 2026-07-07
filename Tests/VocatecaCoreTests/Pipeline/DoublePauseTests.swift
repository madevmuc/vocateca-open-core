import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - DoublePauseTests
//
// Tests for the double-pause state machine in QueueRunner.
//
// State machine:
//   .stopped  --start()-->  .running
//   .running  --pause()-->  .pausing   (first press — graceful)
//   .pausing  --pause()-->  .paused    (second press — immediate)
//   .pausing  --resume()--> .running   (cancel graceful pause, resume)
//   .paused   --resume()--> .running
//   .running  --stop()-->   .stopped
//   .pausing  --stop()-->   .stopped
//   .paused   --stop()-->   .stopped

@MainActor
final class DoublePauseTests: XCTestCase {

    // MARK: - Helpers

    private func makeRunner(store: StateStore, bus: EventBus) -> QueueRunner {
        let runner = QueueRunner()
        runner.load(from: store)
        return runner
    }

    private func startRunner(_ runner: QueueRunner, store: StateStore, bus: EventBus) {
        runner.start(
            store: store,
            downloader: FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3"))),
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )
    }

    // MARK: - 1. First pause → .pausing; second pause → .paused

    func testDoublePauseStateMachine() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed enough items that the drain won't finish before our pause calls.
        for i in 0..<20 {
            try store.upsert(Episode.makePodcast(guid: "dp-\(i)"))
        }

        let gate = Gate()
        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let bus = EventBus()

        let runner = QueueRunner()
        runner.load(from: store)

        runner.start(
            store: store,
            downloader: downloader,
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )
        XCTAssertEqual(runner.runState, .running, "Should be running after start()")

        // First pause press → .pausing (graceful)
        runner.pause()
        XCTAssertEqual(runner.runState, .pausing,
                       "First pause() should transition to .pausing")

        // Second pause press → .paused (immediate)
        runner.pause()
        XCTAssertEqual(runner.runState, .paused,
                       "Second pause() should transition to .paused immediately")

        // Clean up — release gate so tasks can end.
        runner.stop()
        await gate.release()
    }

    // MARK: - 2. Pausing → resume() → running

    func testResumeFromPausingCancelsGracefulPause() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<20 {
            try store.upsert(Episode.makePodcast(guid: "rp-\(i)"))
        }

        let gate = Gate()
        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let bus = EventBus()

        let runner = QueueRunner()
        runner.load(from: store)
        runner.start(
            store: store,
            downloader: downloader,
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )

        XCTAssertEqual(runner.runState, .running)

        // First pause → .pausing
        runner.pause()
        XCTAssertEqual(runner.runState, .pausing)

        // Resume from .pausing → should go back to .running
        runner.resume()
        XCTAssertEqual(runner.runState, .running,
                       "resume() from .pausing should return to .running")

        // Cleanup
        runner.stop()
        await gate.release()
    }

    // MARK: - 3. Stop works from .pausing state

    func testStopFromPausingState() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<20 {
            try store.upsert(Episode.makePodcast(guid: "sp-\(i)"))
        }

        let gate = Gate()
        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let bus = EventBus()

        let runner = QueueRunner()
        runner.load(from: store)
        runner.start(
            store: store,
            downloader: downloader,
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )

        runner.pause()
        XCTAssertEqual(runner.runState, .pausing)

        runner.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(runner.runState, .stopped,
                       "stop() from .pausing must reach .stopped")
    }

    // MARK: - 4. Pause on already-paused is a no-op

    func testPauseOnPausedIsNoOp() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<20 {
            try store.upsert(Episode.makePodcast(guid: "noop-\(i)"))
        }

        let gate = Gate()
        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/ep.mp3")))
        downloader.gate = { await gate.wait() }
        let bus = EventBus()

        let runner = QueueRunner()
        runner.load(from: store)
        runner.start(
            store: store,
            downloader: downloader,
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(),
            bus: bus
        )

        // Go to fully-paused via two presses.
        runner.pause()
        runner.pause()
        XCTAssertEqual(runner.runState, .paused)

        // A third press while already .paused should be a no-op.
        runner.pause()
        XCTAssertEqual(runner.runState, .paused,
                       "pause() on already-.paused state must be a no-op")

        runner.stop()
        await gate.release()
    }
}
