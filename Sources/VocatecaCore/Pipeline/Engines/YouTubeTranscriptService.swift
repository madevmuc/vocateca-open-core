import Foundation

// MARK: - ExtractedTranscript

/// A single-video YouTube transcript, however it was obtained.
///
/// Pinned shape (Phase E's canonical output) — the YouTube Explorer tab
/// (Phase B) and `vocateca-cli transcript` consume this verbatim, so its
/// fields must not change without updating every consumer.
public struct ExtractedTranscript: Sendable, Equatable {
    public let videoID: String
    public let title: String
    public let channelID: String?
    public let channelHandle: String?
    /// The channel's DISPLAY name (yt-dlp's `%(channel)s` / `--dump-json`
    /// `"channel"`), e.g. "The Diary Of A CEO" — distinct from
    /// `channelHandle` (the `@handle`-style `uploader_id`). This is the
    /// value `YouTubeExplorerLibrarySave` uses as both the saved show's
    /// title and `author`, so a same-creator podcast (whose `author`/title
    /// normalises to the same key) gets grouped with it by
    /// ``CreatorAggregator``. `nil` when yt-dlp couldn't determine it (e.g.
    /// the fast known-track path in `captions(forVideoURL:track:)`, which
    /// does no metadata fetch at all).
    public let channelName: String?
    public let segments: [TranscriptionSegment]
    public let language: String?

    /// How this transcript was produced.
    public enum Source: String, Sendable, Equatable {
        /// Pulled from YouTube's own manual or auto-generated captions —
        /// instant, no local transcription run.
        case captions
        /// Produced by running a local ASR engine over the downloaded audio.
        case engine
    }
    public let source: Source

    /// For `source == .captions`: whether the caption track that was used was
    /// YouTube's machine-generated auto-captions (`true`) or the human/
    /// creator-authored track (`false`). `nil` for `source == .engine`, or
    /// when the caller doesn't know (kept optional so this stays additive).
    ///
    /// This is what lets provenance-recording callers (e.g.
    /// `YouTubeExplorerLibrarySave`) tell auto-generated captions apart from
    /// manually-authored ones — `Source` alone only says "came from
    /// captions", not who wrote them.
    public let captionsAuto: Bool?

    /// The video's aspect ratio (width ÷ height) from the yt-dlp manifest — e.g.
    /// `1.777…` (16:9), `1.333…` (4:3), `0.5625` (9:16 Short). Lets the Explorer
    /// size the player to the real video shape. `nil` when unknown (view
    /// defaults to 16:9).
    public let aspectRatio: Double?

    public init(
        videoID: String,
        title: String,
        channelID: String?,
        channelHandle: String?,
        channelName: String? = nil,
        segments: [TranscriptionSegment],
        language: String?,
        source: Source,
        captionsAuto: Bool? = nil,
        aspectRatio: Double? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.channelID = channelID
        self.channelHandle = channelHandle
        self.channelName = channelName
        self.segments = segments
        self.language = language
        self.source = source
        self.captionsAuto = captionsAuto
        self.aspectRatio = aspectRatio
    }
}

// MARK: - YouTubeTranscriptError

/// Errors thrown by ``YouTubeTranscriptService``.
public enum YouTubeTranscriptError: Error, Equatable {
    /// `captions(forVideoURL:)` only handles single-video URLs — playlists,
    /// channel IDs, handles, and channel URLs are rejected with the
    /// original (untouched) URL string so the caller can report it. The CLI
    /// layer is responsible for branching on playlist/channel URLs *before*
    /// ever calling this service.
    case notAVideoURL(String)
}

// MARK: - YouTubeTranscriptService

/// Captions-first single-video transcript extraction + multi-format
/// rendering, shared by the YouTube Explorer tab (Phase B) and
/// `vocateca-cli transcript` (open-core).
public enum YouTubeTranscriptService: Sendable {

    // MARK: - captions(forVideoURL:)

    /// Extracts a transcript from a single YouTube video's captions.
    ///
    /// Captions-first: tries manual (human) captions, then YouTube's
    /// auto-generated captions, before giving up. Returns `nil` — not a
    /// thrown error — when the video has no usable captions of either kind;
    /// "no captions" is an expected, non-exceptional outcome the caller
    /// falls back to a local-engine extraction for.
    ///
    /// - Throws: ``YouTubeTranscriptError/notAVideoURL(_:)`` if `url` is not
    ///   a single-video YouTube URL (e.g. a playlist or channel URL).
    public static func captions(forVideoURL url: String) async throws -> ExtractedTranscript? {
        try await captions(forVideoURL: url, desiredLanguage: nil, captionFetcher: YtDlpCaptionFetching())
    }

    // MARK: - captions(forVideoURL:language:)

    /// Extracts a transcript from a SPECIFIC caption-track language,
    /// bypassing the default original-language selection — for a caller
    /// (e.g. a caption-language picker UI) that knows which language it
    /// wants but not yet which exact ``CaptionTrack`` (use
    /// ``captions(forVideoURL:track:)`` instead once the track itself is
    /// already known, e.g. from ``captionsWithTracks(forVideoURL:)`` — it
    /// avoids the manifest re-probe this overload still runs).
    ///
    /// `language` is matched the same way as the default path (exact match
    /// -> base-language fallback in either direction -> manual preferred
    /// over auto in-language — see ``CaptionLanguageMatcher``), so passing a
    /// region-tagged or bare code (`"de"` or `"de-DE"`) both work.
    ///
    /// - Throws: ``YouTubeTranscriptError/notAVideoURL(_:)`` if `url` is not
    ///   a single-video YouTube URL.
    public static func captions(forVideoURL url: String, language: String) async throws -> ExtractedTranscript? {
        try await captions(forVideoURL: url, desiredLanguage: language, captionFetcher: YtDlpCaptionFetching())
    }

    // MARK: - captions(forVideoURL:track:)

    /// Extracts a transcript for ONE already-known ``CaptionTrack`` — e.g.
    /// from the manifest ``captionsWithTracks(forVideoURL:)`` or
    /// ``listCaptionTracks(forVideoURL:)`` already returned for a caption-
    /// language picker UI. Fetches the track directly over HTTP via
    /// ``CaptionTrack/url`` (falling back to yt-dlp only if that fails) —
    /// NO manifest re-probe, NO metadata re-fetch. This is the fast path a
    /// language switch on an already-loaded video should use.
    ///
    /// The returned transcript's `title`/`channelID`/`channelHandle` are NOT
    /// populated (no metadata fetch happens here) — callers that display
    /// those fields should carry them over from the video's already-loaded
    /// transcript, which doesn't change across a caption-track switch.
    ///
    /// - Throws: ``YouTubeTranscriptError/notAVideoURL(_:)`` if `url` is not
    ///   a single-video YouTube URL.
    public static func captions(forVideoURL url: String, track: CaptionTrack) async throws -> ExtractedTranscript? {
        try await captions(forVideoURL: url, track: track, captionFetcher: YtDlpCaptionFetching())
    }

    /// Module-internal overload of ``captions(forVideoURL:track:)`` carrying
    /// an injected `captionFetcher` seam, so tests can exercise it with a
    /// fake — no network.
    static func captions(
        forVideoURL url: String,
        track: CaptionTrack,
        captionFetcher: CaptionFetching
    ) async throws -> ExtractedTranscript? {
        guard case let .video(videoID) = try classify(url) else {
            throw YouTubeTranscriptError.notAVideoURL(url)
        }

        Log.debug("YouTubeTranscriptService: fetching one known caption track", component: "Captions",
                   context: [("videoID", videoID), ("language", track.languageCode), ("auto", "\(track.isAuto)")])

        guard let vtt = await fetchVTT(for: track, videoURL: url, captionFetcher: captionFetcher),
              let result = TranscriptFormat.captionResult(fromVTT: vtt, language: track.languageCode, isAuto: track.isAuto)
        else {
            Log.info("YouTubeTranscriptService: fetch of known track failed", component: "Captions",
                      context: [("videoID", videoID), ("language", track.languageCode)])
            return nil
        }

        Log.info("YouTubeTranscriptService: extracted transcript from known caption track", component: "Captions",
                  context: [("videoID", videoID), ("segments", "\(result.segments.count)"),
                            ("auto", "\(track.isAuto)"), ("language", track.languageCode)])

        return ExtractedTranscript(
            videoID: videoID,
            title: videoID,
            channelID: nil,
            channelHandle: nil,
            segments: result.segments,
            language: result.language,
            source: .captions,
            captionsAuto: track.isAuto)
    }

    // MARK: - captionsWithTracks(forVideoURL:)

    /// Single-call captions load: ONE `yt-dlp --dump-json` manifest+meta
    /// probe returns everything an Explorer-style caller needs — the
    /// default-selected transcript AND the full track manifest for a
    /// caption-language picker UI — instead of the old two-call
    /// `listCaptionTracks(forVideoURL:)` + `captions(forVideoURL:tracks:)`
    /// pairing (which, worse, itself hid a THIRD yt-dlp call inside for
    /// metadata). This is the main perf fix: a video load now makes exactly
    /// one yt-dlp subprocess plus one direct HTTP GET for the chosen
    /// track's VTT.
    ///
    /// - Returns: `(transcript, tracks)` — `transcript` is `nil` when the
    ///   manifest has no usable track (empty manifest, or the selected
    ///   track's VTT couldn't be fetched); `tracks` is always the full
    ///   manifest (possibly `[]`) regardless of whether `transcript` is
    ///   `nil`, so the caller can still show "no captions" vs. "captions
    ///   exist but failed to load" accurately.
    /// - Throws: ``YouTubeTranscriptError/notAVideoURL(_:)`` if `url` is not
    ///   a single-video YouTube URL.
    public static func captionsWithTracks(forVideoURL url: String) async throws -> (ExtractedTranscript?, [CaptionTrack]) {
        try await captionsWithTracks(forVideoURL: url, captionFetcher: YtDlpCaptionFetching())
    }

    /// Module-internal overload of ``captionsWithTracks(forVideoURL:)``
    /// carrying an injected `captionFetcher` seam, so tests can exercise it
    /// with a fake — no network.
    static func captionsWithTracks(
        forVideoURL url: String,
        captionFetcher: CaptionFetching
    ) async throws -> (ExtractedTranscript?, [CaptionTrack]) {
        guard case let .video(videoID) = try classify(url) else {
            throw YouTubeTranscriptError.notAVideoURL(url)
        }
        return try await captionsWithTracks(videoID: videoID, url: url, desiredLanguage: nil, captionFetcher: captionFetcher)
    }

    /// Module-internal overload carrying injected seams, so tests can
    /// exercise the full captions-first algorithm with fakes (`@testable
    /// import`) — no network. Production callers always use one of the
    /// public `captions(forVideoURL:)` overloads above.
    ///
    /// Manifest-driven selection (fix for P4 perf + P6/P6-EXT region-mismatch
    /// bugs, now ALSO folding the metadata probe into the same manifest
    /// call): ONE `listManifest` probe (tracks + meta together), ONE
    /// ``CaptionLanguageMatcher`` selection, ONE track fetch (HTTP first,
    /// yt-dlp fallback) — never the old multi-attempt manual-orig/
    /// manual-any/auto-orig/auto-any cascade, whose "-any" (unconstrained-
    /// language) steps were what made yt-dlp enumerate/download a massive
    /// number of tracks on videos with hundreds of auto-translate caption
    /// languages, and never a separate metadata subprocess either.
    static func captions(
        forVideoURL url: String,
        desiredLanguage: String?,
        captionFetcher: CaptionFetching
    ) async throws -> ExtractedTranscript? {
        guard case let .video(videoID) = try classify(url) else {
            throw YouTubeTranscriptError.notAVideoURL(url)
        }
        let (transcript, _) = try await captionsWithTracks(
            videoID: videoID, url: url, desiredLanguage: desiredLanguage, captionFetcher: captionFetcher)
        return transcript
    }

    /// Shared implementation behind ``captions(forVideoURL:desiredLanguage:captionFetcher:)``
    /// and ``captionsWithTracks(forVideoURL:captionFetcher:)`` — both just
    /// differ in whether they discard the track list.
    private static func captionsWithTracks(
        videoID: String,
        url: String,
        desiredLanguage: String?,
        captionFetcher: CaptionFetching
    ) async throws -> (ExtractedTranscript?, [CaptionTrack]) {
        Log.debug("YouTubeTranscriptService: fetching captions", component: "Captions",
                   context: [("videoID", videoID), ("desiredLanguage", desiredLanguage ?? "")])

        // ONE manifest+meta probe — tracks AND the video's original
        // language (which steers the default, desiredLanguage == nil,
        // selection below) come from the SAME `--dump-json` call.
        let (meta, tracks) = await captionFetcher.listManifest(videoURL: url)
        let originalLang = (meta?.language?.isEmpty == false) ? meta?.language : nil

        guard !tracks.isEmpty else {
            Log.info("YouTubeTranscriptService: no caption tracks in manifest", component: "Captions",
                      context: [("videoID", videoID)])
            return (nil, tracks)
        }

        guard let chosen = CaptionLanguageMatcher.selectTrack(
            from: tracks, desiredLanguage: desiredLanguage, originalLanguage: originalLang)
        else {
            Log.info("YouTubeTranscriptService: no caption track selectable from manifest", component: "Captions",
                      context: [("videoID", videoID)])
            return (nil, tracks)
        }

        Log.debug("YouTubeTranscriptService: selected caption track", component: "Captions",
                   context: [("videoID", videoID), ("language", chosen.languageCode), ("auto", "\(chosen.isAuto)")])

        guard let vtt = await fetchVTT(for: chosen, videoURL: url, captionFetcher: captionFetcher),
              let result = TranscriptFormat.captionResult(fromVTT: vtt, language: chosen.languageCode, isAuto: chosen.isAuto)
        else {
            Log.info("YouTubeTranscriptService: fetch of selected track failed", component: "Captions",
                      context: [("videoID", videoID), ("language", chosen.languageCode)])
            return (nil, tracks)
        }

        Log.info("YouTubeTranscriptService: extracted transcript from captions", component: "Captions",
                  context: [("videoID", videoID), ("segments", "\(result.segments.count)"),
                            ("auto", "\(chosen.isAuto)"), ("language", chosen.languageCode)])

        let transcript = ExtractedTranscript(
            videoID: videoID,
            title: meta?.title.isEmpty == false ? meta!.title : videoID,
            channelID: meta?.channelID,
            channelHandle: meta?.channelHandle,
            channelName: meta?.channelName,
            segments: result.segments,
            language: result.language,
            source: .captions,
            captionsAuto: chosen.isAuto,
            aspectRatio: meta?.aspectRatio)
        return (transcript, tracks)
    }

    /// Fetches `track`'s WebVTT: direct HTTP via ``CaptionTrack/url`` first
    /// (no yt-dlp subprocess — the perf win), falling back to the yt-dlp
    /// `--sub-langs` download (`captionFetcher.fetchTrack`) when `track.url`
    /// is `nil` or the HTTP fetch fails/returns something that isn't VTT.
    private static func fetchVTT(
        for track: CaptionTrack, videoURL: String, captionFetcher: CaptionFetching
    ) async -> String? {
        if let vtt = await captionFetcher.fetchTrackViaHTTP(track) {
            return vtt
        }
        Log.debug("YouTubeTranscriptService: direct HTTP caption fetch missed, falling back to yt-dlp",
                  component: "Captions", context: [("language", track.languageCode)])
        return await captionFetcher.fetchTrack(videoURL: videoURL, track: track)
    }

    // MARK: - listCaptionTracks(forVideoURL:)

    /// Lists a video's available caption tracks (manual + auto) without
    /// downloading any subtitle content — the manifest a caption-language
    /// picker UI presents. A single `yt-dlp --dump-json` probe (~3s),
    /// independent of `captions(forVideoURL:)`.
    ///
    /// - Throws: ``YouTubeTranscriptError/notAVideoURL(_:)`` if `url` is not
    ///   a single-video YouTube URL, mirroring `captions(forVideoURL:)`.
    public static func listCaptionTracks(forVideoURL url: String) async throws -> [CaptionTrack] {
        try await listCaptionTracks(forVideoURL: url, captionFetcher: YtDlpCaptionFetching())
    }

    /// Module-internal overload carrying an injected `captionFetcher` seam,
    /// mirroring `captions(forVideoURL:desiredLanguage:captionFetcher:)`.
    static func listCaptionTracks(
        forVideoURL url: String,
        captionFetcher: CaptionFetching
    ) async throws -> [CaptionTrack] {
        guard case .video = try classify(url) else {
            throw YouTubeTranscriptError.notAVideoURL(url)
        }
        return await captionFetcher.listTracks(videoURL: url)
    }

    /// Kind describing a classified single-video YouTube URL.
    private enum Classified {
        case video(String)
    }

    /// Thin wrapper around ``YouTubeURL/parse(_:)`` that narrows to this
    /// service's single-video contract: any non-`.video` kind
    /// (`.playlist`/`.channelID`/`.handle`/`.channelURL`) is reported as
    /// ``YouTubeTranscriptError/notAVideoURL(_:)`` by the caller.
    private static func classify(_ url: String) throws -> Classified {
        let parsed = try YouTubeURL.parse(url)
        guard parsed.kind == .video else {
            throw YouTubeTranscriptError.notAVideoURL(url)
        }
        return .video(parsed.value)
    }

    // MARK: - render(_:format:)

    /// Renders an ``ExtractedTranscript`` into one of six export formats.
    ///
    /// Pure, no I/O. Chains through the existing oracle-locked
    /// `TranscriptFormat.vttToSRT`/`srtToPlainText` and the Phase A
    /// `TranscriptFormat.vttFromSegments`/`csvFromSegments` rather than
    /// inventing a parallel segments→SRT renderer.
    ///
    /// - Parameter format: one of `"md"`, `"txt"`, `"srt"`, `"vtt"`, `"csv"`,
    ///   `"json"`. Any other value falls back to `"txt"`.
    public static func render(_ t: ExtractedTranscript, format: String) -> String {
        switch format {
        case "vtt":
            return TranscriptFormat.vttFromSegments(t.segments)
        case "srt":
            return TranscriptFormat.vttToSRT(TranscriptFormat.vttFromSegments(t.segments))
        case "csv":
            // `TranscriptFormat.csvFromSegments` (Phase A, as shipped) takes only
            // `segments` — no `speakers:` overlay parameter — and reads
            // `segment.speaker` directly. `t.segments` already carry that field
            // (set at engine-transcription time by diarization, nil for a pure
            // captions extraction), so no overlay is needed here.
            return TranscriptFormat.csvFromSegments(t.segments)
        case "txt":
            return TranscriptFormat.srtToPlainText(render(t, format: "srt")) + "\n"
        case "md":
            let body = TranscriptFormat.srtToPlainText(render(t, format: "srt"))
            return "# \(t.title)\n\n\(body)\n"
        case "json":
            return renderJSON(t.segments)
        default:
            return render(t, format: "txt")
        }
    }

    private struct JSONSegment: Codable {
        let start: Double
        let end: Double
        let speaker: String?
        let text: String
    }

    private static func renderJSON(_ segments: [TranscriptionSegment]) -> String {
        let rows = segments.map { seg in
            JSONSegment(start: seg.start, end: seg.end,
                        speaker: seg.speaker.map { "S\($0 + 1)" }, text: seg.text)
        }
        let data = (try? JSONEncoder().encode(rows)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
