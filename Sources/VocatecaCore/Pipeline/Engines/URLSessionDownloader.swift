import Foundation

// MARK: - URLSessionDownloader

/// A real `EpisodeDownloader` that fetches podcast audio over HTTP/HTTPS using
/// `URLSession`, streaming directly to disk — never buffering the whole file in RAM.
///
/// ## Retry classification (mirrors Python `_should_retry`)
/// - **Transient** → `PipelineError.transient`: 429 / 5xx HTTP statuses,
///   `URLError` network failures, timeouts.
/// - **Permanent** → `PipelineError.permanent`: 4xx HTTP statuses (404, 403,
///   410…), non-HTTP scheme errors, URL safety violations.
///
/// ## YouTube / generic URL episodes
/// If `episode.mp3Url` looks like a YouTube watch URL, or any URL without a
/// recognised direct-media extension, the downloader delegates to
/// `youtubeAudioHook`. By default the hook throws
/// `.permanent("YouTube audio download not configured")` — callers that want
/// YouTube / yt-dlp support must inject a real hook.
///
/// ## Resume support
/// On each attempt the downloader checks for an existing `<slug>.mp3.part` file.
/// If one is present, it sends a `Range: bytes=<partSize>-` header and calls
/// ``resumeDecision(partSize:statusCode:serverValidator:storedValidator:expectedLength:)``
/// to decide whether to append, restart, or finalize. A `<slug>.mp3.part.meta`
/// JSON sidecar stores the URL + HTTP validators so the decision survives across
/// app launches.
///
/// On a thrown error the `.part` and `.meta` files are left on disk so the next
/// attempt can resume. On permanent failure they are deleted.
///
/// ## Size cap
/// `URLSafety.maxMP3Bytes` (2 GB) is enforced during streaming — each chunk
/// increments a running total and the download is aborted (+ `.part` deleted)
/// if the cap is exceeded. An early abort is also applied via `Content-Length`.
public struct URLSessionDownloader: EpisodeDownloader {

    // MARK: - Configuration

    /// Directory under which audio files are written.
    /// Defaults to `<userDataDir>/media`.
    public let mediaDir: URL

    /// URLSession used for HTTP downloads. Injected so tests can supply a
    /// session backed by a `MockURLProtocol`.
    public let session: URLSession

    /// Called when the episode's mp3Url looks like a YouTube watch URL or any
    /// non-direct-media URL. Throw `PipelineError.permanent` by default; replace
    /// for real YouTube / yt-dlp support.
    public let youtubeAudioHook: @Sendable (Episode, URL) async throws -> URL

    // MARK: - Init

    public init(
        mediaDir: URL = Paths.userDataDir().appendingPathComponent("media", isDirectory: true),
        // Default to a redirect-validating session so a 302 from an attacker's
        // feed-enclosure host can't bounce the download to an internal/loopback
        // host (SSRF). Tests inject their own MockURLProtocol session.
        session: URLSession = URLSafety.redirectValidatingSession(),
        youtubeAudioHook: @escaping @Sendable (Episode, URL) async throws -> URL = { _, _ in
            throw PipelineError.permanent("YouTube audio download not configured — inject youtubeAudioHook")
        }
    ) {
        self.mediaDir = mediaDir
        self.session = session
        self.youtubeAudioHook = youtubeAudioHook
    }

    // MARK: - EpisodeDownloader

    public func download(_ episode: Episode) async throws -> URL {
        return try await download(episode, progress: { _ in })
    }

    /// Progress-aware download that emits byte-fraction signals periodically.
    ///
    /// Calls `progress` with a 0.0–1.0 fraction derived from bytes received vs
    /// the total (from `Content-Length` or `Content-Range`). When the server
    /// doesn't send content length, progress is emitted every 512 KB at a
    /// monotonically increasing unbounded estimate (capped at 0.99 so 1.0 is
    /// only emitted by the Pipeline after the call returns).
    public func download(_ episode: Episode, progress: ProgressReporter) async throws -> URL {
        let rawURL = episode.mp3Url
        let downloadStart = Date()
        Log.info("Download started", component: "Network",
                 context: [("guid", episode.guid), ("url", rawURL)])

        // Safety check — throws URLSafetyError which we map to permanent.
        do {
            try URLSafety.safeURL(rawURL)
        } catch {
            Log.error("Download rejected — unsafe URL", component: "Network",
                      context: [("guid", episode.guid), ("error", "\(error)")])
            throw PipelineError.permanent("URL safety check failed: \(error)")
        }

        guard let url = URL(string: rawURL) else {
            throw PipelineError.permanent("Malformed URL: \(rawURL)")
        }

        // Non-direct-media delegation — no real byte-level progress available.
        // YouTube URLs and any URL without a recognised audio/video extension
        // are routed to the yt-dlp audio hook.
        if Self.isYouTubeURL(url) || !Self.isDirectMediaURL(url) {
            Log.debug("Download via yt-dlp hook", component: "Network",
                      context: [("guid", episode.guid), ("url", url.absoluteString)])
            return try await youtubeAudioHook(episode, url)
        }

        // Build destination path: <mediaDir>/<showSlug>/<slug>.mp3
        // Slugify the show segment so a poisoned show_slug can't traverse the path.
        let slug = Self.makeSlug(episode)
        let showDir = mediaDir.appendingPathComponent(
            TextNormalization.slugify(episode.showSlug), isDirectory: true
        )
        let destURL  = showDir.appendingPathComponent("\(slug).mp3")
        let partURL  = showDir.appendingPathComponent("\(slug).mp3.part")
        let metaURL  = showDir.appendingPathComponent("\(slug).mp3.part.meta")

        // Create directories.
        do {
            try FileManager.default.createDirectory(at: showDir, withIntermediateDirectories: true)
        } catch {
            throw PipelineError.transient("Failed to create media directory: \(error)")
        }

        // Perform the resumable streaming download.
        do {
            try await streamingResumeDownload(
                from: url,
                partURL: partURL,
                metaURL: metaURL,
                progress: progress
            )
            // Atomic rename .part → .mp3 on success.
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: partURL, to: destURL)
            // Clean up meta sidecar.
            try? FileManager.default.removeItem(at: metaURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destURL.path))?[.size] as? Int64
            let ms = Int(Date().timeIntervalSince(downloadStart) * 1000)
            Log.info("Download complete", component: "Network",
                     context: [("guid", episode.guid), ("bytes", "\(bytes ?? 0)"), ("ms", "\(ms)")])
            return destURL
        } catch let pe as PipelineError {
            Log.error("Download failed", component: "Network",
                      context: [("guid", episode.guid), ("error", "\(pe)")])
            // On permanent failure, delete .part and .meta so we don't try
            // to resume something that will never succeed.
            if case .permanent = pe {
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: metaURL)
            }
            // On transient AND disk-full failure, leave .part + .meta so the next
            // attempt (after space is freed) resumes from where it stopped.
            throw pe
        } catch {
            let classified = Self.classifyError(error)
            Log.error("Download failed", component: "Network",
                      context: [("guid", episode.guid), ("error", "\(classified)")])
            if case .permanent = classified {
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: metaURL)
            }
            throw classified
        }
    }

    // MARK: - Resumable streaming download

    /// Streams the download from `url` to `partURL`, resuming if a `.part` file
    /// already exists. Writes a `.meta` sidecar on first write (or after restart).
    ///
    /// Throws `PipelineError` on error; leaves `.part` + `.meta` in place on
    /// transient failure so the next attempt can resume.
    private func streamingResumeDownload(
        from url: URL,
        partURL: URL,
        metaURL: URL,
        progress: ProgressReporter,
        maxBytes: Int = URLSafety.maxMP3Bytes
    ) async throws {
        let fm = FileManager.default

        // Stat the existing .part file.
        let partSize: Int64
        if let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let size = attrs[.size] as? Int64 {
            partSize = size
        } else {
            partSize = 0
        }

        // Load stored validator from the .meta sidecar (nil on first attempt).
        let storedMeta: DownloadMeta? = {
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            return try? JSONDecoder().decode(DownloadMeta.self, from: data)
        }()

        // Build request, adding Range header if we have an existing partial file.
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        if partSize > 0 {
            request.setValue("bytes=\(partSize)-", forHTTPHeaderField: "Range")
        }

        let (asyncBytes, response) = try await session.bytes(for: request)

        // Validate HTTP status and extract headers.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PipelineError.permanent("Non-HTTP response")
        }

        let statusCode = httpResponse.statusCode
        Log.debug("HTTP response", component: "Network",
                  context: [("status", "\(statusCode)"), ("url", url.absoluteString)])
        if statusCode >= 400 {
            if Self.isRetriableStatus(statusCode) {
                throw PipelineError.transient("HTTP \(statusCode)")
            } else {
                throw PipelineError.permanent("HTTP \(statusCode)")
            }
        }

        // Extract server validators from response headers.
        let serverETag = httpResponse.value(forHTTPHeaderField: "ETag")
        let serverLM   = httpResponse.value(forHTTPHeaderField: "Last-Modified")
        let serverValidator: Validator? = (serverETag != nil || serverLM != nil)
            ? Validator(etag: serverETag, lastModified: serverLM)
            : nil

        // Determine total expected length from Content-Range (206) or Content-Length (200).
        var expectedLength: Int64? = nil
        if statusCode == 206,
           let cr = httpResponse.value(forHTTPHeaderField: "Content-Range") {
            // "bytes 512000-999999/1000000" → total = 1000000
            expectedLength = Self.parseTotalFromContentRange(cr)
        }
        if expectedLength == nil,
           let cl = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let clInt = Int64(cl) {
            // For a 200 response, Content-Length is the full size.
            // Reject early if it exceeds the cap.
            if statusCode == 200 && Int(clInt) > maxBytes {
                throw PipelineError.permanent(
                    "Content-Length \(clInt) exceeds max \(maxBytes) bytes"
                )
            }
            expectedLength = clInt
        }

        // Make the resume decision.
        let action = resumeDecision(
            partSize: partSize,
            statusCode: statusCode,
            serverValidator: serverValidator,
            storedValidator: storedMeta?.validator,
            expectedLength: expectedLength
        )

        switch action {
        case .finalizeAlreadyComplete:
            // The .part already has the full content — drain bytes then return.
            for try await _ in asyncBytes {}
            return

        case .restart:
            // Truncate the .part file and delete the stale .meta.
            try? fm.removeItem(at: metaURL)
            if fm.fileExists(atPath: partURL.path) {
                try fm.removeItem(at: partURL)
            }

        case .appendFrom:
            break
        }

        // Determine byte offset from which we append (0 for restart).
        let appendOffset: Int64
        switch action {
        case .appendFrom(let off): appendOffset = off
        case .restart:             appendOffset = 0
        case .finalizeAlreadyComplete: return  // unreachable (handled above)
        }

        // Open or create the .part FileHandle.
        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        guard let fileHandle = try? FileHandle(forWritingTo: partURL) else {
            throw PipelineError.transient("Cannot open .part file for writing: \(partURL.path)")
        }
        defer { try? fileHandle.close() }

        // Seek to the correct position (truncate to zero on restart).
        if appendOffset > 0 {
            try fileHandle.seek(toOffset: UInt64(appendOffset))
        } else {
            try fileHandle.truncate(atOffset: 0)
        }

        // Write the .meta sidecar (or overwrite after restart).
        let metaToWrite = DownloadMeta(
            url: url.absoluteString,
            validator: serverValidator ?? Validator(etag: nil, lastModified: nil),
            expectedLength: expectedLength
        )
        if let metaData = try? JSONEncoder().encode(metaToWrite) {
            try? metaData.write(to: metaURL, options: .atomic)
        }

        // Stream bytes to disk, enforcing the size cap.
        //
        // H5: `session.bytes(for:)` yields ONE byte at a time; writing each byte
        // with its own `write(contentsOf:)` was a syscall PER BYTE, so a 50 MB
        // episode issued ~50 million `write(2)` calls — a CPU-bound, multi-minute
        // download. Buffer into a 64 KB `Data` and flush whole chunks, cutting the
        // syscall count ~65 000×. All the surrounding robustness is unchanged: the
        // 2 GB cap (checked on the running total, now per chunk), the resume
        // append-offset, the progress cadence, and the `.part`→`.mp3` atomic
        // rename in the caller.
        var runningTotal: Int64 = appendOffset
        let totalForProgress: Int64? = expectedLength
        let progressChunkBytes: Int64 = 512 * 1024
        var lastProgressMark: Int64 = appendOffset

        let writeBufferCap = 64 * 1024
        var writeBuffer = Data()
        writeBuffer.reserveCapacity(writeBufferCap)

        // Flush the accumulated buffer to disk, mapping a disk-full write failure
        // to `.diskFull` (M12) — its own category so the pipeline pauses the queue
        // rather than permanently failing this episode. Any other write failure is
        // transient (leave `.part`/`.meta` for resume).
        func flush() throws {
            guard !writeBuffer.isEmpty else { return }
            do {
                try fileHandle.write(contentsOf: writeBuffer)
            } catch {
                throw Self.classifyWriteError(error)
            }
            writeBuffer.removeAll(keepingCapacity: true)
        }

        for try await byte in asyncBytes {
            writeBuffer.append(byte)
            runningTotal += 1
            if runningTotal > Int64(maxBytes) {
                // Cap exceeded: delete .part + .meta and fail permanently.
                try? fileHandle.close()
                try? fm.removeItem(at: partURL)
                try? fm.removeItem(at: metaURL)
                throw PipelineError.permanent(
                    "Download exceeded \(maxBytes) bytes without EOF"
                )
            }
            // Flush the buffer once it reaches the 64 KB cap.
            if writeBuffer.count >= writeBufferCap {
                try flush()
            }
            // Report progress at ~512 KB intervals.
            if runningTotal - lastProgressMark >= progressChunkBytes {
                lastProgressMark = runningTotal
                let fraction: Double
                if let total = totalForProgress, total > 0 {
                    fraction = min(0.99, Double(runningTotal) / Double(total))
                } else {
                    let megaBytes = Double(runningTotal) / (1024 * 1024)
                    fraction = min(0.99, 1.0 - 1.0 / (1.0 + megaBytes / 50.0))
                }
                progress(fraction)
            }
        }

        // Flush the final partial chunk (bytes since the last 64 KB flush).
        try flush()
    }

    // MARK: - Pure helpers (testable)

    /// Parse the total resource size from a `Content-Range` response header.
    ///
    /// Handles both `bytes <start>-<end>/<total>` (206) and `bytes */<total>` (416).
    /// Returns `nil` if parsing fails.
    static func parseTotalFromContentRange(_ header: String) -> Int64? {
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let totalStr = String(header[header.index(after: slash)...])
            .trimmingCharacters(in: .whitespaces)
        return Int64(totalStr)
    }

    /// True for HTTP 429, 500, 502, 503, 504 — mirrors Python's `RETRIABLE_STATUSES`.
    static func isRetriableStatus(_ code: Int) -> Bool {
        code == 429 || (code >= 500 && [500, 502, 503, 504].contains(code))
    }

    /// True if the URL host looks like a YouTube domain.
    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com" || host == "www.youtube.com"
            || host == "youtu.be" || host == "m.youtube.com"
    }

    /// True when the URL path ends with a recognised audio or video extension,
    /// indicating the URL is a direct media download (not a webpage that yt-dlp
    /// needs to parse). Non-direct URLs are routed to the yt-dlp audio hook.
    static func isDirectMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return FolderScan.mediaExtensions.contains("." + ext)
    }

    /// Classify a **file-write** failure during streaming.
    ///
    /// M12: a disk-full write (`ENOSPC` / Cocoa `NSFileWriteOutOfSpaceError`) is
    /// NOT a per-episode fault — the episode is fine, the machine is out of space.
    /// Map it to `.diskFull` so the pipeline requeues the episode (no burned
    /// attempt) and pauses the whole queue with a banner, instead of the old
    /// behaviour where a write error fell through to `.permanent` → a permanently
    /// `failed` episode. Every other write error is `.transient` (leave the
    /// `.part`/`.meta` for the next attempt to resume).
    static func classifyWriteError(_ error: Error) -> PipelineError {
        if Self.isOutOfSpace(error) {
            return .diskFull("disk full while writing download: \(error.localizedDescription)")
        }
        return .transient("write failed: \(error.localizedDescription)")
    }

    /// True when `error` represents an out-of-space condition, whether it arrives
    /// as a POSIX `ENOSPC` or a Cocoa `NSFileWriteOutOfSpaceError`. `FileHandle`
    /// surfaces the underlying write failure in either shape depending on OS/path.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) {
            return true
        }
        // Some FileHandle write failures nest the POSIX error under the Cocoa one.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC) {
                return true
            }
            if underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileWriteOutOfSpaceError {
                return true
            }
        }
        return false
    }

    /// Classify a non-HTTP `Error` into a `PipelineError`.
    static func classifyError(_ error: Error) -> PipelineError {
        // Cancellation FIRST — a Stop / hard-pause / worker teardown surfaces as
        // `URLError.cancelled` (URLSession task cancelled) or a Swift
        // `CancellationError` (structured-concurrency cancellation). Neither is a
        // failure: routing it to `.permanent` (the old `default:`) marked the
        // episode permanently `failed` and burned the media, so a user who paused
        // mid-download lost the episode. Classify it as `.cancelled` so the
        // pipeline resets the row to `pending` without bumping attempts.
        if error is CancellationError {
            return .cancelled("download cancelled")
        }
        // M12: an out-of-space error that reaches the generic classifier (e.g. a
        // write failure that surfaced outside the chunk-flush helper) is a disk
        // problem, not a per-episode permanent fault.
        if Self.isOutOfSpace(error) {
            return .diskFull("disk full: \(error.localizedDescription)")
        }
        if let urlErr = error as? URLError {
            if urlErr.code == .cancelled {
                return .cancelled("download cancelled")
            }
            switch urlErr.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed,
                 .requestBodyStreamExhausted:
                return .transient(urlErr.localizedDescription)
            default:
                return .permanent(urlErr.localizedDescription)
            }
        }
        return .permanent(error.localizedDescription)
    }

    /// Build a filesystem-safe slug from the episode guid (strip non-alphanumeric).
    static func makeSlug(_ episode: Episode) -> String {
        makeSlug(guid: episode.guid)
    }

    /// Guid-only overload of ``makeSlug(_:)`` — same normalisation, so the media
    /// retention backfill can reconstruct a downloaded file's expected path from
    /// just `(guid, showSlug)` without a full `Episode`.
    static func makeSlug(guid: String) -> String {
        let raw = guid.lowercased()
        let safe = raw.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-_")).contains($0) }
            .map(Character.init)
        return String(safe.prefix(80))
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
}
