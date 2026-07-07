import XCTest
import Foundation
import GRDB
@testable import VocatecaCore

// MARK: - PipelineTests

/// Tests for `Pipeline.process(_:)` using fake engines.
///
/// All tests use a temp `StateStore` (v2 schema, in-memory temp file)
/// seeded with episodes, and `Fake*` engines — no real network, Whisper,
/// or disk I/O occurs.
final class PipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makePipeline(
        store: StateStore,
        downloader: any EpisodeDownloader,
        transcriber: any Transcriber,
        ocr: any ImageOCRProcessor,
        writer: any LibraryWriter,
        forceStore: ForceTranscribeStore = ForceTranscribeStore()
    ) -> Pipeline {
        Pipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocrProcessor: ocr,
            libraryWriter: writer,
            forceStore: forceStore
        )
    }

    // MARK: - 1. Happy path podcast episode

    /// Seed 1 pending podcast episode; run pipeline; assert pending→done,
    /// transcriptPath set, and episode.transcribed event present.
    func testHappyPathPodcast() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "pod-001")
        try store.upsert(ep)

        let mediaURL = URL(fileURLWithPath: "/tmp/pod-001.mp3")
        let transcriptURL = URL(fileURLWithPath: "/tmp/pod-001.md")

        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let ocr         = FakeOCRProcessor()
        let writer      = FakeLibraryWriter(outputURL: transcriptURL)

        let pipeline = makePipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocr: ocr,
            writer: writer
        )

        let result = await pipeline.process(ep)

        // Result assertions.
        XCTAssertEqual(result.guid, "pod-001")
        XCTAssertEqual(result.finalStatus, .done)
        XCTAssertEqual(result.transcriptPath, transcriptURL.path)

        // DB status assertions.
        let saved = try XCTUnwrap(store.episode(guid: "pod-001"))
        XCTAssertEqual(saved.status, "done")
        XCTAssertNotNil(saved.completedAt)
        // Error fields cleared on DONE.
        XCTAssertNil(saved.errorText)
        XCTAssertNil(saved.errorCategory)
        XCTAssertEqual(saved.attempts, 0)

        // OCR must NOT have been called for a podcast episode.
        XCTAssertEqual(ocr.callCount, 0, "OCR must not be called for podcast episodes")
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(writer.callCount, 1)
        XCTAssertNotNil(writer.lastTranscript, "LibraryWriter must receive the transcript")
        XCTAssertNil(writer.lastOcrText, "LibraryWriter must not receive OCR text for podcasts")

        // episode.transcribed event must be in the events table.
        let events = try store.queryEvents(guid: "pod-001")
        let transcribedEvents = events.filter { $0["type"] as? String == EventType.episodeTranscribed }
        XCTAssertFalse(transcribedEvents.isEmpty, "episode.transcribed event must be emitted")
    }

    // MARK: - 1b. Empty transcript → retry once, then fail

    /// A transcriber that returns a completely empty transcript is a failure, not
    /// a "done" episode: the pipeline retries once (→ pending) and fails on the
    /// second empty result (→ failed) rather than silently writing no transcript.
    func testEmptyTranscriptRetriesOnceThenFails() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "pod-empty")
        try store.upsert(ep)

        let mediaURL    = URL(fileURLWithPath: "/tmp/pod-empty.mp3")
        let downloader  = FakeDownloader(.succeed(mediaURL))
        let empty       = TranscriptionResult(text: "", segments: [], language: nil)
        // Return empty on every call.
        let transcriber = FakeTranscriber(.succeed(empty))
        let ocr         = FakeOCRProcessor()
        let writer      = FakeLibraryWriter(outputURL: URL(fileURLWithPath: "/tmp/pod-empty.md"))

        let pipeline = makePipeline(
            store: store, downloader: downloader,
            transcriber: transcriber, ocr: ocr, writer: writer
        )

        // First attempt → retry (back to pending), nothing written.
        let r1 = await pipeline.process(ep)
        XCTAssertEqual(r1.finalStatus, .pending, "first empty transcript must retry")
        let after1 = try XCTUnwrap(store.episode(guid: "pod-empty"))
        XCTAssertEqual(after1.status, "pending")
        XCTAssertEqual(writer.callCount, 0, "no transcript must be written for an empty result")

        // Second attempt → fail.
        let r2 = await pipeline.process(after1)
        XCTAssertEqual(r2.finalStatus, .failed, "second empty transcript must fail")
        let after2 = try XCTUnwrap(store.episode(guid: "pod-empty"))
        XCTAssertEqual(after2.status, "failed")
        XCTAssertNotNil(after2.errorText)
        XCTAssertEqual(writer.callCount, 0)
    }

    // MARK: - 2. Instagram image post (OCR, not transcribe)

    func testInstagramImagePost() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makeInstagramPost(guid: "ig-post-001")
        try store.upsert(ep)

        let mediaURL     = URL(fileURLWithPath: "/tmp/ig-post-001.jpg")
        let transcriptURL = URL(fileURLWithPath: "/tmp/ig-post-001.md")

        let downloader  = FakeDownloader(.succeed(mediaURL))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let ocr         = FakeOCRProcessor(result: "Caption text from image")
        let writer      = FakeLibraryWriter(outputURL: transcriptURL)

        let pipeline = makePipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocr: ocr,
            writer: writer
        )

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.guid, "ig-post-001")
        XCTAssertEqual(result.finalStatus, .done)

        // Transcriber must NOT have been called.
        XCTAssertEqual(transcriber.callCount, 0, "Transcriber must not be called for image posts")
        // OCR must have been called exactly once.
        XCTAssertEqual(ocr.callCount, 1, "OCR must be called for image posts")
        // LibraryWriter must receive OCR text (not transcript).
        XCTAssertNil(writer.lastTranscript, "transcript must be nil for image posts")
        XCTAssertEqual(writer.lastOcrText, "Caption text from image")

        let saved = try XCTUnwrap(store.episode(guid: "ig-post-001"))
        XCTAssertEqual(saved.status, "done")
    }

    // MARK: - 3. Transient failure → retry (attempts incremented)

    func testTransientFailureIncrementsAttempts() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "transient-001", attempts: 0)
        try store.upsert(ep)

        // Downloader fails transiently once.
        let downloader  = FakeDownloader(.failTransient("network timeout"))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let ocr         = FakeOCRProcessor()
        let writer      = FakeLibraryWriter()

        let pipeline = makePipeline(
            store: store, downloader: downloader,
            transcriber: transcriber, ocr: ocr, writer: writer
        )

        let result = await pipeline.process(ep)

        // With 0 attempts before → attemptsAfterBump = 1 < 3 → shouldRetry = true → pending.
        XCTAssertEqual(result.finalStatus, .pending,
                       "After 1 transient failure (below cap) status should be pending for re-queue")

        let saved = try XCTUnwrap(store.episode(guid: "transient-001"))
        XCTAssertEqual(saved.status, "pending")
        XCTAssertEqual(saved.attempts, 1, "Attempts must be incremented")
    }

    // MARK: - 4. Permanent failure → FAILED

    func testPermanentFailure() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "perm-001")
        try store.upsert(ep)

        let downloader  = FakeDownloader(.failPermanent("404 not found"))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let ocr         = FakeOCRProcessor()
        let writer      = FakeLibraryWriter()

        let pipeline = makePipeline(
            store: store, downloader: downloader,
            transcriber: transcriber, ocr: ocr, writer: writer
        )

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .failed)

        let saved = try XCTUnwrap(store.episode(guid: "perm-001"))
        XCTAssertEqual(saved.status, "failed")
        XCTAssertNotNil(saved.errorText, "error_text must be set on permanent failure")
        XCTAssertNotNil(saved.errorCategory)

        // episode.failed event must be present.
        let events = try store.queryEvents(guid: "perm-001")
        let failedEvents = events.filter { $0["type"] as? String == EventType.episodeFailed }
        XCTAssertFalse(failedEvents.isEmpty, "episode.failed event must be emitted")
    }

    // MARK: - 5. Skip → SKIPPED

    func testSkipError() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "skip-001")
        try store.upsert(ep)

        let downloader  = FakeDownloader(.skip("YouTube Short"))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let ocr         = FakeOCRProcessor()
        let writer      = FakeLibraryWriter()

        let pipeline = makePipeline(
            store: store, downloader: downloader,
            transcriber: transcriber, ocr: ocr, writer: writer
        )

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .skipped)

        let saved = try XCTUnwrap(store.episode(guid: "skip-001"))
        XCTAssertEqual(saved.status, "skipped")

        let events = try store.queryEvents(guid: "skip-001")
        let skippedEvents = events.filter { $0["type"] as? String == EventType.episodeSkipped }
        XCTAssertFalse(skippedEvents.isEmpty, "episode.skipped event must be emitted")
    }

    // MARK: - 6. No-speech detected → SKIPPED (no library write)

    /// When the transcription result triggers `NoSpeechDetector`, the pipeline
    /// must mark the episode `.skipped`, NOT call `libraryWriter`, and return
    /// a `.skipped` result.
    func testNoSpeechDetectedSkipsEpisode() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The no-speech SKIP is opt-in per show: a show defaults to "Always
        // spoken word" (assumeSpeech == true), which BYPASSES the skip. To
        // exercise the skip path this episode's show must be set to auto-detect
        // (assumeSpeech == false). Install such a watchlist, saving + restoring
        // the real one so the test stays isolated. Episode.makePodcast defaults
        // showSlug to "test-show", so the installed show must match that slug.
        let watchlistURL = Paths.watchlistURL
        let savedWatchlist = try? Data(contentsOf: watchlistURL)
        defer {
            if let savedWatchlist { try? savedWatchlist.write(to: watchlistURL) }
            else { try? FileManager.default.removeItem(at: watchlistURL) }
        }
        try WatchlistStore(watchlist: Watchlist(shows: [
            Show(slug: "test-show", title: "Test Show",
                 rss: "https://example.com/rss", assumeSpeech: false)
        ])).save(to: watchlistURL)

        let ep = Episode.makePodcast(guid: "nospeak-001")
        try store.upsert(ep)

        let mediaURL = URL(fileURLWithPath: "/tmp/nospeak-001.mp3")

        let downloader = FakeDownloader(.succeed(mediaURL))

        // Build a TranscriptionResult that fires the noSpeechProb signal:
        // mean noSpeechProb = 0.85 > 0.60 threshold.
        let noSpeechResult = TranscriptionResult(
            text: "some sounds",
            segments: [
                TranscriptionSegment(start: 0, end: 5, text: "some sounds",
                                     noSpeechProb: 0.85, avgLogprob: -1.2)
            ],
            language: nil
        )
        let transcriber = FakeTranscriber(.succeed(noSpeechResult))
        let ocr    = FakeOCRProcessor()
        let writer = FakeLibraryWriter()

        let pipeline = makePipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocr: ocr,
            writer: writer
        )

        let result = await pipeline.process(ep)

        // Result must be skipped.
        XCTAssertEqual(result.finalStatus, .skipped,
                       "Episode with no speech must be marked skipped")
        XCTAssertNil(result.transcriptPath,
                     "No transcriptPath must be set when skipping")

        // Library writer must NOT have been called.
        XCTAssertEqual(writer.callCount, 0,
                       "LibraryWriter must not be called for no-speech episodes")

        // DB status must be skipped, with the no-speech reason persisted in
        // error_text (the only .skipped path that stores a reason — it powers the
        // informational "looks like music" notification and shows in details).
        let saved = try XCTUnwrap(store.episode(guid: "nospeak-001"))
        XCTAssertEqual(saved.status, "skipped")
        XCTAssertNotNil(saved.errorText, "no-speech skip must persist its reason")
        XCTAssertTrue(saved.errorText?.contains("No speech") ?? false,
                      "skip reason should explain it was a no-speech skip")

        // episode.skipped event must be present.
        let events = try store.queryEvents(guid: "nospeak-001")
        let skippedEvents = events.filter { $0["type"] as? String == EventType.episodeSkipped }
        XCTAssertFalse(skippedEvents.isEmpty, "episode.skipped event must be emitted")
    }

    /// Override: a force-flagged episode transcribes even when the result looks
    /// like no speech, and the one-shot flag is cleared afterwards.
    func testForceTranscribeOverridesNoSpeechSkip() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "force-001")
        try store.upsert(ep)

        let downloader = FakeDownloader(.succeed(URL(fileURLWithPath: "/tmp/force-001.mp3")))
        // A clearly no-speech result (high noSpeechProb) that WOULD be skipped…
        let noSpeechResult = TranscriptionResult(
            text: "la la la",
            segments: [TranscriptionSegment(start: 0, end: 5, text: "la la la",
                                            noSpeechProb: 0.95, avgLogprob: -1.5)],
            language: nil
        )
        let transcriber = FakeTranscriber(.succeed(noSpeechResult))
        let writer = FakeLibraryWriter()

        // …but the user has overridden it ("Transcribe anyway").
        let defaults = UserDefaults(suiteName: "force-test-\(UUID().uuidString)")!
        let forceStore = ForceTranscribeStore(defaults: defaults)
        forceStore.setForced(guid: "force-001")

        let pipeline = makePipeline(store: store, downloader: downloader,
                                    transcriber: transcriber, ocr: FakeOCRProcessor(),
                                    writer: writer, forceStore: forceStore)

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done,
                       "forced episode must transcribe despite no-speech")
        XCTAssertEqual(writer.callCount, 1, "library writer must run when forced")
        XCTAssertFalse(forceStore.isForced(guid: "force-001"),
                       "force flag is one-shot — cleared after use")
    }

    /// When the transcription result is normal speech, the pipeline must NOT skip.
    func testNormalSpeechNotSkipped() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ep = Episode.makePodcast(guid: "speech-001")
        try store.upsert(ep)

        let mediaURL     = URL(fileURLWithPath: "/tmp/speech-001.mp3")
        let transcriptURL = URL(fileURLWithPath: "/tmp/speech-001.md")

        let downloader = FakeDownloader(.succeed(mediaURL))

        // Normal speech: low noSpeechProb, varied text.
        let speechResult = TranscriptionResult(
            text: "Welcome to the show today we have a very interesting guest",
            segments: [
                TranscriptionSegment(start: 0, end: 5,
                                     text: "Welcome to the show today",
                                     noSpeechProb: 0.05, avgLogprob: -0.3),
                TranscriptionSegment(start: 5, end: 10,
                                     text: "we have a very interesting guest",
                                     noSpeechProb: 0.03, avgLogprob: -0.2)
            ],
            language: "en"
        )
        let transcriber = FakeTranscriber(.succeed(speechResult))
        let ocr    = FakeOCRProcessor()
        let writer = FakeLibraryWriter(outputURL: transcriptURL)

        let pipeline = makePipeline(
            store: store,
            downloader: downloader,
            transcriber: transcriber,
            ocr: ocr,
            writer: writer
        )

        let result = await pipeline.process(ep)

        XCTAssertEqual(result.finalStatus, .done,
                       "Normal speech episode must reach done status")
        XCTAssertEqual(writer.callCount, 1,
                       "LibraryWriter must be called for normal speech episodes")
    }

    // MARK: - 8. Max attempts: transient failing N+1 times → eventually FAILED

    func testMaxAttemptsTransient() async throws {
        let (store, dir) = try StateStore.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Episode already at attempts = maxAttempts - 1 (so next bump hits the cap).
        // Pipeline.maxAttempts = 3. attemptsAfterBump = 3, which is NOT < 3 → no retry.
        let ep = Episode.makePodcast(guid: "maxattempts-001", attempts: Pipeline.maxAttempts - 1)
        try store.upsert(ep)

        let downloader  = FakeDownloader(.failTransient("still failing"))
        let transcriber = FakeTranscriber(.succeed(FakeTranscriber.makeDefaultResult()))
        let ocr         = FakeOCRProcessor()
        let writer      = FakeLibraryWriter()

        let pipeline = makePipeline(
            store: store, downloader: downloader,
            transcriber: transcriber, ocr: ocr, writer: writer
        )

        let result = await pipeline.process(ep)

        // At maxAttempts the transient becomes permanent.
        XCTAssertEqual(result.finalStatus, .failed,
                       "Transient failure at attempts == maxAttempts must result in FAILED")

        let saved = try XCTUnwrap(store.episode(guid: "maxattempts-001"))
        XCTAssertEqual(saved.status, "failed")
        XCTAssertEqual(saved.attempts, Pipeline.maxAttempts,
                       "Attempts must reach maxAttempts (\(Pipeline.maxAttempts))")
    }
}

// MARK: - StateStore event query helper for tests

extension StateStore {
    /// Queries events for a guid, returning them as `[[String: Any]]`.
    func queryEvents(guid: String) throws -> [[String: Any]] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: "SELECT * FROM events WHERE guid = ? ORDER BY id ASC",
                           arguments: [guid])
            )
            return rows.map { row -> [String: Any] in
                var dict: [String: Any] = [:]
                for col in row.columnNames {
                    dict[col] = row[col]
                }
                return dict
            }
        }
    }
}
