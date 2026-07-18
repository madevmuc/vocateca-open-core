import Foundation

// MARK: - YouTubeResolverError

/// Errors thrown by ``YouTubeResolver``.
public enum YouTubeResolverError: Error, Sendable {
    /// yt-dlp did not produce a recognisable `UC…` channel id.
    case notResolved(String)
    /// yt-dlp is not installed.
    case ytdlpMissing
    /// yt-dlp exited non-zero or produced no usable output.
    case ytdlpFailed(String)
}

// MARK: - YouTubeResolver

/// Resolves YouTube channel handles/URLs to channel IDs and enumerates channel
/// videos via the **yt-dlp** binary.
///
/// Port of the yt-dlp path in `core/youtube_meta.py`. The fast HTTP canonical-
/// link path is intentionally skipped per the Phase-2 spec decision.
///
/// ## yt-dlp commands used
///
/// - **Resolve channel id**
///   `yt-dlp --skip-download --print "%(channel_id)s" <url>`
///   Works for any channel URL form (handle, /c/, /user/, /channel/UC…, video).
///
/// - **Channel preview**
///   URLSession GET on the RSS feed `feeds/videos.xml?channel_id=<id>` to get
///   the channel title and a lower-bound video count (~15 most recent entries).
///   Sets `videoCountIsLowerBound = true`.  Falls back to an empty preview on
///   any network error — callers should be tolerant.
///
/// - **Enumerate videos**
///   `yt-dlp --flat-playlist --dump-json [--playlist-end N] [--dateafter YYYYMMDD]
///    https://www.youtube.com/channel/<id>/videos`
///   One JSON object per stdout line.  Passed through `YouTubeManifest.fromVideos`
///   to produce canonical `Entry` values.
///
/// ## Shorts
/// The `/videos` tab excludes Shorts. When `includeShorts=true`, the `/shorts`
/// tab (`https://www.youtube.com/channel/<id>/shorts`) is enumerated with the
/// same yt-dlp invocation and merged with the `/videos` tab results via
/// `YouTubeManifest.mergeEntries` (de-duplicated by `guid`, videos first).
public struct YouTubeResolver: Sendable {

    // MARK: - Properties

    private let binaryManager: BinaryManager
    private let subprocess: Subprocess

    // MARK: - Init

    public init(binaryManager: BinaryManager = BinaryManager()) {
        self.binaryManager = binaryManager
        self.subprocess = Subprocess()
    }

    // MARK: - Resolve channel ID

    /// Resolve any YouTube input (URL, handle, bare name, channel id) to a
    /// `UC…` channel id.
    ///
    /// - If `input` already parses as `.channelID`, it is returned immediately
    ///   without any network call.
    /// - Otherwise, an appropriate URL is constructed and yt-dlp is invoked
    ///   with `--skip-download --print "%(channel_id)s"`.
    /// - Throws ``YouTubeResolverError/notResolved(_:)`` when yt-dlp produces
    ///   no valid channel id in its output.
    /// - Throws ``YouTubeResolverError/ytdlpMissing`` when yt-dlp is not
    ///   installed.
    /// - Throws ``YouTubeResolverError/ytdlpFailed(_:)`` when yt-dlp exits
    ///   non-zero.
    public func resolveChannelID(from input: String) async throws -> String {
        // 0. A channel-feed URL (`.../feeds/videos.xml?channel_id=UC…`) — the form
        //    the app itself stores as a YouTube show's `rss` (see
        //    `WatchlistStore.addYouTube` / reconnect) — already carries the id.
        //    Take it directly: `YouTubeURL.parse` does NOT recognise the feeds URL,
        //    so without this every YouTube poll throws `notResolved`, the feed is
        //    marked failed, and the show reads "feed unreachable".
        let feedChannelID = YouTubeURL.channelID(fromFeedURL: input)
        if !feedChannelID.isEmpty { return feedChannelID }

        // 1. Parse the input
        let parsed: YouTubeURL
        do {
            parsed = try YouTubeURL.parse(input)
        } catch {
            throw YouTubeResolverError.notResolved(input)
        }

        // 2. If we already have a channel id, return it.
        if case .channelID = parsed.kind {
            return parsed.value
        }

        // 3. Build the URL to pass to yt-dlp
        let targetURL = resolveURL(for: parsed)

        // 4. Run yt-dlp
        // Use --playlist-end 1 so yt-dlp only extracts the first item and prints
        // the channel_id once.  Without this, yt-dlp iterates the entire channel
        // playlist (potentially thousands of items) before returning.
        let out = try await runYtDlp(
            ["--skip-download", "--playlist-end", "1", "--print", "%(channel_id)s", targetURL],
            timeout: 120
        )

        // 5. Extract the channel id
        guard let channelID = Self.firstChannelID(in: out) else {
            throw YouTubeResolverError.notResolved(input)
        }
        return channelID
    }

    // MARK: - Channel preview

    /// A lightweight preview of a YouTube channel.
    public struct ChannelPreview: Sendable, Equatable {
        /// The channel's `UC…` id.
        public let channelID: String
        /// The channel title from the RSS feed.
        public let title: String
        /// Video count. Always a lower bound (from the RSS feed's ~15 entries).
        public let videoCount: Int
        /// Always `true` — the RSS feed only carries the 15 most recent videos.
        public let videoCountIsLowerBound: Bool
        /// First video thumbnail URL from the RSS feed, or `""` if unavailable.
        public let artworkURL: String

        public init(
            channelID: String,
            title: String,
            videoCount: Int,
            videoCountIsLowerBound: Bool,
            artworkURL: String
        ) {
            self.channelID = channelID
            self.title = title
            self.videoCount = videoCount
            self.videoCountIsLowerBound = videoCountIsLowerBound
            self.artworkURL = artworkURL
        }
    }

    /// Fetch a lightweight channel preview via the channel's YouTube RSS feed.
    ///
    /// **Approach:** URLSession GET on
    /// `https://www.youtube.com/feeds/videos.xml?channel_id=<channelID>`.
    /// The feed lists the ~15 most recent videos and carries the channel title
    /// and per-video thumbnail URLs. This is fast (no yt-dlp) and gives us
    /// everything the UI needs for an "add channel" confirmation screen.
    ///
    /// - `videoCount` is the number of entries in the RSS feed (≤ 15), so it
    ///   is always a lower bound.  `videoCountIsLowerBound` is always `true`.
    /// - `artworkURL` is the `<media:thumbnail url="…">` from the first (newest)
    ///   entry.  It is a video frame, not a channel avatar — good enough for a
    ///   preview, and no extra network requests are needed.
    ///
    /// The feed URL is validated by ``URLSafety/safeURL(_:allowPrivate:)`` (SSRF
    /// guard) and the response is capped at ``URLSafety/maxFeedBytes`` via
    /// ``URLSafety/boundedData(from:maxBytes:timeout:session:)`` before parsing.
    ///
    /// Throws on network error, SSRF guard rejection, or unparseable XML.
    public func channelPreview(channelID: String) async throws -> ChannelPreview {
        let rawFeedURL = YouTubeURL.rssURL(forChannelID: channelID)
        // SSRF guard: validate before fetching. youtube.com is always public so
        // this should never throw in production; it protects against a crafted
        // channelID that embeds a redirect to a private host.
        try URLSafety.safeURL(rawFeedURL)
        let feedURL = URL(string: rawFeedURL)!
        let data = try await URLSafety.boundedData(
            from: feedURL,
            maxBytes: URLSafety.maxFeedBytes,
            timeout: 30
        )

        // Parse via simple XML extractor — we only need title, entry count,
        // and one thumbnail URL.
        let (title, entryCount, firstThumbURL) = Self.parseRSSPreview(data: data)

        return ChannelPreview(
            channelID: channelID,
            title: title,
            videoCount: entryCount,
            videoCountIsLowerBound: true,
            artworkURL: firstThumbURL
        )
    }

    // MARK: - Enumerate videos

    /// Enumerate a channel's videos via yt-dlp.
    ///
    /// Runs:
    /// ```
    /// yt-dlp --flat-playlist --dump-json [--playlist-end <limit>]
    ///         [--dateafter <YYYYMMDD>]
    ///         https://www.youtube.com/channel/<channelID>/videos
    /// ```
    /// stdout is one JSON object per line; each line is parsed into a video dict
    /// and passed through `YouTubeManifest.fromVideos` for canonical entries.
    ///
    /// - Parameters:
    ///   - channelID: The `UC…` channel id.
    ///   - limit: Optional `--playlist-end` cap.
    ///   - dateAfter: Optional `--dateafter` filter in `"YYYY-MM-DD"` format.
    ///     Converted to `YYYYMMDD` for yt-dlp.  Note: with `--flat-playlist`
    ///     yt-dlp does NOT filter by date server-side — all entries are returned
    ///     and the flag is effectively a no-op in this mode.  Pass `full: true`
    ///     (not yet wired) to get real date filtering.
    ///   - includeVideos: Whether to enumerate the `/videos` tab. Defaults to
    ///     `true`.
    ///   - includeShorts: Whether to also enumerate the `/shorts` tab and merge
    ///     its entries in (de-duplicated by `guid`, `/videos` entries take
    ///     priority). Defaults to `false`.
    /// - Returns: Array of manifest entries, `/videos` tab first (newest-first,
    ///   yt-dlp default order) followed by any unique `/shorts` tab entries.
    public func enumerateVideos(
        channelID: String,
        limit: Int? = nil,
        dateAfter: String? = nil,
        includeVideos: Bool = true,
        includeShorts: Bool = false
    ) async throws -> [YouTubeManifest.Entry] {
        var videos: [YouTubeManifest.Entry] = []
        var shorts: [YouTubeManifest.Entry] = []
        if includeVideos {
            videos = try await enumerateTab(
                url: Self.channelVideosURL(channelID: channelID),
                limit: limit,
                dateAfter: dateAfter
            )
        }
        if includeShorts {
            shorts = try await enumerateTab(
                url: Self.channelShortsURL(channelID: channelID),
                limit: limit,
                dateAfter: dateAfter
            )
        }
        return YouTubeManifest.mergeEntries(videos: videos, shorts: shorts)
    }

    /// Enumerate a single channel tab (`/videos` or `/shorts`) via yt-dlp.
    ///
    /// Runs:
    /// ```
    /// yt-dlp --flat-playlist --dump-json [--playlist-end <limit>]
    ///         [--dateafter <YYYYMMDD>] <url>
    /// ```
    /// stdout is one JSON object per line; each line is parsed into a video dict
    /// and passed through `YouTubeManifest.fromVideos` for canonical entries.
    private func enumerateTab(
        url: String,
        limit: Int?,
        dateAfter: String?
    ) async throws -> [YouTubeManifest.Entry] {
        var args = ["--flat-playlist", "--dump-json"]
        if let limit {
            args += ["--playlist-end", String(limit)]
        }
        if let dateAfter {
            // yt-dlp wants YYYYMMDD; callers pass YYYY-MM-DD
            let compact = dateAfter.replacingOccurrences(of: "-", with: "")
            args += ["--dateafter", compact]
        }
        // "--" terminates option parsing so the URL can never be misread as a flag.
        args.append("--")
        args.append(url)

        let out = try await runYtDlp(args, timeout: 300)
        let dicts = try Self.parseJSONLines(out)
        return YouTubeManifest.fromVideos(dicts)
    }

    // MARK: - Pure helpers (testable without IO)

    /// Return the `UC…` channel id from the first matching line in yt-dlp output.
    ///
    /// Port of `_first_channel_id` from `core/youtube_meta.py`.
    /// Returns `nil` when no valid id is found (e.g. every line is "NA" or junk).
    public static func firstChannelID(in output: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"^UC[\w-]{22}$"#)
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if pattern.firstMatch(in: trimmed, range: range) != nil {
                return trimmed
            }
        }
        return nil
    }

    /// Build the channel videos tab URL for a given channel id.
    ///
    /// Uses the `/videos` tab which excludes Shorts.
    public static func channelVideosURL(channelID: String) -> String {
        "https://www.youtube.com/channel/\(channelID)/videos"
    }

    /// Build the channel shorts tab URL for a given channel id.
    ///
    /// Uses the `/shorts` tab, which lists only Shorts.
    public static func channelShortsURL(channelID: String) -> String {
        "https://www.youtube.com/channel/\(channelID)/shorts"
    }

    /// Parse yt-dlp's `--dump-json` stdout (one JSON object per line) into an
    /// array of heterogeneous video dicts for `YouTubeManifest.fromVideos`.
    ///
    /// Blank lines are skipped; non-parseable lines are skipped with a debug note.
    public static func parseJSONLines(_ output: String) throws -> [[String: JSONValue]] {
        var result: [[String: JSONValue]] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
                // skip unparseable lines (yt-dlp sometimes emits progress/warning lines)
                continue
            }
            result.append(dict)
        }
        return result
    }

    /// Parse a YouTube RSS feed for the channel title, entry count, and first
    /// video thumbnail URL.
    ///
    /// Returns `("", 0, "")` on parse failure.
    public static func parseRSSPreview(data: Data) -> (title: String, entryCount: Int, firstThumbURL: String) {
        let parser = RSSPreviewXMLParser(data: data)
        return parser.parse()
    }

    // MARK: - Private helpers

    /// Convert a parsed YouTubeURL into a URL string suitable for yt-dlp.
    private func resolveURL(for parsed: YouTubeURL) -> String {
        switch parsed.kind {
        case .channelID:
            // Should have been handled above, but cover it here for safety.
            return "https://www.youtube.com/channel/\(parsed.value)"
        case .handle:
            return "https://www.youtube.com/@\(parsed.value)"
        case .channelURL:
            // value is already a full URL (e.g., https://www.youtube.com/@handle or /c/name)
            return parsed.value
        case .video:
            return "https://www.youtube.com/watch?v=\(parsed.value)"
        case .playlist:
            return "https://www.youtube.com/playlist?list=\(parsed.value)"
        }
    }

    /// Run yt-dlp with the given arguments. Throws typed errors.
    ///
    /// Single choke point for every yt-dlp invocation in this type — prepends
    /// ``YtDlp/hardenedBaseArgs`` (L-3) here so both call sites
    /// (`resolveChannelID` and `enumerateTab`) are covered without needing to
    /// remember it at each call site.
    private func runYtDlp(_ args: [String], timeout: TimeInterval) async throws -> String {
        guard let ytdlpPath = binaryManager.resolvedPath(for: .ytDlp) else {
            throw YouTubeResolverError.ytdlpMissing
        }
        let result = try await subprocess.run(ytdlpPath, YtDlp.hardenedBaseArgs + args, timeout: timeout)
        if result.exitCode != 0 {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw YouTubeResolverError.ytdlpFailed(msg.isEmpty ? "yt-dlp exited \(result.exitCode)" : msg)
        }
        return result.stdout
    }
}

// MARK: - RSSPreviewXMLParser

/// Lightweight `XMLParser` delegate that extracts channel title, entry count,
/// and the first `<media:thumbnail url="…">` from a YouTube Atom feed.
///
/// YouTube channel feeds conform to Atom (`<feed>` root) with media namespace.
/// We need only three things:
///   1. `<title>` of the feed itself (not entries).
///   2. Count of `<entry>` elements.
///   3. `url` attribute of the first `<media:thumbnail>` inside the first entry.
private final class RSSPreviewXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private let data: Data

    private var feedTitle = ""
    private var entryCount = 0
    private var firstThumbURL = ""

    private var inFeedTitle = false
    private var inEntry = false
    private var capturedFirstThumb = false
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> (title: String, entryCount: Int, firstThumbURL: String) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return (feedTitle, entryCount, firstThumbURL)
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "entry":
            entryCount += 1
            inEntry = true

        case "title":
            if !inEntry {
                // The feed-level <title> (not inside an <entry>)
                inFeedTitle = true
                currentText = ""
            }

        case "media:thumbnail", "thumbnail":
            // Only capture the first thumbnail (from the first entry)
            if inEntry && !capturedFirstThumb, let url = attributes["url"], !url.isEmpty {
                firstThumbURL = url
                capturedFirstThumb = true
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inFeedTitle {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "title":
            if inFeedTitle {
                feedTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                inFeedTitle = false
                currentText = ""
            }
        case "entry":
            inEntry = false
        default:
            break
        }
    }
}
