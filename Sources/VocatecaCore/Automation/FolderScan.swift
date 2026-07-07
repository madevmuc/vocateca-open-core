import Foundation

// MARK: - FolderScan

/// Pure folder-scan helpers — no FSEvents, no I/O side-effects.
///
/// These functions are the OPEN, testable, side-effect-free half of the
/// folder-watching feature. The CLOSED `AutomationRunner` in `VocatecaPro`
/// calls these to decide which files to ingest; tests exercise them directly
/// without needing FSEvents or a running watcher.
public enum FolderScan {

    // MARK: - Media extensions

    /// Extensions ffmpeg handles on the audio-extract path.
    ///
    /// Ported byte-for-byte from `core/local_source.py :: _MEDIA_EXTS`.
    /// The set is used to gate folder events cheaply, without ffprobe, so
    /// non-media files dropped into the watch folder are silently skipped.
    public static let mediaExtensions: Set<String> = [
        ".mp3",
        ".m4a",
        ".m4b",
        ".wav",
        ".aiff",
        ".aif",
        ".flac",
        ".ogg",
        ".oga",
        ".opus",
        ".mp4",
        ".m4v",
        ".mov",
        ".mkv",
        ".webm",
        ".avi",
        ".wmv",
    ]

    // MARK: - isIngestable

    /// Returns `true` when the file at `url` has a media extension that the
    /// pipeline can process.
    ///
    /// Extension comparison is case-insensitive and lowercase-normalised,
    /// matching Python's `p.suffix.lower() not in _MEDIA_EXTS` check.
    ///
    /// - Parameters:
    ///   - url: The file URL to check.
    ///   - mediaExtensions: The set of allowed lowercase extensions (default:
    ///     ``FolderScan/mediaExtensions``). Override in tests to use a custom set.
    /// - Returns: `true` if the extension is in `mediaExtensions`.
    public static func isIngestable(
        _ url: URL,
        mediaExtensions: Set<String> = FolderScan.mediaExtensions
    ) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return mediaExtensions.contains("." + ext)
    }

    // MARK: - newMediaFiles

    /// Returns the media files found under `dir` that are not already in `knownPaths`.
    ///
    /// Performs a recursive directory scan using `FileManager`. Each discovered
    /// file is checked with `isIngestable`; files whose absolute path string is
    /// in `knownPaths` are skipped (dedup gate).
    ///
    /// This function is PURE from a concurrency perspective: it does not modify
    /// any shared state. It performs synchronous file I/O (directory scan) so
    /// call it off the main actor if the directory is large.
    ///
    /// - Parameters:
    ///   - dir: The directory to scan.
    ///   - knownPaths: Absolute path strings for files already registered.
    /// - Returns: URLs of new media files not yet in `knownPaths`.
    public static func newMediaFiles(in dir: URL, knownPaths: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            guard isIngestable(fileURL) else { continue }
            // Resolve symlinks so the path matches what callers build from the same URL.
            let resolvedPath = fileURL.resolvingSymlinksInPath().path
            let standardPath = fileURL.standardizedFileURL.path
            // Check both raw and resolved paths — macOS /tmp is a symlink to /private/tmp.
            guard !knownPaths.contains(resolvedPath),
                  !knownPaths.contains(standardPath),
                  !knownPaths.contains(fileURL.path) else {
                continue
            }
            results.append(fileURL)
        }
        return results
    }

    // MARK: - Size-stability check (L5 — avoid ingesting half-copied files)

    /// A file's size + modification-time at a point in time, used to detect
    /// whether a file dropped into the watch folder is still being written
    /// (e.g. Finder copy, a browser download, or a slow network-drive write).
    public struct FileStabilitySnapshot: Sendable, Equatable {
        public let size: Int64
        public let modificationDate: Date?

        public init(size: Int64, modificationDate: Date?) {
            self.size = size
            self.modificationDate = modificationDate
        }

        /// Snapshots the CURRENT size + mtime of the file at `url`.
        /// `nil` when the file cannot be stat'd (e.g. it vanished, or a
        /// permission error) — callers treat a `nil` snapshot as "not stable".
        public static func current(of url: URL) -> FileStabilitySnapshot? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return nil }
            let mtime = attrs[.modificationDate] as? Date
            return FileStabilitySnapshot(size: size, modificationDate: mtime)
        }
    }

    /// Pure comparison: is `current` the SAME as `previous` (same byte size AND
    /// same modification time)? A file still being written grows and/or its
    /// mtime keeps advancing between two samples taken a short interval apart;
    /// only a file that stopped changing across BOTH dimensions is considered
    /// settled enough to ingest.
    ///
    /// `nil` for either snapshot (the file could not be stat'd, e.g. it
    /// vanished mid-copy) is never stable.
    ///
    /// - Parameters:
    ///   - current: The most recent snapshot.
    ///   - previous: An earlier snapshot of the SAME file, taken some interval before.
    /// - Returns: `true` when the file appears fully written (size and mtime unchanged).
    public static func isStable(current: FileStabilitySnapshot?, previous: FileStabilitySnapshot?) -> Bool {
        guard let current, let previous else { return false }
        return current.size == previous.size && current.modificationDate == previous.modificationDate
    }
}
