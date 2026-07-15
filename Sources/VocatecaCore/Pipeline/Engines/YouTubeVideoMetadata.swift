import Foundation

// MARK: - YouTubeVideoMeta

/// Minimal video metadata pulled from yt-dlp's `--print` output.
///
/// Feeds `ExtractedTranscript`'s `title`/`channelID`/`channelHandle` fields
/// (Task E.3) — none of which `YtDlpCaptionFetcher` or
/// `MediaURLResolver.resolve` currently expose.
public struct YouTubeVideoMeta: Sendable, Equatable {
    public let videoID: String
    public let title: String
    public let channelID: String?
    public let channelHandle: String?

    /// The video's ORIGINAL (creator-authored) language, e.g. `"en"` — yt-dlp's
    /// `%(language)s`. `nil` when yt-dlp couldn't determine it. Used by
    /// `YouTubeTranscriptService`'s caption selection (see
    /// ``CaptionLanguageMatcher``) to prefer a manual caption track in the
    /// video's own language over a machine-translated one. Additive
    /// (defaulted) so existing call sites that don't care about language
    /// keep compiling.
    ///
    /// NOTE: since the P-perf fix, `YouTubeTranscriptService`'s primary
    /// caption-loading path builds this from the SAME `--dump-json` probe
    /// that lists caption tracks (``YtDlpCaptionFetcher/listManifest(videoURL:binaryManager:subprocess:timeout:)``)
    /// rather than via ``YtDlpVideoMetadataFetcher`` below, which remains a
    /// standalone metadata-only probe for any other caller that needs one.
    public let language: String?

    public init(videoID: String, title: String, channelID: String?, channelHandle: String?, language: String? = nil) {
        self.videoID = videoID
        self.title = title
        self.channelID = channelID
        self.channelHandle = channelHandle
        self.language = language
    }
}

// MARK: - YouTubeVideoMetadataFetching

/// A thin protocol seam over ``YtDlpVideoMetadataFetcher/fetchMeta(videoURL:)``.
///
/// Mirrors the ``CaptionFetching`` seam (Task E.1): gives callers that need a
/// fake for non-network unit tests (e.g. `YouTubeTranscriptService.captions(forVideoURL:)`,
/// Task E.3) something to substitute, without a concrete `Process` dependency.
public protocol YouTubeVideoMetadataFetching: Sendable {

    /// Fetch a video's title/channel metadata, or `nil` if it could not be
    /// determined (unsafe URL, yt-dlp missing, non-zero exit, unparsable
    /// output). Never throws — the caller falls back to whatever it already
    /// has (e.g. the RSS/manifest-derived title).
    func fetchMeta(videoURL: String) async -> YouTubeVideoMeta?
}

// MARK: - YtDlpVideoMetadataFetcher

/// Production adapter: shells out to yt-dlp with a single `--print` probe,
/// mirroring the `--print %(language)s` pattern already used inside
/// `YtDlpCaptionFetcher.fetch`. Metadata-only — `--skip-download` — so this
/// is fast and does not touch the caption/media download path at all.
public struct YtDlpVideoMetadataFetcher: YouTubeVideoMetadataFetching {

    private let binaryManager: BinaryManager
    private let subprocess: Subprocess

    public init(binaryManager: BinaryManager = BinaryManager(), subprocess: Subprocess = Subprocess()) {
        self.binaryManager = binaryManager
        self.subprocess = subprocess
    }

    public func fetchMeta(videoURL: String) async -> YouTubeVideoMeta? {
        guard !videoURL.isEmpty,
              let ytdlp = binaryManager.resolvedPath(for: .ytDlp) else { return nil }

        // Reject non-http(s) schemes and bare "-…" tokens (argument-injection
        // guard), same as `YtDlpCaptionFetcher.fetch`. Never throws — a
        // rejected URL just yields no metadata.
        guard let safe = try? URLSafety.safeURL(videoURL) else {
            Log.warn("YtDlpVideoMetadataFetcher: rejected unsafe URL",
                     component: "Pipeline", context: [("url", videoURL)])
            return nil
        }

        let args = YtDlp.hardenedBaseArgs + [
            "--skip-download",
            "--no-playlist",
            "--print", "%(id)s|%(title)s|%(channel_id)s|%(uploader_id)s|%(language)s",
            "--", safe,
        ]

        Log.debug("yt-dlp video metadata fetch", component: "Captions", context: [("url", safe)])

        // Short timeout (20s): this is a metadata-only probe, not a caption
        // or media download, so it should never take as long as those.
        guard let result = try? await subprocess.run(ytdlp, args, timeout: 20),
              result.exitCode == 0 else { return nil }

        let line = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? result.stdout

        return Self.parseMetaLine(line)
    }

    // MARK: - Pure parsing

    /// Parses a single yt-dlp `--print "%(id)s|%(title)s|%(channel_id)s|%(uploader_id)s"`
    /// output line. Pure, no I/O — internal so tests can hit it directly
    /// without a subprocess.
    ///
    /// - Returns: `nil` if `line` does not contain at least 4 `|`-separated
    ///   fields (malformed output). `"NA"` and `""` are treated as absent for
    ///   `channelID`/`channelHandle`/`language` (yt-dlp's placeholder for a
    ///   missing field); `videoID`/`title` are always non-optional strings
    ///   (empty if yt-dlp printed nothing for them, never `nil`). The 5th
    ///   (`language`) field is optional in the input — lines from before this
    ///   field was added still parse, with `language == nil`.
    static func parseMetaLine(_ line: String) -> YouTubeVideoMeta? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.components(separatedBy: "|")
        guard fields.count >= 4 else { return nil }

        func presentOrNil(_ field: String) -> String? {
            (field.isEmpty || field == "NA") ? nil : field
        }

        return YouTubeVideoMeta(
            videoID: fields[0],
            title: fields[1],
            channelID: presentOrNil(fields[2]),
            channelHandle: presentOrNil(fields[3]),
            language: fields.count >= 5 ? presentOrNil(fields[4]) : nil
        )
    }
}
