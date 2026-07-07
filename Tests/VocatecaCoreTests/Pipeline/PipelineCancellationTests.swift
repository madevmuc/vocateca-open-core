import XCTest
import Foundation
@testable import VocatecaCore

/// Stability wave 1 — package 1 (C1 + H1): cancellation is neither an error nor
/// a success. A Stop / hard-pause mid-download or mid-transcribe must reset the
/// episode to `pending` WITHOUT bumping `attempts` and WITHOUT persisting a
/// truncated transcript as `.done`.
final class PipelineCancellationTests: XCTestCase {

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
            libraryWriter: FakeLibraryWriter(outputURL: URL(fileURLWithPath: "/tmp/should-not-write.md"))
        )
    }

    // MARK: - Bug B: cancel during download → pending, no attempts bump

    func testDownloadCancelRequeuesWithoutBumpingAttempts() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed with a non-zero attempts so we can prove it is NOT incremented.
        let ep = Episode.makePodcast(guid: "cancel-dl", attempts: 1)
        try store.upsert(ep)

        let downloader  = FakeDownloader(.failCancelled("stopped mid-download"))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let pipeline = makePipeline(store: store, downloader: downloader, transcriber: transcriber)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .pending,
                       "a cancelled download must requeue, not fail")
        let saved = try XCTUnwrap(store.episode(guid: "cancel-dl"))
        XCTAssertEqual(saved.status, "pending")
        XCTAssertEqual(saved.attempts, 1, "cancellation must NOT burn a retry attempt")
        XCTAssertNil(saved.errorText, "cancellation is not a failure — no error_text")
        XCTAssertEqual(transcriber.callCount, 0, "transcription must not run after a cancelled download")
    }

    // MARK: - Bug A: cancel during transcribe → NOT done (partial rejected)

    func testTranscribeCancelDoesNotPersistPartialAsDone() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "cancel-tr", attempts: 0)
        try store.upsert(ep)

        // Downloader succeeds; transcriber models WhisperKit returning a PARTIAL
        // transcript (no throw) once the task is cancelled.
        let downloader  = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/cancel-tr.mp3")))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        transcriber.partialOnCancel = true
        let writer = FakeLibraryWriter(outputURL: URL(fileURLWithPath: "/tmp/cancel-tr.md"))
        let pipeline = Pipeline(
            store: store, downloader: downloader, transcriber: transcriber,
            ocrProcessor: FakeOCRProcessor(), libraryWriter: writer)

        // Run the pipeline in a task and cancel it immediately: by the time the
        // (post-download) transcribe call runs, the task is cancelled, so the fake
        // returns a partial. The pipeline's post-call checkCancellation must catch
        // it and requeue rather than persisting `.done`.
        let task = Task { await pipeline.process(ep) }
        task.cancel()
        let result = await task.value

        XCTAssertNotEqual(result.finalStatus, .done,
                          "a cancelled transcription must NOT be persisted as done")
        let saved = try XCTUnwrap(store.episode(guid: "cancel-tr"))
        XCTAssertNotEqual(saved.status, "done",
                          "DB status must not be done after cancellation")
        XCTAssertEqual(writer.callCount, 0,
                       "library write (and thus downstream push) must not run for a cancelled transcript")
    }
}
