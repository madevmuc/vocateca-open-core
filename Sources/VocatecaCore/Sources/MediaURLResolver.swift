import Foundation

// MARK: - ResolvedEntry

/// A single entry from a yt-dlp flat-playlist dump.
public struct ResolvedEntry: Sendable, Equatable {
    public let id:    String
    public let title: String
    public let url:   String

    public init(id: String, title: String, url: String) {
        self.id    = id
        self.title = title
        self.url   = url
    }
}

// MARK: - ResolvedMedia

/// The parsed result of `yt-dlp --dump-single-json <url>`.
public struct ResolvedMedia: Sendable, Equatable {
    /// Video/page title from yt-dlp metadata.
    public let title:      String
    /// Uploader/channel name from yt-dlp metadata (used as pseudo-show title).
    public let uploader:   String
    /// The canonical webpage URL for this item.
    public let webpageURL: String
    /// `true` when the URL resolved to a playlist or channel (multiple entries).
    public let isPlaylist: Bool
    /// Individual entries when `isPlaylist == true`; empty for single items.
    public let entries:    [ResolvedEntry]
    /// Best thumbnail URL from yt-dlp metadata, or "" when none. Used as the
    /// pseudo-show artwork for one-off imports.
    public let thumbnail:  String

    public init(
        title:      String,
        uploader:   String,
        webpageURL: String,
        isPlaylist: Bool,
        entries:    [ResolvedEntry] = [],
        thumbnail:  String = ""
    ) {
        self.title      = title
        self.uploader   = uploader
        self.webpageURL = webpageURL
        self.isPlaylist = isPlaylist
        self.entries    = entries
        self.thumbnail  = thumbnail
    }
}

// MARK: - MediaURLResolverError

public enum MediaURLResolverError: Error, Sendable {
    /// yt-dlp binary is not installed.
    case ytDlpNotInstalled
    /// yt-dlp exited with a non-zero code; `stderr` carries the reason.
    case ytDlpFailed(exitCode: Int32, stderr: String)
    /// yt-dlp output was not valid JSON.
    case invalidJSON(String)
}

// MARK: - MediaURLResolver

/// Resolves a generic URL (SoundCloud, Vimeo, etc.) via `yt-dlp --dump-single-json`
/// and returns structured metadata without downloading the media.
///
/// ## Design
/// - Runs `yt-dlp --dump-single-json --no-warnings --no-playlist <url>` via the
///   hardened ``Subprocess`` helper (concurrent drain + timeout).
/// - JSON parsing is pure and testable from fixture strings — no subprocess needed
///   in tests that supply JSON directly.
/// - All subprocess calls go through the injected `BinaryManager` so tests can
///   supply a fake binary path or bypass the call entirely by injecting a fake
///   result closure.
///
/// ## Network gating
/// Live calls require `VOCATECA_RUN_NETWORK_TESTS=1` in test environments.
public struct MediaURLResolver: Sendable {

    private let binaryManager: BinaryManager
    private let subprocess:    Subprocess

    // MARK: - Init

    public init(
        binaryManager: BinaryManager = BinaryManager(),
        subprocess:    Subprocess    = Subprocess()
    ) {
        self.binaryManager = binaryManager
        self.subprocess    = subprocess
    }

    // MARK: - Resolve

    /// Runs `yt-dlp --dump-single-json --no-warnings <url>` and returns
    /// structured metadata.
    ///
    /// - Parameter url: Any URL that yt-dlp recognises (SoundCloud, Vimeo, etc.).
    /// - Throws: ``MediaURLResolverError`` on missing binary, subprocess failure,
    ///   or JSON parse errors.
    public func resolve(_ url: String) async throws -> ResolvedMedia {
        guard let ytDlpPath = binaryManager.resolvedPath(for: .ytDlp) else {
            throw MediaURLResolverError.ytDlpNotInstalled
        }

        // Reject non-http(s) schemes and bare "-…" tokens that could be
        // misread as yt-dlp flags (argument-injection guard).
        let safeURL = try URLSafety.safeURL(url)

        // --no-playlist: resolve single item even when a playlist URL is pasted;
        // use a separate `enumerate` path for playlist metadata.
        // "--" terminates option parsing so the URL can never be interpreted
        // as a flag by yt-dlp.
        let args = YtDlp.hardenedBaseArgs + [
            "--dump-single-json",
            "--no-warnings",
            "--no-playlist",
            "--", safeURL,
        ]

        Log.debug("MediaURLResolver: resolving URL",
                  component: "MediaURLResolver",
                  context: [("url", url)])

        let result = try await subprocess.run(ytDlpPath, args, timeout: 60)
        guard result.exitCode == 0 else {
            throw MediaURLResolverError.ytDlpFailed(
                exitCode: result.exitCode,
                stderr:   result.stderr
            )
        }

        return try Self.parse(json: result.stdout)
    }

    // MARK: - Parse (pure — unit-testable from fixtures)

    /// Parses the JSON output of `yt-dlp --dump-single-json` into a ``ResolvedMedia``.
    ///
    /// `public static` so tests can call it directly with a fixture string
    /// without needing a running yt-dlp binary.
    public static func parse(json: String) throws -> ResolvedMedia {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MediaURLResolverError.invalidJSON(String(json.prefix(200)))
        }

        let title      = (obj["title"]       as? String) ?? ""
        let uploader   = (obj["uploader"]    as? String)
                      ?? (obj["channel"]     as? String)
                      ?? (obj["creator"]     as? String)
                      ?? ""
        let webpageURL = (obj["webpage_url"] as? String)
                      ?? (obj["url"]         as? String)
                      ?? ""

        // Thumbnail: prefer the top-level "thumbnail"; else the last (largest)
        // entry of the "thumbnails" array.
        let thumbnail  = (obj["thumbnail"] as? String)
                      ?? ((obj["thumbnails"] as? [[String: Any]])?.last?["url"] as? String)
                      ?? ""

        // yt-dlp signals a playlist/channel result with a "_type" of "playlist".
        let type       = (obj["_type"] as? String) ?? "video"
        let isPlaylist = type == "playlist"

        // Parse entries when present (flat-playlist output or channel dump).
        var entries: [ResolvedEntry] = []
        if let rawEntries = obj["entries"] as? [[String: Any]] {
            for entry in rawEntries {
                let id    = (entry["id"]    as? String) ?? ""
                let t     = (entry["title"] as? String) ?? id
                let eURL  = (entry["url"]   as? String)
                         ?? (entry["webpage_url"] as? String)
                         ?? ""
                guard !id.isEmpty else { continue }
                entries.append(ResolvedEntry(id: id, title: t, url: eURL))
            }
        }

        return ResolvedMedia(
            title:      title,
            uploader:   uploader,
            webpageURL: webpageURL,
            isPlaylist: isPlaylist,
            entries:    entries,
            thumbnail:  thumbnail
        )
    }

    // MARK: - Enumerate (flat-playlist — for FeedIngestor.ytdlp)

    /// Runs `yt-dlp --flat-playlist --dump-json <url>` and returns a list of
    /// ``ResolvedEntry`` objects, one per video/track, up to `limit`.
    ///
    /// Each line of output is a separate JSON object (NDJSON format). This is
    /// used by `FeedIngestor`'s `ytdlp` branch to enumerate a playlist/channel
    /// without downloading media.
    ///
    /// - Parameters:
    ///   - url:   Playlist or channel URL.
    ///   - limit: Maximum entries to return (0 = unlimited).
    /// - Returns: Array of ``ResolvedEntry`` values.
    public func enumerate(url: String, limit: Int = 50) async throws -> [ResolvedEntry] {
        guard let ytDlpPath = binaryManager.resolvedPath(for: .ytDlp) else {
            throw MediaURLResolverError.ytDlpNotInstalled
        }

        // Reject non-http(s) schemes and bare "-…" tokens (argument-injection guard).
        let safeURL = try URLSafety.safeURL(url)

        var args = YtDlp.hardenedBaseArgs + ["--flat-playlist", "--dump-json", "--no-warnings"]
        if limit > 0 {
            args += ["--playlist-end", "\(limit)"]
        }
        args.append("--")
        args.append(safeURL)

        Log.debug("MediaURLResolver: enumerating playlist",
                  component: "MediaURLResolver",
                  context: [("url", url), ("limit", "\(limit)")])

        let result = try await subprocess.run(ytDlpPath, args, timeout: 120)
        guard result.exitCode == 0 else {
            throw MediaURLResolverError.ytDlpFailed(
                exitCode: result.exitCode,
                stderr:   result.stderr
            )
        }

        return Self.parseEnumerateOutput(result.stdout)
    }

    /// Parses NDJSON output from `yt-dlp --flat-playlist --dump-json`.
    ///
    /// `public static` for unit testing with fixture strings.
    public static func parseEnumerateOutput(_ ndjson: String) -> [ResolvedEntry] {
        var entries: [ResolvedEntry] = []
        for line in ndjson.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let id    = (obj["id"]    as? String) ?? ""
            let title = (obj["title"] as? String) ?? id
            let url   = (obj["url"]   as? String)
                     ?? (obj["webpage_url"] as? String)
                     ?? ""
            guard !id.isEmpty else { continue }
            entries.append(ResolvedEntry(id: id, title: title, url: url))
        }
        return entries
    }
}
