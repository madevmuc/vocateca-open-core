import Foundation

// MARK: - CaptionFetching

/// A thin protocol seam over the manifest-driven pieces of
/// ``YtDlpCaptionFetcher``:
/// ``YtDlpCaptionFetcher/listManifest(videoURL:binaryManager:subprocess:timeout:)``,
/// ``YtDlpCaptionFetcher/listTracks(videoURL:binaryManager:subprocess:timeout:)``,
/// ``YtDlpCaptionFetcher/fetchTrack(videoURL:track:binaryManager:subprocess:timeout:)``,
/// and ``YtDlpCaptionFetcher/fetchTrackViaHTTP(_:session:timeout:)``.
///
/// `YtDlpCaptionFetcher`'s manifest methods are static funcs on a concrete
/// `enum` with no injection point, so callers that need a fake for
/// non-network unit tests (e.g. `YouTubeTranscriptService.captions(forVideoURL:)`)
/// have nothing to substitute. This protocol gives them one, without
/// changing `YtDlpCaptionFetcher` itself in any way.
public protocol CaptionFetching: Sendable {

    /// Lists a video's available caption tracks (manual + auto) AND its
    /// metadata (title/channel/original language) via a single manifest
    /// probe — never downloads any subtitle content. This is the ONE
    /// yt-dlp call the perf fix collapses caption loading down to; see
    /// ``YtDlpCaptionFetcher/listManifest(videoURL:binaryManager:subprocess:timeout:)``.
    ///
    /// - Returns: `(nil, [])` on any failure (yt-dlp missing, unsafe URL,
    ///   timeout, unparsable output) so the caller falls back cleanly
    ///   (ultimately Whisper) instead of throwing.
    func listManifest(videoURL: String) async -> (meta: YouTubeVideoMeta?, tracks: [CaptionTrack])

    /// Lists a video's available caption tracks (manual + auto) via a
    /// single manifest probe — never downloads any subtitle content.
    ///
    /// - Returns: `[]` on any failure (yt-dlp missing, unsafe URL, timeout,
    ///   unparsable output) so the caller falls back cleanly (ultimately
    ///   Whisper) instead of throwing.
    func listTracks(videoURL: String) async -> [CaptionTrack]

    /// Fetches exactly one, already-selected caption track directly over
    /// HTTP using ``CaptionTrack/url`` — NO yt-dlp subprocess — and returns
    /// its raw WebVTT text, or `nil` if it could not be fetched (`url` nil,
    /// unsafe URL, request failure/timeout, body isn't WebVTT). The primary
    /// fetch path; callers fall back to
    /// ``fetchTrack(videoURL:track:)`` on `nil`.
    func fetchTrackViaHTTP(_ track: CaptionTrack) async -> String?

    /// Fetches exactly one, already-selected caption track VIA YT-DLP
    /// (`--sub-langs`) and returns its raw WebVTT text, or `nil` if it could
    /// not be fetched (yt-dlp missing, timeout, non-zero exit, empty
    /// result). Fallback path for when ``fetchTrackViaHTTP(_:)`` can't be
    /// used (`track.url` is `nil`) or fails.
    func fetchTrack(videoURL: String, track: CaptionTrack) async -> String?
}

// MARK: - YtDlpCaptionFetching

/// Production adapter: forwards straight to ``YtDlpCaptionFetcher``'s
/// manifest-driven `listManifest`/`listTracks`/`fetchTrackViaHTTP`/
/// `fetchTrack`, with their default `binaryManager`/`subprocess`/`session`/
/// `timeout`. Behaviour is identical to calling `YtDlpCaptionFetcher`
/// directly — this type adds no logic, only an injection seam.
public struct YtDlpCaptionFetching: CaptionFetching {

    public init() {}

    public func listManifest(videoURL: String) async -> (meta: YouTubeVideoMeta?, tracks: [CaptionTrack]) {
        await YtDlpCaptionFetcher.listManifest(videoURL: videoURL)
    }

    public func listTracks(videoURL: String) async -> [CaptionTrack] {
        await YtDlpCaptionFetcher.listTracks(videoURL: videoURL)
    }

    public func fetchTrackViaHTTP(_ track: CaptionTrack) async -> String? {
        await YtDlpCaptionFetcher.fetchTrackViaHTTP(track)
    }

    public func fetchTrack(videoURL: String, track: CaptionTrack) async -> String? {
        await YtDlpCaptionFetcher.fetchTrack(videoURL: videoURL, track: track)
    }
}
