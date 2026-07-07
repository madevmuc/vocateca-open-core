import Foundation

// MARK: - LogLevel

/// Severity level for a log entry.
public enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"
}

// MARK: - LogLine

/// A single, immutable log entry held in the ring buffer.
public struct LogLine: Sendable {
    /// Wall-clock timestamp of the entry.
    public let date: Date
    public let level: LogLevel
    /// Short component/subsystem tag, e.g. "Ingest" or "QueueRunner".
    public let component: String
    public let message: String
    /// Optional key=value context pairs rendered inline.
    public let context: [(String, String)]

    /// Formatted string: `HH:mm:ss.SSS [LEVEL] [Component] message key=value …`
    public var formatted: String {
        let ts = LogLine.timeFormatter().string(from: date)
        let ctx = context.isEmpty ? "" : " " + context.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        return "\(ts) [\(level.rawValue)] [\(component)] \(message)\(ctx)"
    }

    // DateFormatter is not Sendable but is only used from a nonisolated
    // context in formatted; create a local one per call is the safe path.
    // We cache one per thread via a local static to avoid re-alloc hot-path.
    private static let _timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Shared time formatter, exposed internally so `LogRedaction` can render
    /// the same timestamp format without duplicating the DateFormatter setup.
    static func timeFormatter() -> DateFormatter { _timeFormatter }
}

// MARK: - LogRedaction

/// Pure, unit-testable redaction for log lines shown/exported via copy.
///
/// The in-app Logs viewer always shows the FULL line (`LogLine.formatted`) —
/// the leak vector is the clipboard/export path, so redaction is applied only
/// when building a copy/export payload (see `LogStore.copyPayload(redacted:)`).
public enum LogRedaction {

    /// Context keys (lowercased) whose VALUE is replaced with `<redacted>`.
    /// The key itself is preserved so the shape of the line is still legible,
    /// e.g. `title=<redacted>`.
    public static let sensitiveKeys: Set<String> = [
        "title", "path", "url", "slug", "guid", "token", "secret",
        "email", "handle", "feed", "target", "query", "account",
        "profile", "name"
    ]

    /// Renders `line` like `LogLine.formatted`, but with sensitive context
    /// values masked and URLs/absolute paths scrubbed from the free message.
    public static func redact(_ line: LogLine) -> String {
        let ts = LogLine.timeFormatter().string(from: line.date)
        let ctx = line.context.isEmpty ? "" : " " + line.context.map { key, value in
            let masked = sensitiveKeys.contains(key.lowercased()) ? "<redacted>" : value
            return "\(key)=\(masked)"
        }.joined(separator: " ")
        let message = scrub(line.message)
        return "\(ts) [\(line.level.rawValue)] [\(line.component)] \(message)\(ctx)"
    }

    /// Replaces `https?://…` substrings with `<redacted-url>`, absolute
    /// filesystem paths (`/Users/…`, `~/…`, `file://…`) with `<redacted-path>`,
    /// and email addresses with `[email]`. A simple scan/regex — this
    /// intentionally does not attempt to catch every possible path/email
    /// shape, only the common ones that show up in logs.
    public static func scrub(_ text: String) -> String {
        var result = text

        // URLs (http/https). Stop at whitespace or common trailing punctuation.
        result = result.replacingOccurrences(
            of: #"https?://[^\s"'<>]+"#,
            with: "<redacted-url>",
            options: .regularExpression
        )

        // file:// URLs.
        result = result.replacingOccurrences(
            of: #"file://[^\s"'<>]+"#,
            with: "<redacted-path>",
            options: .regularExpression
        )

        // Absolute /Users/... paths.
        result = result.replacingOccurrences(
            of: #"/Users/[^\s"'<>]+"#,
            with: "<redacted-path>",
            options: .regularExpression
        )

        // ~-rooted paths (e.g. ~/Music/ep.mp3).
        result = result.replacingOccurrences(
            of: #"~/[^\s"'<>]+"#,
            with: "<redacted-path>",
            options: .regularExpression
        )

        // L-2: email addresses embedded in free-text messages (e.g. a stray
        // "Signed in as x@y.com" that bypassed the context-tuple convention).
        // Context-tuple email VALUES are already masked by `redact(_:)`'s
        // `sensitiveKeys` check above this call; this catches the message text.
        result = result.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[email]",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }

    /// Scrubs a header/system-info snapshot string. Same rules as message
    /// scrubbing, plus a fallback that masks the username segment of any
    /// remaining `/Users/<name>` occurrence (belt-and-suspenders in case a
    /// path slipped through without matching the broader path scrub above).
    public static func scrubSnapshot(_ text: String) -> String {
        var result = scrub(text)
        result = result.replacingOccurrences(
            of: #"/Users/[^/\s"'<>]+"#,
            with: "/Users/<redacted>",
            options: .regularExpression
        )
        return result
    }
}

// MARK: - LogRelevance

/// Pure, unit-testable "which log lines are relevant to this notification?"
/// heuristic, used by the Notifications detail panel's focused log excerpt
/// (no live-network / no side effects — just filters an already-fetched
/// `[LogLine]` snapshot).
public enum LogRelevance {

    /// Filters `lines` down to the ones most relevant to a notification that
    /// fired at `createdAt` (epoch seconds), optionally about `showSlug`.
    ///
    /// A line is relevant when:
    /// - its timestamp falls within `window` seconds of `createdAt` (either
    ///   side), OR
    /// - `showSlug` is non-nil/non-empty and the line's `message` or any
    ///   context value contains it (case-insensitive), OR
    /// - it's a WARN/ERROR line that falls within `window` seconds of
    ///   `createdAt` (already covered by the first rule, kept as a distinct
    ///   case for callers who widen the window for lower-severity lines only —
    ///   see `window` parameter).
    ///
    /// - Parameters:
    ///   - lines: A `LogStore.snapshot()` result (oldest-first).
    ///   - createdAt: The notification's `createdAt` (epoch seconds).
    ///   - showSlug: The notification's `showSlug`, if any.
    ///   - window: Half-width of the time window, in seconds. Defaults to 60
    ///     (±60 s around `createdAt`).
    /// - Returns: Matching lines, **newest-first**.
    public static func relevantLines(
        in lines: [LogLine],
        createdAt: Double,
        showSlug: String?,
        window: TimeInterval = 60
    ) -> [LogLine] {
        let center = Date(timeIntervalSince1970: createdAt)
        let slugLower = showSlug?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSlug = !(slugLower?.isEmpty ?? true)

        let filtered = lines.filter { line in
            let withinWindow = abs(line.date.timeIntervalSince(center)) <= window
            if withinWindow { return true }
            guard hasSlug, let slug = slugLower else { return false }
            if line.message.lowercased().contains(slug) { return true }
            return line.context.contains { _, value in value.lowercased().contains(slug) }
        }
        // Newest-first.
        return filtered.sorted { $0.date > $1.date }
    }
}

// MARK: - LogStore

/// Thread-safe in-memory ring buffer + on-disk log file for Vocateca diagnostics.
///
/// ## Design
/// - **Ring buffer**: capped at ``maxLines`` entries (default 5 000). When full,
///   the oldest entries are dropped to make room.
/// - **File sink**: each entry is also appended to
///   `~/Library/Caches/Vocateca/logs/vocateca.log`. When the file exceeds
///   ``maxFileSizeBytes`` (default 5 MB) it is rotated to a `.1` generation
///   (L2): the current file is renamed to `vocateca.log.1` (replacing any
///   previous `.1`), a fresh `vocateca.log` is opened, and the triggering entry
///   is written into it — so exactly one previous generation is retained and no
///   entry is dropped on rotation (the old behaviour truncated to zero and lost
///   the triggering line). Rotation is best-effort: a failure falls back to a
///   truncate; it never throws into callers.
/// - **Thread safety**: a plain `NSLock` guards the ring buffer + file handle
///   so that `@unchecked Sendable` is correct — all mutable state is behind the lock.
///
/// ## Singleton
/// Use `LogStore.shared` for all production logging.
/// Tests may create private instances with `LogStore(maxLines:maxFileSizeBytes:logURL:)`.
public final class LogStore: @unchecked Sendable {

    // MARK: - Configuration

    /// Maximum number of lines kept in memory.
    public let maxLines: Int
    /// File rotation threshold in bytes.
    public let maxFileSizeBytes: Int64

    // SHARED SINGLETON
    public static let shared = LogStore()

    // MARK: - Private state (all guarded by `lock`)

    private let lock = NSLock()
    private var buffer: [LogLine] = []
    private var fileHandle: FileHandle?
    private let logURL: URL
    /// Bumped on every append/clear. A cheap way for a live viewer to poll
    /// "did anything change?" without snapshotting the whole buffer each tick.
    private var _generation: Int = 0

    // MARK: - Init

    /// Production init — writes to `~/Library/Caches/Vocateca/logs/vocateca.log`.
    public convenience init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Vocateca/logs", isDirectory: true)
        self.init(
            maxLines: 5_000,
            maxFileSizeBytes: 5 * 1_024 * 1_024,
            logURL: dir.appendingPathComponent("vocateca.log")
        )
    }

    /// Testable init — inject custom limits and a temp URL.
    public init(maxLines: Int, maxFileSizeBytes: Int64, logURL: URL) {
        self.maxLines = maxLines
        self.maxFileSizeBytes = maxFileSizeBytes
        self.logURL = logURL
        _openFile()
    }

    /// Absolute URL of the on-disk log file (e.g. for a clickable file:// link in
    /// a support email so the user can attach the full log).
    public var fileURL: URL { logURL }

    // MARK: - Append

    /// Appends `line` to the ring buffer and the log file (under the lock).
    func append(_ line: LogLine) {
        lock.withLock {
            // Ring buffer: drop oldest when full.
            if buffer.count >= maxLines {
                buffer.removeFirst()
            }
            buffer.append(line)
            _generation &+= 1

            // File sink.
            _writeToFile(line.formatted + "\n")
        }
    }

    /// Monotonic change counter (append + clear). Cheap to read; a live log
    /// viewer polls this and only re-snapshots when it changed.
    public var generation: Int { lock.withLock { _generation } }

    // MARK: - Public read API

    /// Returns a snapshot of all buffered log lines (oldest first).
    public func snapshot() -> [LogLine] {
        lock.withLock { buffer }
    }

    /// Returns all buffered lines joined by newlines (oldest first).
    public func snapshotString() -> String {
        snapshot().map { $0.formatted }.joined(separator: "\n")
    }

    /// Empties the in-memory buffer and truncates the log file.
    public func clear() {
        lock.withLock {
            buffer.removeAll(keepingCapacity: true)
            _generation &+= 1
            _truncateFile()
        }
    }

    // MARK: - Copy payload (for pasting into a bug report / AI session)

    /// Builds a self-contained copy payload:
    /// - System snapshot (prepended when `systemInfo` is provided)
    /// - Environment header (app name, macOS version, line counts)
    /// - All buffered log lines
    ///
    /// The payload is safe to paste directly into a bug report or an AI prompt.
    ///
    /// - Parameters:
    ///   - redacted: When `true`, sensitive context values and URLs/absolute
    ///     paths in messages (and in the `systemInfo` snapshot) are masked —
    ///     see `LogRedaction`. Defaults to `false`, preserving existing
    ///     callers' behavior. The in-app buffer/viewer is never affected by
    ///     this flag; only the returned copy/export string is redacted.
    ///   - appMode: Optional current app mode string ("background" / "power").
    ///   - systemInfo: Optional system snapshot string from `SystemInfo.snapshot()`
    ///     (built in the UI layer so it can include NSScreen data without Core
    ///     importing AppKit). When provided it is prepended before the log header
    ///     so a pasted log is fully self-contained.
    public func copyPayload(redacted: Bool = false, appMode: String? = nil, systemInfo: String? = nil) -> String {
        let lines = lock.withLock { buffer }

        var header = """
            === Vocateca Diagnostic Log ===
            App:     Vocateca v2
            macOS:   \(ProcessInfo.processInfo.operatingSystemVersionString)
            Date:    \(ISO8601DateFormatter().string(from: Date()))
            Entries: \(lines.count)
            """
        if let mode = appMode {
            header += "\nMode:    \(mode)"
        }

        // Quick status counts by level.
        var counts: [String: Int] = [:]
        for l in lines { counts[l.level.rawValue, default: 0] += 1 }
        let levelSummary = ["DEBUG", "INFO", "WARN", "ERROR"]
            .compactMap { lv -> String? in
                guard let c = counts[lv] else { return nil }
                return "\(lv)=\(c)"
            }
            .joined(separator: " ")
        if !levelSummary.isEmpty {
            header += "\nLevels:  \(levelSummary)"
        }

        header += "\n================================\n"

        let body = redacted
            ? lines.map { LogRedaction.redact($0) }.joined(separator: "\n")
            : lines.map { $0.formatted }.joined(separator: "\n")

        // Prepend the system snapshot so a pasted log is fully self-contained.
        if let snap = systemInfo, !snap.isEmpty {
            let snapshotText = redacted ? LogRedaction.scrubSnapshot(snap) : snap
            return "=== System Snapshot ===\n\(snapshotText)\n========================\n\n" + header + body
        }
        return header + body
    }

    // MARK: - Private file helpers (must be called under lock)

    private func _openFile() {
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
    }

    private func _writeToFile(_ text: String) {
        guard let fh = fileHandle, let data = text.data(using: .utf8) else { return }

        // L2: rotate to a `.1` generation when the file is too large, then write
        // the triggering entry into the FRESH file (no longer dropped). `_rotateFile`
        // rebinds `fileHandle` to the new file, so re-read it for the write below.
        let size = fh.offsetInFile
        if Int64(size) > maxFileSizeBytes {
            _rotateFile()
        }

        (fileHandle ?? fh).write(data)
    }

    /// L2: rotate `vocateca.log` → `vocateca.log.1` (keeping exactly one previous
    /// generation), then open a fresh empty `vocateca.log`. Best-effort — on any
    /// filesystem failure, falls back to the old truncate-in-place so the file
    /// never grows unbounded even if the rename can't happen.
    private func _rotateFile() {
        let fm = FileManager.default
        let rotatedURL = logURL.appendingPathExtension("1")

        // Close the current handle so the rename can proceed cleanly.
        try? fileHandle?.close()
        fileHandle = nil

        do {
            // Replace any existing previous generation, then move current → .1.
            if fm.fileExists(atPath: rotatedURL.path) {
                try fm.removeItem(at: rotatedURL)
            }
            if fm.fileExists(atPath: logURL.path) {
                try fm.moveItem(at: logURL, to: rotatedURL)
            }
            // Open a fresh, empty current log.
            fm.createFile(atPath: logURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: logURL)
            fileHandle?.seekToEndOfFile()
        } catch {
            // Rename failed (e.g. permissions) — fall back to a truncate-in-place so
            // the file still can't grow unbounded. Make sure a current file exists
            // and is open, then truncate it to zero.
            FileHandle.standardError.write(
                Data("LogStore: rotation to .1 failed, truncating (\(error))\n".utf8))
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            if fileHandle == nil {
                fileHandle = try? FileHandle(forWritingTo: logURL)
            }
            _truncateFile()
        }
    }

    private func _truncateFile() {
        // Truncate the file by closing + re-opening at offset 0.
        fileHandle?.truncateFile(atOffset: 0)
        fileHandle?.seek(toFileOffset: 0)
    }
}

// MARK: - Log (public facade)

/// Lightweight logging facade — all methods are thread-safe and route through `LogStore.shared`.
///
/// Usage:
/// ```swift
/// Log.info("Poll started", component: "Ingest", context: [("show", show.slug)])
/// Log.error("Download failed", component: "Pipeline", context: [("error", "\(err)")])
/// ```
public enum Log {

    // MARK: - Level convenience methods

    public static func debug(
        _ message: String,
        component: String,
        context: [(String, String)] = [],
        store: LogStore = .shared
    ) {
        _emit(level: .debug, message: message, component: component, context: context, store: store)
    }

    public static func info(
        _ message: String,
        component: String,
        context: [(String, String)] = [],
        store: LogStore = .shared
    ) {
        _emit(level: .info, message: message, component: component, context: context, store: store)
    }

    public static func warn(
        _ message: String,
        component: String,
        context: [(String, String)] = [],
        store: LogStore = .shared
    ) {
        _emit(level: .warn, message: message, component: component, context: context, store: store)
    }

    public static func error(
        _ message: String,
        component: String,
        context: [(String, String)] = [],
        store: LogStore = .shared
    ) {
        _emit(level: .error, message: message, component: component, context: context, store: store)
    }

    // MARK: - Internal

    private static func _emit(
        level: LogLevel,
        message: String,
        component: String,
        context: [(String, String)],
        store: LogStore
    ) {
        let line = LogLine(
            date: Date(),
            level: level,
            component: component,
            message: message,
            context: context
        )
        store.append(line)
    }
}
