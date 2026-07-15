import Foundation

// MARK: - CaptionTrack

/// A single available caption track for a YouTube video, as reported by
/// yt-dlp's manifest (`--dump-json`) — BEFORE any subtitle content is
/// downloaded.
///
/// This is the shape ``YtDlpCaptionFetcher/listTracks(videoURL:binaryManager:subprocess:timeout:)``
/// parses out of yt-dlp's `subtitles`/`automatic_captions` dictionaries, and
/// the shape a future caption-language picker UI consumes.
public struct CaptionTrack: Sendable, Equatable {
    /// The track's language code exactly as yt-dlp reports it, e.g. `"en"`,
    /// `"en-US"`, `"de-DE"`. NOT normalised — callers that need base-language
    /// matching go through ``CaptionLanguageMatcher``.
    public let languageCode: String
    /// Human-readable name yt-dlp attaches to the track (e.g. `"English"`,
    /// `"German (auto-generated)"`), falling back to `languageCode` when
    /// yt-dlp doesn't supply one.
    public let displayName: String
    /// `true` for YouTube's machine-generated auto-captions
    /// (yt-dlp's `automatic_captions`), `false` for human/creator-authored
    /// subtitles (yt-dlp's `subtitles`).
    public let isAuto: Bool
    /// The direct, yt-dlp-minted HTTP(S) URL for this track's `vtt`-format
    /// caption file, as found in the manifest's `subtitles`/
    /// `automatic_captions` entry (the `ext == "vtt"` format's `url`). This
    /// URL is fetchable with a plain HTTP GET — no yt-dlp subprocess needed
    /// — which is what lets caption fetching collapse from three yt-dlp
    /// invocations per video down to one. `nil` when the manifest had no
    /// `vtt` entry for this track (falls back to
    /// ``YtDlpCaptionFetcher/fetchTrack(videoURL:track:binaryManager:subprocess:timeout:)``).
    public let url: String?

    public init(languageCode: String, displayName: String, isAuto: Bool, url: String? = nil) {
        self.languageCode = languageCode
        self.displayName = displayName
        self.isAuto = isAuto
        self.url = url
    }
}
