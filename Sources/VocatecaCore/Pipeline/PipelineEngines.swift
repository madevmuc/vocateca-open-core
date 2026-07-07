import Foundation

// MARK: - Progress reporting

/// A progress-report closure threaded into engine calls.
///
/// Called on an arbitrary task / thread — implementations must be `@Sendable`
/// so they are safe to call across actor boundaries. The single `Double`
/// argument is a 0.0–1.0 fraction of work completed.
///
/// Design note: we use a simple closure rather than adding a progress parameter
/// to every protocol method, keeping existing conformances unchanged. Engine
/// types that can report progress override `downloadWithProgress` /
/// `transcribeWithProgress`; others fall back to the default implementations
/// below which call the primary method and emit no intermediate updates.
public typealias ProgressReporter = @Sendable (Double) -> Void

// MARK: - Protocol seams (injected engines)

/// Downloads the remote media for an episode to a local file.
///
/// Implemented by the real network layer in production; replaced by a
/// `FakeDownloader` in tests — no real network or ffmpeg here.
public protocol EpisodeDownloader: Sendable {
    /// Downloads media for `episode` and returns the local `file://` URL
    /// where the audio/video was stored.
    ///
    /// - Throws: `PipelineError.transient` for network blips worth retrying;
    ///           `PipelineError.permanent` for unrecoverable errors (404, auth-gate);
    ///           `PipelineError.skipped` when the episode should be silently skipped.
    func download(_ episode: Episode) async throws -> URL

    /// Downloads media, calling `progress` periodically with 0.0–1.0 fractions.
    ///
    /// Default implementation calls `download(_:)` with no intermediate progress
    /// reports. Override to emit real byte-based fractions.
    func download(_ episode: Episode, progress: ProgressReporter) async throws -> URL
}

public extension EpisodeDownloader {
    /// Default: forward to the primary `download(_:)`, emit no intermediate events.
    func download(_ episode: Episode, progress: ProgressReporter) async throws -> URL {
        return try await download(episode)
    }
}

/// Writes the finished transcript (and optional sidecar files) to the library.
///
/// In production this renders markdown + persists to disk; in tests a
/// `FakeLibraryWriter` records calls and returns a temp URL.
public protocol LibraryWriter: Sendable {
    /// Writes transcript (and/or OCR text) for `episode` and returns the path
    /// to the produced transcript file (e.g. `<show>/<slug>.md`).
    ///
    /// - Parameters:
    ///   - episode: The episode metadata row.
    ///   - transcript: Result from the `Transcriber`, or `nil` for image-only paths.
    ///   - ocrText: Text extracted by OCR for image posts, or `nil`.
    ///   - mediaPath: The downloaded media file, or `nil` when unavailable.
    /// - Returns: URL of the written transcript file.
    func write(
        episode: Episode,
        transcript: TranscriptionResult?,
        ocrText: String?,
        mediaPath: URL?
    ) async throws -> URL
}

/// Extracts text from an image post via OCR.
///
/// Used for Instagram image posts/stories where there is no audio to transcribe.
/// The real implementation uses Apple Vision; tests use a `FakeOCRProcessor`.
public protocol ImageOCRProcessor: Sendable {
    /// Runs OCR on the image at `mediaPath` and returns the extracted text.
    ///
    /// - Parameters:
    ///   - episode: Episode metadata (for context / language hints).
    ///   - mediaPath: Local URL of the downloaded image file.
    /// - Returns: Extracted text string (may be empty for blank images).
    /// - Throws: `PipelineError.transient` or `.permanent` on OCR failure.
    func process(_ episode: Episode, mediaPath: URL) async throws -> String
}

// MARK: - PipelineError

/// Error taxonomy that drives the pipeline's retry / fail / skip decision.
///
/// Mirrors Python `core/errors.py` categories: transient errors are retried
/// up to the attempt cap; permanent errors fail immediately; skipped errors
/// mark the episode as SKIPPED (not a failure).
///
/// ## Retry rules (mirroring Python `errors.should_retry`):
/// - `.transient` AND `attempts < maxAttempts` (default 3) → `recordFailure(retry:true)` → back to PENDING.
/// - `.transient` AND `attempts >= maxAttempts`             → `recordFailure(retry:false)` → FAILED.
/// - `.permanent`                                           → FAILED immediately.
/// - `.skipped`                                             → SKIPPED (no failure recorded).
public enum PipelineError: Error, Sendable {
    /// Transient failure (network blip, disk full) — worth an automatic retry.
    case transient(String)
    /// Permanent failure (404, bad format, auth-gate) — do not retry.
    case permanent(String)
    /// Episode should be silently skipped (Short, filtered, etc.).
    case skipped(String)
    /// The step was **cancelled** (user Stop / hard-pause / worker teardown), not
    /// a failure. Must reset the episode to its pre-step state (`pending`) WITHOUT
    /// bumping `attempts` and WITHOUT a failure notification — a cancellation is
    /// neither an error nor a success. Distinct from `.transient` (which burns an
    /// attempt) so a Stop during a long download/transcribe never marks the
    /// episode `failed` or persists a truncated result.
    case cancelled(String)
    /// The step failed because the **disk is full** (`ENOSPC` /
    /// `NSFileWriteOutOfSpaceError`). M12: this is a machine condition, not a
    /// per-episode fault — a big backlog can fill the disk BETWEEN maintenance
    /// ticks. Like `.cancelled`, the episode is requeued to `pending` WITHOUT
    /// burning an attempt (its `.part`/model cache is preserved for resume once
    /// space is freed); additionally the whole queue is paused and a banner is
    /// raised. Distinct from `.permanent` — the old classification marked the
    /// episode permanently `failed`, which was wrong and unrecoverable.
    case diskFull(String)
}

// MARK: - Error category strings

/// Error category constants (mirrors Python `core/errors.py`).
/// Stored in `episodes.error_category` for grouping in the UI.
public enum ErrorCategory {
    public static let network  = "network"
    public static let download = "download"
    public static let notFound = "not_found"
    public static let tooLarge = "too_large"
    public static let format   = "format"
    public static let whisper  = "whisper"
    public static let disk     = "disk"
    public static let unknown  = "unknown"
    public static let ocr      = "ocr"
    /// A process crash detected via the launch reclaim (episode was still
    /// `downloading`/`transcribing` after too many restarts — a poison pill).
    public static let crash    = "crash"

    /// Classify a permanent failure into a canonical category using the pipeline
    /// `phase` it failed in plus keyword hints from the message. Keeps the stored
    /// `error_category` meaningful so the Failed-tab filters group correctly
    /// (previously every permanent failure was stored as `unknown`).
    ///
    /// Message keywords win over phase (a disk-full during download is a disk
    /// error, not a download error); otherwise the phase decides.
    public static func classify(phase: String, message: String) -> String {
        let m = message.lowercased()

        // Cross-cutting message signals first.
        if m.contains("no space") || m.contains("disk full")
            || m.contains("out of space") || m.contains("enospc") { return disk }
        if m.contains("not found") || m.contains("404") { return notFound }
        if m.contains("too large") || m.contains("413")
            || m.contains("exceeds") { return tooLarge }

        // Phase-based default.
        switch phase {
        case "download", "downloading": return download
        case "transcribe", "transcribing": return whisper
        case "ocr": return ocr
        case "library": return disk    // library step writes files → disk/IO
        default: return unknown
        }
    }
}
