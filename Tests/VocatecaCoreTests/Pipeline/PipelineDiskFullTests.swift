import XCTest
import Foundation
@testable import VocatecaCore

/// Stability wave 6 — Package B (M12): a disk-full (`ENOSPC`) download write is
/// its OWN category. The episode must be REQUEUED (→ pending, no attempt burned,
/// no error_text) — NOT permanently failed — and a `queueDiskFull` event must be
/// emitted so the UI can pause the queue + banner.
final class PipelineDiskFullTests: XCTestCase {

    private func makePipeline(
        store: StateStore,
        downloader: any EpisodeDownloader,
        bus: EventBus
    ) -> Pipeline {
        Pipeline(
            store: store,
            downloader: downloader,
            transcriber: FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult())),
            ocrProcessor: FakeOCRProcessor(),
            libraryWriter: FakeLibraryWriter(outputURL: URL(fileURLWithPath: "/tmp/should-not-write.md")),
            bus: bus
        )
    }

    // MARK: - Requeue, don't fail

    func testDiskFullDownloadRequeuesWithoutBurningAttempt() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed with a non-zero attempts so we can prove it is NOT incremented.
        let ep = Episode.makePodcast(guid: "disk-full-1", attempts: 1)
        try store.upsert(ep)

        let downloader = FakeDownloader(.failDiskFull("no space left on device"))
        let bus = EventBus()
        let pipeline = makePipeline(store: store, downloader: downloader, bus: bus)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .pending,
                       "a disk-full download must requeue, not fail")
        let saved = try XCTUnwrap(store.episode(guid: "disk-full-1"))
        XCTAssertEqual(saved.status, "pending")
        XCTAssertEqual(saved.attempts, 1, "disk-full must NOT burn a retry attempt")
        XCTAssertNil(saved.errorText, "disk-full is not a per-episode failure — no error_text")
    }

    // MARK: - Emits queueDiskFull so the UI can pause + banner

    func testDiskFullEmitsQueueDiskFullEvent() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "disk-full-2", attempts: 0)
        try store.upsert(ep)

        let bus = EventBus()
        let received = expectation(description: "queueDiskFull event received")
        received.assertForOverFulfill = false
        let stream = await bus.subscribe(.exact(EventType.queueDiskFull))
        let watch = Task {
            for await _ in stream { received.fulfill(); break }
        }

        let downloader = FakeDownloader(.failDiskFull("ENOSPC"))
        let pipeline = makePipeline(store: store, downloader: downloader, bus: bus)
        _ = await pipeline.process(ep)

        await fulfillment(of: [received], timeout: 5)
        watch.cancel()
    }

    // MARK: - Distinct from a permanent failure (regression guard)

    func testPermanentDownloadStillFails() async throws {
        // Sanity: the disk-full change must NOT reclassify genuine permanent
        // failures — a 404-style permanent still fails the episode.
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "perm-1", attempts: 0)
        try store.upsert(ep)

        let downloader = FakeDownloader(.failPermanent("HTTP 404"))
        let bus = EventBus()
        let pipeline = makePipeline(store: store, downloader: downloader, bus: bus)

        let result = await pipeline.process(ep)
        XCTAssertEqual(result.finalStatus, .failed, "a permanent failure must still fail")
        let saved = try XCTUnwrap(store.episode(guid: "perm-1"))
        XCTAssertEqual(saved.status, "failed")
    }
}
