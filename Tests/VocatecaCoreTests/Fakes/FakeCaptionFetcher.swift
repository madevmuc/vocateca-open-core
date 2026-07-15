import Foundation
@testable import VocatecaCore

// MARK: - FakeCaptionFetcher

/// A scriptable `CaptionFetching` test double for the manifest-driven
/// design: a video's manifest (tracks + meta) is scripted up front;
/// `fetchTrackViaHTTP` content is scripted per exact track URL, and
/// `fetchTrack` (the yt-dlp fallback) content is scripted per exact
/// `CaptionTrack`.
///
/// Any `videoURL` not present in `tracksScript`/`metaScript` returns
/// `[]`/`nil` from `listManifest`/`listTracks` — the same "no tracks found"
/// outcome `YtDlpCaptionFetcher` produces on failure. Any track/URL not
/// present in the relevant content script returns `nil` from the
/// corresponding fetch method — the same "fetch failed" outcome. Since
/// production `CaptionTrack`s built by tests default `url` to `nil`,
/// `fetchTrackViaHTTP` naturally misses for them (no scripting needed) and
/// the caller falls through to `fetchTrack` — mirroring
/// `YouTubeTranscriptService`'s real HTTP-then-yt-dlp-fallback order.
///
/// Records every call for assertion, and is safe to call from concurrent
/// tasks via an internal lock.
final class FakeCaptionFetcher: CaptionFetching, @unchecked Sendable {

    struct FetchCall: Equatable {
        let videoURL: String
        let track: CaptionTrack
    }

    private let lock = NSLock()
    private var tracksScript: [String: [CaptionTrack]]
    private var metaScript: [String: YouTubeVideoMeta]
    private var contentScript: [String: String?]
    private var httpContentScript: [String: String?]
    private var _listManifestCalls: [String] = []
    private var _listCalls: [String] = []
    private var _fetchCalls: [FetchCall] = []
    private var _httpFetchCalls: [CaptionTrack] = []

    /// All `videoURL`s passed to `listManifest`, in order.
    var listManifestCalls: [String] { lock.withLock { _listManifestCalls } }
    /// All `videoURL`s passed to `listTracks`, in order.
    var listCalls: [String] { lock.withLock { _listCalls } }
    /// All `(videoURL, track)` pairs passed to `fetchTrack`, in order.
    var fetchCalls: [FetchCall] { lock.withLock { _fetchCalls } }
    /// All tracks passed to `fetchTrackViaHTTP`, in order.
    var httpFetchCalls: [CaptionTrack] { lock.withLock { _httpFetchCalls } }

    /// Composite key used by `contentScript`: distinguishes tracks by
    /// language code + auto-ness within a video.
    static func contentKey(videoURL: String, track: CaptionTrack) -> String {
        "\(videoURL)|\(track.languageCode)|\(track.isAuto)"
    }

    /// - Parameters:
    ///   - tracksScript: maps `videoURL` to the manifest `listManifest`/
    ///     `listTracks` should return for it. A URL absent from this
    ///     returns `[]`.
    ///   - metaScript: maps `videoURL` to the meta `listManifest` should
    ///     return for it. A URL absent from this returns `nil` meta.
    ///   - contentScript: maps `contentKey(videoURL:track:)` to the WebVTT
    ///     text `fetchTrack` (yt-dlp fallback) should return for that exact
    ///     track, or to `nil` to model "fetch failed for this track". A key
    ///     absent from this also returns `nil`.
    ///   - httpContentScript: maps a track's `url` to the WebVTT text
    ///     `fetchTrackViaHTTP` should return for it. A URL absent from this
    ///     (or a track with `url == nil`) also returns `nil`.
    init(
        tracksScript: [String: [CaptionTrack]] = [:],
        metaScript: [String: YouTubeVideoMeta] = [:],
        contentScript: [String: String?] = [:],
        httpContentScript: [String: String?] = [:]
    ) {
        self.tracksScript = tracksScript
        self.metaScript = metaScript
        self.contentScript = contentScript
        self.httpContentScript = httpContentScript
    }

    /// Convenience initializer for the common single-video case: one
    /// video's manifest (+ optional meta), plus WebVTT content keyed by
    /// track (yt-dlp fallback path) and/or by track URL (direct-HTTP path).
    convenience init(
        videoURL: String,
        tracks: [CaptionTrack],
        meta: YouTubeVideoMeta? = nil,
        content: [CaptionTrack: String] = [:],
        httpContent: [CaptionTrack: String] = [:]
    ) {
        var contentScript: [String: String?] = [:]
        for (track, vtt) in content {
            contentScript[Self.contentKey(videoURL: videoURL, track: track)] = vtt
        }
        var httpContentScript: [String: String?] = [:]
        for (track, vtt) in httpContent {
            if let url = track.url { httpContentScript[url] = vtt }
        }
        self.init(
            tracksScript: [videoURL: tracks],
            metaScript: meta.map { [videoURL: $0] } ?? [:],
            contentScript: contentScript,
            httpContentScript: httpContentScript)
    }

    func listManifest(videoURL: String) async -> (meta: YouTubeVideoMeta?, tracks: [CaptionTrack]) {
        lock.withLock { _listManifestCalls.append(videoURL) }
        return lock.withLock { (metaScript[videoURL], tracksScript[videoURL] ?? []) }
    }

    func listTracks(videoURL: String) async -> [CaptionTrack] {
        lock.withLock { _listCalls.append(videoURL) }
        return lock.withLock { tracksScript[videoURL] ?? [] }
    }

    func fetchTrackViaHTTP(_ track: CaptionTrack) async -> String? {
        lock.withLock { _httpFetchCalls.append(track) }
        guard let url = track.url,
              let entry = lock.withLock({ httpContentScript[url] })
        else { return nil }
        return entry
    }

    func fetchTrack(videoURL: String, track: CaptionTrack) async -> String? {
        lock.withLock { _fetchCalls.append(FetchCall(videoURL: videoURL, track: track)) }
        guard let entry = lock.withLock({ contentScript[Self.contentKey(videoURL: videoURL, track: track)] })
        else { return nil }
        return entry
    }
}

// `CaptionTrack` needs to be `Hashable` for the `[CaptionTrack: String]`
// convenience-initializer dictionary above; it's only `Equatable` in
// production code (no production need for hashing), so extend it here,
// test-side only.
extension CaptionTrack: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(languageCode)
        hasher.combine(displayName)
        hasher.combine(isAuto)
    }
}
