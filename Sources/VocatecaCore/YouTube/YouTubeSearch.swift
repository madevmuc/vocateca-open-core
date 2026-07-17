import Foundation

// MARK: - Search hits

/// One channel from a YouTube channel search.
public struct YouTubeChannelHit: Sendable, Equatable, Identifiable, Hashable {

    /// The opaque `UC…` channel id.
    public let channelID: String

    /// The channel's display name, e.g. "Andrew Huberman".
    public let name: String

    /// The `@handle` form (yt-dlp's `uploader_id`), e.g. "@hubermanlab". `nil`
    /// when the search page didn't carry one.
    public let handle: String?

    /// Subscriber count. This is the only thing that tells four near-identically
    /// named channels apart, so it is surfaced in the result row rather than
    /// hidden in a detail pane. `nil` when the channel hides it.
    public let subscriberCount: Int?

    /// Channel avatar, `https`-normalised (the search page emits protocol-relative
    /// `//yt3.ggpht.com/…` URLs). `nil` when absent.
    public let thumbnailURL: String?

    /// Canonical channel URL — what a subscribe hands to the existing add path.
    public let channelURL: String

    /// The channel's one-line blurb from the search page. `nil` when absent.
    public let description: String?

    /// Whether YouTube marks this channel as verified.
    public let isVerified: Bool

    public var id: String { channelID }

    public init(
        channelID: String, name: String, handle: String? = nil,
        subscriberCount: Int? = nil, thumbnailURL: String? = nil,
        channelURL: String, description: String? = nil, isVerified: Bool = false
    ) {
        self.channelID = channelID
        self.name = name
        self.handle = handle
        self.subscriberCount = subscriberCount
        self.thumbnailURL = thumbnailURL
        self.channelURL = channelURL
        self.description = description
        self.isVerified = isVerified
    }
}

/// One video from a YouTube video search.
public struct YouTubeVideoHit: Sendable, Equatable, Identifiable, Hashable {

    public let videoID: String
    public let title: String

    /// The uploading channel's display name. `nil` when absent.
    public let channelName: String?

    /// The uploading channel's URL — lets "subscribe to the channel instead"
    /// work straight from a video hit.
    public let channelURL: String?

    /// Runtime in seconds. `nil` for a live stream or when absent.
    public let duration: Double?

    public let viewCount: Int?

    /// Video thumbnail, `https`-normalised. `nil` when absent.
    public let thumbnailURL: String?

    /// The canonical `watch?v=` URL.
    public var videoURL: String { "https://www.youtube.com/watch?v=\(videoID)" }

    public var id: String { videoID }

    public init(
        videoID: String, title: String, channelName: String? = nil,
        channelURL: String? = nil, duration: Double? = nil, viewCount: Int? = nil,
        thumbnailURL: String? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.channelURL = channelURL
        self.duration = duration
        self.viewCount = viewCount
        self.thumbnailURL = thumbnailURL
    }
}

// MARK: - YouTubeSearching

/// A thin seam over the yt-dlp-backed search, mirroring ``CaptionFetching`` and
/// ``YouTubeVideoMetadataFetching``: gives the UI something to fake in tests
/// without a `Process` dependency.
///
/// Neither method throws. A failure — yt-dlp missing, non-zero exit, timeout,
/// YouTube changing its markup — yields an empty array. The caller shows an empty
/// YouTube group; it must never take the whole screen down with it.
public protocol YouTubeSearching: Sendable {
    func searchChannels(query: String, limit: Int) async -> [YouTubeChannelHit]
    func searchVideos(query: String, limit: Int) async -> [YouTubeVideoHit]

    /// A channel's most recent uploads — what the preview shows once a channel
    /// hit is selected, so "is this the right Huberman" can be answered by
    /// looking at what they actually publish.
    func latestVideos(channelURL: String, limit: Int) async -> [YouTubeVideoHit]
}

// MARK: - YtDlpYouTubeSearchService

/// Searches YouTube through the bundled yt-dlp — no API key, no account, nothing
/// for the user to configure.
///
/// Two different entry points, because yt-dlp only has a search *extractor* for
/// videos:
///
/// - **Videos** use `ytsearch<N>:<query>`, a first-class yt-dlp feature.
/// - **Channels** have no equivalent, so this drives the ordinary results page
///   with YouTube's own "channels only" filter (`sp=EgIQAg%3D%3D`).
///
/// ## The `sp` parameter is not a contract
///
/// `sp=EgIQAg` is an opaque, protobuf-ish parameter of YouTube's *web interface*.
/// Nobody promised it will keep meaning "channels only", and it can start
/// returning videos — or nothing — without warning, on a day when direct channel
/// links still work perfectly. That asymmetry is the reason every failure here is
/// silent and local: the caller keeps its other ways of adding a channel, and a
/// broken search costs the user a search box, not the screen.
///
/// ## Cost
///
/// Each call is one yt-dlp exec against the live site: measured ~12–16 s per
/// search on a warm connection, dominated by yt-dlp's own start-up. That is why
/// the UI searches on Return rather than per keystroke, and why the two searches
/// run concurrently instead of one after the other.
public struct YtDlpYouTubeSearchService: YouTubeSearching {

    private let binaryManager: BinaryManager
    private let subprocess: Subprocess
    private let timeout: TimeInterval

    /// - Parameter timeout: hard wall-clock cap per search. 45 s: a measured
    ///   search is ~12–16 s, but yt-dlp's cold start is the dominant term and
    ///   gets much worse under endpoint-security scanning, so the cap has to
    ///   leave real headroom or it fires on slow Macs rather than on failures.
    public init(
        binaryManager: BinaryManager = BinaryManager(),
        subprocess: Subprocess = Subprocess(),
        timeout: TimeInterval = 45
    ) {
        self.binaryManager = binaryManager
        self.subprocess = subprocess
        self.timeout = timeout
    }

    // MARK: - Channels

    public func searchChannels(query: String, limit: Int = 8) async -> [YouTubeChannelHit] {
        guard let target = Self.channelSearchURL(query: query) else { return [] }
        // The query is never logged: people search for their own health, legal and
        // financial questions, and a transcript tool's log has no business holding
        // that. Only the kind of search and the shape of the result are recorded —
        // same rule AddRouter's fast-path detection follows.
        guard let json = await run(target: target, limit: limit, kind: "channels") else { return [] }
        return Self.parseChannelSearch(json, limit: limit)
    }

    // MARK: - Videos

    public func searchVideos(query: String, limit: Int = 8) async -> [YouTubeVideoHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        // `ytsearch<N>:<query>` is a yt-dlp pseudo-URL, not an http(s) one, so it
        // cannot go through URLSafety.safeURL. It is safe by construction instead:
        // the prefix is a literal, N is an Int, and the whole token is passed after
        // `--`, so a query starting with "-" can never be read as a flag.
        guard let json = await run(target: "ytsearch\(limit):\(trimmed)", limit: limit, kind: "videos") else {
            return []
        }
        return Self.parseVideoSearch(json, limit: limit)
    }

    // MARK: - A channel's latest uploads

    /// Lists a channel's most recent uploads.
    ///
    /// Drives the `/videos` tab of the channel rather than the channel root: the
    /// root is a curated page (featured video, shelves, sometimes a trailer) and
    /// its flat-playlist output is not "the latest N uploads" in any dependable
    /// order.
    ///
    /// **What this does NOT return:** `--flat-playlist` on `/videos` leaves
    /// `view_count` and `timestamp` empty (verified against the live site
    /// 2026-07-17). The preview therefore cannot honestly show "2 days ago" or a
    /// view count for these rows — only the title and the runtime. Filling those
    /// in would need one extra yt-dlp exec per video, which is ~12 s each.
    public func latestVideos(channelURL: String, limit: Int = 3) async -> [YouTubeVideoHit] {
        guard limit > 0, let target = Self.uploadsURL(forChannelURL: channelURL) else { return [] }
        guard let json = await run(target: target, limit: limit, kind: "channel-uploads") else { return [] }
        return Self.parseVideoSearch(json, limit: limit)
    }

    /// `…/channel/UC…` → `…/channel/UC…/videos`. Returns `nil` for an unsafe or
    /// non-YouTube URL, and is idempotent if the URL already points at `/videos`.
    static func uploadsURL(forChannelURL channelURL: String) -> String? {
        let trimmed = channelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let safe = try? URLSafety.safeURL(trimmed),
              let host = URLComponents(string: safe)?.host?.lowercased(),
              host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com"
        else { return nil }
        var base = safe
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/videos") { return base }
        return base + "/videos"
    }

    // MARK: - The one exec both searches share

    private func run(target: String, limit: Int, kind: String) async -> String? {
        guard let ytdlp = binaryManager.resolvedPath(for: .ytDlp) else {
            Log.warn("YouTube search: yt-dlp not available", component: "Search",
                     context: [("kind", kind)])
            return nil
        }

        let args = YtDlp.hardenedBaseArgs + [
            "--flat-playlist",          // metadata only — never resolve each hit
            "--no-warnings",
            "--playlist-end", "\(limit)",
            "-J",                       // one JSON object for the whole result page
            "--", target,
        ]

        let start = Date()
        Log.info("YouTube search started", component: "Search", context: [("kind", kind)])

        do {
            let result = try await subprocess.run(ytdlp, args, timeout: timeout)
            guard result.exitCode == 0 else {
                Log.warn("YouTube search failed", component: "Search",
                         context: [("kind", kind), ("exit", "\(result.exitCode)"),
                                   ("ms", "\(Int(Date().timeIntervalSince(start) * 1000))")])
                return nil
            }
            return result.stdout
        } catch is CancellationError {
            // The user typed a new query, or left. Not a failure worth a warning.
            Log.debug("YouTube search cancelled", component: "Search", context: [("kind", kind)])
            return nil
        } catch {
            Log.warn("YouTube search errored", component: "Search",
                     context: [("kind", kind), ("error", "\(error)"),
                               ("ms", "\(Int(Date().timeIntervalSince(start) * 1000))")])
            return nil
        }
    }

    // MARK: - URL building (pure)

    /// Builds the results-page URL with YouTube's "channels only" filter.
    ///
    /// Returns `nil` for an empty query or one that cannot be percent-encoded —
    /// and runs the result through `URLSafety.safeURL`, so this stays consistent
    /// with every other outbound URL in the pipeline even though the host is a
    /// constant we wrote ourselves.
    static func channelSearchURL(query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [
            URLQueryItem(name: "search_query", value: trimmed),
            // "channels only". Opaque and unpromised — see the type's docs.
            URLQueryItem(name: "sp", value: "EgIQAg=="),
        ]
        guard let url = components?.url?.absoluteString,
              let safe = try? URLSafety.safeURL(url) else { return nil }
        return safe
    }

    // MARK: - Parsing (pure, no I/O — tested against checked-in fixtures)

    /// Parses `yt-dlp --flat-playlist -J` output from a channels-filtered results
    /// page into ``YouTubeChannelHit``s.
    ///
    /// Entries without a `channel_id` are dropped: that is what a `sp=EgIQAg` that
    /// has stopped meaning "channels only" looks like (video entries come back
    /// instead), and a video masquerading as a channel is worse than one hit fewer.
    static func parseChannelSearch(_ json: String, limit: Int = .max) -> [YouTubeChannelHit] {
        entries(in: json).compactMap { entry -> YouTubeChannelHit? in
            guard let channelID = string(entry["channel_id"]), !channelID.isEmpty else { return nil }
            let name = string(entry["channel"]) ?? string(entry["uploader"]) ?? string(entry["title"]) ?? ""
            guard !name.isEmpty else { return nil }
            let url = string(entry["channel_url"])
                ?? string(entry["url"])
                ?? "https://www.youtube.com/channel/\(channelID)"
            return YouTubeChannelHit(
                channelID: channelID,
                name: name,
                handle: presentOrNil(string(entry["uploader_id"])),
                subscriberCount: int(entry["channel_follower_count"]),
                thumbnailURL: bestThumbnail(entry["thumbnails"]),
                channelURL: url,
                description: presentOrNil(string(entry["description"])),
                isVerified: bool(entry["channel_is_verified"]) ?? false
            )
        }
        .prefix(limit)
        .reduce(into: []) { $0.append($1) }
    }

    /// Parses `yt-dlp --flat-playlist -J` output from `ytsearch<N>:` into
    /// ``YouTubeVideoHit``s. Entries without an `id` are dropped.
    static func parseVideoSearch(_ json: String, limit: Int = .max) -> [YouTubeVideoHit] {
        entries(in: json).compactMap { entry -> YouTubeVideoHit? in
            guard let videoID = string(entry["id"]), !videoID.isEmpty else { return nil }
            return YouTubeVideoHit(
                videoID: videoID,
                title: string(entry["title"]) ?? "",
                channelName: presentOrNil(string(entry["channel"]) ?? string(entry["uploader"])),
                channelURL: presentOrNil(string(entry["channel_url"])),
                duration: double(entry["duration"]),
                viewCount: int(entry["view_count"]),
                thumbnailURL: bestThumbnail(entry["thumbnails"])
            )
        }
        .prefix(limit)
        .reduce(into: []) { $0.append($1) }
    }

    // MARK: - JSON helpers

    /// The `entries` array of a `-J` playlist object, or `[]` for anything
    /// unparsable (empty output, an error page, a future yt-dlp that renames the
    /// key). Never throws — an unreadable answer is the same as no answer.
    private static func entries(in json: String) -> [[String: JSONValue]] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(let list)? = root["entries"]
        else { return [] }
        return list.compactMap { value in
            guard case .object(let dict) = value else { return nil }
            return dict
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    private static func presentOrNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "NA" else { return nil }
        return s
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let n)?: return n
        case .string(let s)?: return Double(s)   // yt-dlp sometimes emits numbers as strings
        default:              return nil
        }
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard let d = double(value) else { return nil }
        return Int(d)
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let b)?:   return b
        case .number(let n)?: return n != 0
        default:              return nil
        }
    }

    /// Picks the largest thumbnail and normalises its scheme.
    ///
    /// The channel search returns protocol-relative URLs (`//yt3.ggpht.com/…`),
    /// which `URL(string:)` accepts and then fails to load from. The video search
    /// returns absolute `https://i.ytimg.com/…` ones. Both have to come out of
    /// here as something loadable.
    static func bestThumbnail(_ value: JSONValue?) -> String? {
        guard case .array(let list)? = value else { return nil }
        var best: (url: String, area: Double)?
        for item in list {
            guard case .object(let dict) = item,
                  let raw = presentOrNil(string(dict["url"])) else { continue }
            let area = (double(dict["width"]) ?? 0) * (double(dict["height"]) ?? 0)
            if best == nil || area > best!.area { best = (raw, area) }
        }
        guard let url = best?.url else { return nil }
        return normalisedThumbnailURL(url)
    }

    /// `//host/path` → `https://host/path`; everything else is passed through.
    static func normalisedThumbnailURL(_ url: String) -> String {
        url.hasPrefix("//") ? "https:" + url : url
    }
}
