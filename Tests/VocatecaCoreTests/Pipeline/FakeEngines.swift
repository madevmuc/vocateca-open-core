import Foundation
@testable import VocatecaCore

// MARK: - FakeDownloader

/// A controllable fake downloader for pipeline tests.
///
/// Configured with a sequence of `Behaviour` values; each `download(_:)` call
/// consumes the next behaviour in the queue. When the queue is exhausted the
/// last behaviour is repeated.
///
/// Internally uses a `NSLock` so it is safe to call from multiple concurrent
/// tasks (required for `QueueWorker` concurrency tests).
final class FakeDownloader: EpisodeDownloader, @unchecked Sendable {

    enum Behaviour {
        /// Return a fixed URL (success).
        case succeed(URL)
        /// Throw a transient `PipelineError`.
        case failTransient(String)
        /// Throw a permanent `PipelineError`.
        case failPermanent(String)
        /// Throw a skip `PipelineError`.
        case skip(String)
        /// Throw `PipelineError.cancelled` — models a Stop/hard-pause during
        /// download (what `URLSessionDownloader.classifyError` now produces for
        /// `URLError.cancelled` / `CancellationError`).
        case failCancelled(String)
        /// Throw `PipelineError.diskFull` — models an `ENOSPC` write during
        /// download (M12). The pipeline must requeue (→ pending, no attempt burn)
        /// and emit `queueDiskFull`, not permanently fail the episode.
        case failDiskFull(String)
    }

    private let lock = NSLock()
    private var behaviours: [Behaviour]
    private var _callCount: Int = 0
    private var _maxConcurrent: Int = 0
    private var _currentConcurrent: Int = 0
    private var _perGuidCount: [String: Int] = [:]

    /// Total number of times `download(_:)` was called.
    var callCount: Int { lock.withLock { _callCount } }
    /// Peak concurrent calls observed (for concurrency cap tests).
    var maxConcurrentCalls: Int { lock.withLock { _maxConcurrent } }
    /// The highest number of times any single guid was downloaded — must be 1 if
    /// the queue claim is atomic (no double-claim). Catches the C1 regression.
    var maxPerGuidCount: Int { lock.withLock { _perGuidCount.values.max() ?? 0 } }

    /// Optional gate: when set, every `download(_:)` awaits this before returning.
    /// Used to hold downloads in-flight while the test pauses the worker.
    var gate: (@Sendable () async -> Void)?
    /// Optional hold (nanoseconds) each download sleeps, so concurrent tasks
    /// genuinely overlap (lets concurrency-cap tests observe real parallelism).
    var holdNanos: UInt64 = 0
    /// Optional signal fired (once) when the first download begins.
    var onFirstDownloadStarted: (@Sendable () -> Void)?
    private var _firstStartedFired = false

    init(behaviours: [Behaviour]) {
        self.behaviours = behaviours
    }

    convenience init(_ single: Behaviour) {
        self.init(behaviours: [single])
    }

    func download(_ episode: Episode) async throws -> URL {
        return try await download(episode, progress: { _ in })
    }

    /// Progress-aware override: emits 0.25 and 0.75 fractions before returning,
    /// so tests can assert that the QueueRunner picks up intermediate progress.
    func download(_ episode: Episode, progress: ProgressReporter) async throws -> URL {
        let (behaviour, fireFirst) = lock.withLock { () -> (Behaviour, Bool) in
            _callCount += 1
            _currentConcurrent += 1
            if _currentConcurrent > _maxConcurrent { _maxConcurrent = _currentConcurrent }
            _perGuidCount[episode.guid, default: 0] += 1
            let idx = min(_callCount - 1, behaviours.count - 1)
            let fire = !_firstStartedFired
            _firstStartedFired = true
            return (behaviours[idx], fire)
        }
        defer {
            lock.withLock { _currentConcurrent -= 1 }
        }

        if fireFirst { onFirstDownloadStarted?() }

        // Emit initial progress fractions BEFORE the gate so tests can observe
        // in-flight progress while the download is still held open.
        progress(0.25)
        await Task.yield()
        progress(0.75)
        await Task.yield()

        if let gate = gate { await gate() }

        // Yield to allow concurrent tasks to start (needed for concurrency cap testing).
        await Task.yield()

        if holdNanos > 0 { try? await Task.sleep(nanoseconds: holdNanos) }

        switch behaviour {
        case .succeed(let url):  return url
        case .failTransient(let msg): throw PipelineError.transient(msg)
        case .failPermanent(let msg): throw PipelineError.permanent(msg)
        case .skip(let msg):         throw PipelineError.skipped(msg)
        case .failCancelled(let msg): throw PipelineError.cancelled(msg)
        case .failDiskFull(let msg): throw PipelineError.diskFull(msg)
        }
    }
}

// MARK: - FakeTranscriber

/// A controllable fake transcriber.
///
/// Records how many times it was called and returns a fixed `TranscriptionResult`.
/// Throws `PipelineError` values according to the configured sequence.
final class FakeTranscriber: Transcriber, @unchecked Sendable {

    enum Behaviour {
        case succeed(TranscriptionResult)
        case failTransient(String)
        case failPermanent(String)
    }

    private let lock = NSLock()
    private var behaviours: [Behaviour]
    private var _callCount: Int = 0
    private var _maxConcurrent: Int = 0
    private var _currentConcurrent: Int = 0

    /// When `true`, models WhisperKit's cancellation semantics: if the task is
    /// already cancelled at call time the transcriber RETURNS its success result
    /// (a partial transcript) instead of throwing — exactly the path that made
    /// the pipeline persist a truncated transcript as `.done`. The pipeline's
    /// post-call `Task.checkCancellation()` is what must catch this.
    var partialOnCancel: Bool = false

    /// Number of times `transcribe(audioURL:language:)` was called.
    var callCount: Int { lock.withLock { _callCount } }
    var maxConcurrentCalls: Int { lock.withLock { _maxConcurrent } }

    init(behaviours: [Behaviour]) {
        self.behaviours = behaviours
    }

    convenience init(_ single: Behaviour) {
        self.init(behaviours: [single])
    }

    static func makeDefaultResult() -> TranscriptionResult {
        TranscriptionResult(
            text: "Hello world",
            segments: [TranscriptionSegment(start: 0, end: 1.0, text: "Hello world")],
            language: "en"
        )
    }

    func transcribe(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        return try await transcribe(audioURL: audioURL, language: language, progress: { _ in })
    }

    /// Progress-aware override: emits 0.0 at start and 0.5 mid-way before returning.
    func transcribe(audioURL: URL, language: String?, progress: @escaping ProgressReporter) async throws -> TranscriptionResult {
        let behaviour = lock.withLock { () -> Behaviour in
            _callCount += 1
            _currentConcurrent += 1
            if _currentConcurrent > _maxConcurrent { _maxConcurrent = _currentConcurrent }
            let idx = min(_callCount - 1, behaviours.count - 1)
            return behaviours[idx]
        }
        defer {
            lock.withLock { _currentConcurrent -= 1 }
        }

        progress(0.0)
        await Task.yield()
        progress(0.5)
        await Task.yield()

        // WhisperKit cancellation model: on a cancelled task the engine returns
        // whatever it decoded so far (no throw). The pipeline must reject this via
        // its own checkCancellation — so here we return the success result even
        // though the task is cancelled, to prove the pipeline catches it.
        if partialOnCancel, Task.isCancelled {
            if case let .succeed(r) = behaviour { return r }
        }

        switch behaviour {
        case .succeed(let r):        return r
        case .failTransient(let msg): throw PipelineError.transient(msg)
        case .failPermanent(let msg): throw PipelineError.permanent(msg)
        }
    }
}

// MARK: - FakeOCRProcessor

/// A controllable fake OCR processor.
final class FakeOCRProcessor: ImageOCRProcessor, @unchecked Sendable {

    private let lock = NSLock()
    private var _callCount: Int = 0
    private let result: String

    var callCount: Int { lock.withLock { _callCount } }

    init(result: String = "OCR text") {
        self.result = result
    }

    func process(_ episode: Episode, mediaPath: URL) async throws -> String {
        lock.withLock { _callCount += 1 }
        await Task.yield()
        return result
    }
}

// MARK: - FakeLibraryWriter

/// A controllable fake library writer.
///
/// Returns a stable temp URL. Records `transcript` and `ocrText` passed to it
/// for assertion in tests.
final class FakeLibraryWriter: LibraryWriter, @unchecked Sendable {

    private let lock = NSLock()
    private var _callCount: Int = 0
    private var _lastTranscript: TranscriptionResult? = nil
    private var _lastOcrText: String? = nil

    var callCount: Int { lock.withLock { _callCount } }
    var lastTranscript: TranscriptionResult? { lock.withLock { _lastTranscript } }
    var lastOcrText: String? { lock.withLock { _lastOcrText } }

    private let outputURL: URL

    init(outputURL: URL = URL(fileURLWithPath: "/tmp/fake-transcript.md")) {
        self.outputURL = outputURL
    }

    func write(
        episode: Episode,
        transcript: TranscriptionResult?,
        ocrText: String?,
        mediaPath: URL?
    ) async throws -> URL {
        lock.withLock {
            _callCount += 1
            _lastTranscript = transcript
            _lastOcrText = ocrText
        }
        await Task.yield()
        return outputURL
    }
}

// MARK: - Test helpers

extension StateStore {

    /// Creates a fresh `StateStore` backed by a temp SQLite file with v2 migrations.
    /// Caller owns the returned `URL` (temp directory) and must clean it up.
    static func makeTemp() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
        return (store, dir)
    }
}

extension Episode {

    /// A minimal podcast episode, suitable for seeding pipeline tests.
    static func makePodcast(
        guid: String = UUID().uuidString,
        showSlug: String = "test-show",
        title: String = "Test Episode",
        pubDate: String = "2024-01-01",
        status: String = "pending",
        priority: Int = 0,
        durationSec: Int? = nil,
        attempts: Int = 0
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: title,
            pubDate: pubDate,
            mp3Url: "https://example.com/\(guid).mp3",
            status: status,
            durationSec: durationSec,
            priority: priority,
            attempts: attempts
        )
    }

    /// An Instagram image post episode.
    static func makeInstagramPost(
        guid: String = UUID().uuidString,
        showSlug: String = "ig-show",
        title: String = "IG Post",
        pubDate: String = "2024-01-01",
        priority: Int = 0
    ) -> Episode {
        Episode(
            guid: guid,
            showSlug: showSlug,
            title: title,
            pubDate: pubDate,
            mp3Url: "https://example.com/\(guid).jpg",
            status: "pending",
            priority: priority,
            igKind: "post",
            mediaType: "image"
        )
    }
}
