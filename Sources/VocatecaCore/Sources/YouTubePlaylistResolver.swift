import Foundation

/// A single video inside a resolved YouTube playlist. Declared once here
/// (VocatecaCore, open-core) — Phase B (YouTube Explorer tab) and Phase E
/// (CLI/MCP `transcript` bulk mode) reuse this exact type, they do not
/// redeclare it.
public struct PlaylistEntry: Sendable, Equatable {
    public let videoID: String
    public let title: String
    public let url: String
    public init(videoID: String, title: String, url: String) {
        self.videoID = videoID
        self.title = title
        self.url = url
    }
}

/// Resolves a YouTube playlist URL to its flat list of videos. Wraps
/// `MediaURLResolver.enumerate(url:limit:)` (yt-dlp `--flat-playlist
/// --dump-json`) rather than shelling out separately — same subprocess,
/// same hardened args, one less yt-dlp invocation path to maintain.
public enum YouTubePlaylistResolver {
    public static func entries(forURL url: String, limit: Int = 500) async throws -> [PlaylistEntry] {
        Log.info("YouTubePlaylistResolver: resolving playlist",
                 component: "YouTubePlaylist", context: [("url", url), ("limit", "\(limit)")])
        let resolved = try await MediaURLResolver().enumerate(url: url, limit: limit)
        let mapped = map(resolved)
        Log.info("YouTubePlaylistResolver: resolved",
                 component: "YouTubePlaylist", context: [("count", "\(mapped.count)")])
        return mapped
    }

    /// Pure mapping — kept `static` (not `private`) so it's directly
    /// unit-testable via `@testable import` without a subprocess.
    static func map(_ entries: [ResolvedEntry]) -> [PlaylistEntry] {
        entries.map { PlaylistEntry(videoID: $0.id, title: $0.title, url: $0.url) }
    }
}
