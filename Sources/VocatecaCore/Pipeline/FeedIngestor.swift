import Foundation

// MARK: - FeedIngestorError

/// Errors thrown by ``FeedIngestor/poll(show:store:)``.
public enum FeedIngestorError: Error, Sendable {
    /// The show is in feed backoff; no poll was performed.
    case inBackoff
    /// The show is disabled (`Show.enabled == false`).
    case showDisabled
    /// The show's `source` is not supported by this ingestor.
    case unsupportedSource(String)
    /// A network or parse error occurred during the poll.
    case fetchFailed(Error)
}

// MARK: - PollResult

/// The result of a single ``FeedIngestor/poll(show:store:)`` call.
///
/// Wraps the previously-returned `[NewEpisode]` array with an optional
/// ``RSSManifest/ChannelMeta`` so callers can persist the show's real
/// title/author/artwork (the metadata-refresh fix) without a second network
/// fetch — `channelMeta` is parsed from the SAME feed bytes already fetched
/// to build the episode list.
///
/// `channelMeta` is `nil` for sources that don't yield channel-level metadata
/// from the poll itself (YouTube/ytdlp/local — see ``FeedIngestor/poll(show:store:)``
/// doc for why YouTube doesn't do a second fetch just to get this).
public struct PollResult: Sendable {
    /// Episodes newly inserted during this poll (see ``FeedIngestor/poll(show:store:)``).
    public let episodes: [NewEpisode]
    /// Channel-level metadata parsed from the already-fetched feed, when available.
    public let channelMeta: RSSManifest.ChannelMeta?

    public init(episodes: [NewEpisode], channelMeta: RSSManifest.ChannelMeta?) {
        self.episodes = episodes
        self.channelMeta = channelMeta
    }
}

// MARK: - FeedIngestor

/// Polls a show's feed source and upserts new episodes into the state database.
///
/// ## Supported sources
/// - `"podcast"` — fetches the RSS/Atom feed at `show.rss` and upserts via
///   `StateStore.upsertEpisodeFromFeed`.
/// - `"youtube"` — resolves the channel URL at `show.rss` via `YouTubeResolver`,
///   enumerates videos (capped at `youtubeLimit`), and upserts each.
/// - `"instagram"` — out of scope for WP-3 (WP-5 owns enumeration). No-op with
///   an `unsupportedSource` error unless `skipInstagram` is set (in which case
///   it returns 0 silently, used for testing mixed-show watchlists).
///
/// ## Backoff
/// Before polling, `FeedBackoff.inBackoff` is consulted. If the feed is in
/// backoff, the call returns immediately with `inBackoff` error. On success,
/// `FeedBackoff.onSuccess` is called. On any fetch/parse error,
/// `FeedBackoff.onFailure` is called (backoff state escalates).
///
/// ## Thread safety
/// `FeedIngestor` is `Sendable` (all state is injected; the struct has no mutable
/// state of its own). It is safe to call from any actor or task.
public struct FeedIngestor: Sendable {

    // MARK: - Configuration

    /// Maximum number of videos to enumerate from a YouTube channel per poll.
    /// Keeps the first poll of large channels fast.
    public let youtubeLimit: Int

    /// The YouTube resolver used for `source == "youtube"`.
    public let youtubeResolver: YouTubeResolver

    /// When non-nil, author backfill writes are persisted to this URL via WatchlistStore.
    /// Pass `Paths.watchlistURL` in production; leave nil in tests to skip the write.
    public let watchlistURL: URL?

    // MARK: - Init

    public init(
        youtubeLimit: Int = 50,
        youtubeResolver: YouTubeResolver = YouTubeResolver(),
        watchlistURL: URL? = nil
    ) {
        self.youtubeLimit = youtubeLimit
        self.youtubeResolver = youtubeResolver
        self.watchlistURL = watchlistURL
    }

    // MARK: - poll

    /// Poll the show's feed and upsert any new/updated episodes.
    ///
    /// - Parameters:
    ///   - show:  The show to poll.
    ///   - store: The state store to upsert into.
    /// - Returns: A ``PollResult`` carrying the episodes that were **newly
    ///   inserted** during this poll (episodes already known are excluded;
    ///   empty when the queue is already up to date — callers that only need
    ///   the count can use `.episodes.count`) plus, for podcast sources, the
    ///   channel-level metadata (title/author/artwork) parsed from the SAME
    ///   feed bytes already fetched — no second network fetch. Callers should
    ///   persist non-nil `channelMeta` via ``WatchlistStore/updateMetadata(slug:metadata:to:)``
    ///   so "Refresh feed" replaces a slug-derived title with the real one.
    /// - Throws: ``FeedIngestorError`` or any underlying error.
    /// - Parameter newEpisodeStatus: The status a **freshly discovered** episode is
    ///   inserted with. Defaults to `.pending` (unchanged behaviour for every
    ///   existing caller/test). **L4:** the UI ingest coordinator passes `.deferred`
    ///   here for auto-download-OFF shows so the row is born in its final state —
    ///   never a transient `pending` a concurrent drain could claim. On a re-poll of
    ///   an existing row the status is preserved regardless (ON CONFLICT does not
    ///   touch it), so this only affects the first insert of a new episode.
    public func poll(
        show: Show,
        store: StateStore,
        newEpisodeStatus: EpisodeStatus = .pending
    ) async throws -> PollResult {
        guard show.enabled else {
            Log.debug("Poll skipped — show disabled",
                      component: "FeedIngestor", context: [("slug", show.slug)])
            throw FeedIngestorError.showDisabled
        }

        // Respect feed backoff — skip silently (caller decides whether to log).
        if (try? FeedBackoff.inBackoff(showSlug: show.slug, store: store)) == true {
            Log.debug("Poll skipped — in backoff",
                      component: "FeedIngestor", context: [("slug", show.slug)])
            throw FeedIngestorError.inBackoff
        }

        Log.info("Poll starting",
                 component: "FeedIngestor",
                 context: [("slug", show.slug),
                            ("source", show.source),
                            ("feed", show.rss)])

        switch show.source {
        case "podcast":
            return try await pollPodcast(show: show, store: store, newEpisodeStatus: newEpisodeStatus)
        case "youtube":
            return try await pollYouTube(show: show, store: store, newEpisodeStatus: newEpisodeStatus)
        case "instagram":
            // Instagram enumeration is owned by WP-5 (InstagramEnumerator).
            // FeedIngestor only handles RSS + YouTube + ytdlp polling.
            Log.debug("Poll skipped — instagram not handled by FeedIngestor (WP-5)",
                      component: "FeedIngestor", context: [("slug", show.slug)])
            throw FeedIngestorError.unsupportedSource("instagram")
        case "local":
            // Local pseudo-shows are never polled — they are populated by
            // LocalIngestService (manual import) or AutomationRunner (FSEvents).
            Log.debug("Poll skipped — local pseudo-show is not pollable",
                      component: "FeedIngestor", context: [("slug", show.slug)])
            throw FeedIngestorError.unsupportedSource("local")
        case "ytdlp":
            return try await pollYtDlp(show: show, store: store, newEpisodeStatus: newEpisodeStatus)
        default:
            Log.warn("Poll skipped — unsupported source",
                     component: "FeedIngestor",
                     context: [("slug", show.slug), ("source", show.source)])
            throw FeedIngestorError.unsupportedSource(show.source)
        }
    }

    // MARK: - Podcast source

    private func pollPodcast(show: Show, store: StateStore, newEpisodeStatus: EpisodeStatus) async throws -> PollResult {
        // Validate and fetch the feed URL.
        let feedURLString: String
        do {
            feedURLString = try URLSafety.safeURL(show.rss)
        } catch {
            // Safety violation is a permanent error — don't backoff.
            Log.error("Podcast poll aborted — URL safety violation",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("url", show.rss), ("error", "\(error)")])
            throw FeedIngestorError.fetchFailed(error)
        }

        guard let feedURL = URL(string: feedURLString) else {
            Log.error("Podcast poll aborted — malformed feed URL",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("url", feedURLString)])
            throw FeedIngestorError.fetchFailed(
                FeedIngestorURLError.malformedURL(feedURLString)
            )
        }

        // Fetch the feed data with size cap.
        Log.debug("Fetching podcast feed",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("url", feedURL.absoluteString)])
        let data: Data
        do {
            data = try await URLSafety.boundedData(
                from: feedURL,
                maxBytes: URLSafety.maxFeedBytes,
                timeout: 60
            )
        } catch {
            // Network/fetch failure — record backoff.
            try? FeedBackoff.onFailure(showSlug: show.slug, store: store)
            Log.error("Podcast feed fetch failed",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("url", feedURL.absoluteString), ("error", "\(error)")])
            throw FeedIngestorError.fetchFailed(error)
        }
        Log.debug("Podcast feed fetched",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("bytes", "\(data.count)")])

        // Parse the feed.
        let entries: [ManifestEntry]
        let feedAuthor: String
        let channelMeta: RSSManifest.ChannelMeta
        do {
            entries = try RSSManifest.build(fromXML: data)
            feedAuthor = RSSManifest.parseFeedAuthor(fromXML: data)
            // Same already-fetched `data` — no second network fetch. Carries
            // title/artwork (in addition to description/language) so the
            // metadata-refresh fix (IngestCoordinator.ingest) can replace a
            // slug-derived display name with the feed's real channel title,
            // and populate artwork so Shows/Library/Queue stop falling back
            // to initials.
            channelMeta = RSSManifest.parseFeedChannelMeta(fromXML: data)
        } catch {
            // Parse failure — record backoff.
            try? FeedBackoff.onFailure(showSlug: show.slug, store: store)
            Log.error("Podcast feed parse failed",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("bytes", "\(data.count)"), ("error", "\(error)")])
            throw FeedIngestorError.fetchFailed(error)
        }
        Log.debug("Podcast feed parsed",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("entries", "\(entries.count)"), ("author", feedAuthor),
                             ("channelTitle", channelMeta.title.isEmpty ? "(empty)" : channelMeta.title),
                             ("channelArtwork", channelMeta.artworkURL.isEmpty ? "(empty)" : channelMeta.artworkURL)])

        // Backfill Show.author if not yet set and the feed carries a non-empty author.
        if show.author == nil || show.author?.isEmpty == true,
           !feedAuthor.isEmpty,
           let wlURL = watchlistURL {
            Log.debug("Backfilling podcast author",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("author", feedAuthor)])
            try? WatchlistStore.load(from: wlURL)
                .updateAuthor(slug: show.slug, author: feedAuthor, to: wlURL)
        }

        // Upsert each entry; collect freshly-inserted episodes.
        var newEpisodes: [NewEpisode] = []
        var existingCount = 0
        for entry in entries {
            let durationSec = Self.parseDurationSeconds(entry.duration)
            if let new = try store.upsertEpisodeFromFeed(
                showSlug: show.slug,
                guid: entry.guid,
                title: entry.title,
                pubDate: entry.pubDate,
                mp3URL: entry.mp3URL,
                durationSec: durationSec,
                initialStatus: newEpisodeStatus
            ) {
                newEpisodes.append(new)
                Log.debug("New episode upserted",
                          component: "FeedIngestor",
                          context: [("slug", show.slug), ("guid", entry.guid), ("title", entry.title)])
            } else {
                existingCount += 1
            }
        }

        Log.info("Podcast poll done",
                 component: "FeedIngestor",
                 context: [("slug", show.slug),
                            ("entries", "\(entries.count)"),
                            ("new", "\(newEpisodes.count)"),
                            ("existing", "\(existingCount)"),
                            ("db", Paths.stateDatabaseURL.path)])

        // Record success.
        try? FeedBackoff.onSuccess(showSlug: show.slug, store: store)
        return PollResult(episodes: newEpisodes, channelMeta: channelMeta)
    }

    // MARK: - YouTube source

    private func pollYouTube(show: Show, store: StateStore, newEpisodeStatus: EpisodeStatus) async throws -> PollResult {
        // Resolve the channel URL/handle to a channel ID.
        Log.debug("Resolving YouTube channel ID",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("input", show.rss)])
        let channelID: String
        do {
            channelID = try await youtubeResolver.resolveChannelID(from: show.rss)
        } catch {
            try? FeedBackoff.onFailure(showSlug: show.slug, store: store)
            Log.error("YouTube channel ID resolution failed",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("input", show.rss), ("error", "\(error)")])
            throw FeedIngestorError.fetchFailed(error)
        }
        Log.debug("YouTube channel resolved",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("channelID", channelID)])

        // Backfill Show.author with the YouTube @handle if not yet set.
        // The handle is the most useful "author" identifier for YouTube channels.
        if (show.author == nil || show.author?.isEmpty == true),
           let wlURL = watchlistURL {
            // Extract the handle from the original rss URL if available.
            let handle = Self.youTubeHandleFromInput(show.rss)
            if let handle = handle, !handle.isEmpty {
                Log.debug("Backfilling YouTube author",
                          component: "FeedIngestor",
                          context: [("slug", show.slug), ("handle", handle)])
                try? WatchlistStore.load(from: wlURL)
                    .updateAuthor(slug: show.slug, author: handle, to: wlURL)
            }
        }

        // Enumerate videos up to `youtubeLimit`.
        Log.debug("Enumerating YouTube videos",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("channelID", channelID), ("limit", "\(youtubeLimit)")])
        let videos: [YouTubeManifest.Entry]
        do {
            videos = try await youtubeResolver.enumerateVideos(
                channelID: channelID,
                limit: youtubeLimit,
                includeVideos: show.includeVideos,
                includeShorts: !show.skipShorts
            )
        } catch {
            try? FeedBackoff.onFailure(showSlug: show.slug, store: store)
            Log.error("YouTube video enumeration failed",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("channelID", channelID), ("error", "\(error)")])
            throw FeedIngestorError.fetchFailed(error)
        }
        Log.debug("YouTube videos enumerated",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("videos", "\(videos.count)")])

        // Upsert each video as an episode; collect freshly-inserted episodes.
        var newEpisodes: [NewEpisode] = []
        var existingCount = 0
        for video in videos {
            if let new = try store.upsertEpisodeFromFeed(
                showSlug: show.slug,
                guid: video.guid,
                title: video.title,
                pubDate: video.pubDate,
                mp3URL: video.mp3URL,
                durationSec: video.durationSec,
                initialStatus: newEpisodeStatus
            ) {
                newEpisodes.append(new)
                Log.debug("New YouTube video upserted",
                          component: "FeedIngestor",
                          context: [("slug", show.slug), ("guid", video.guid), ("title", video.title)])
            } else {
                existingCount += 1
            }
        }

        Log.info("YouTube poll done",
                 component: "FeedIngestor",
                 context: [("slug", show.slug),
                            ("videos", "\(videos.count)"),
                            ("new", "\(newEpisodes.count)"),
                            ("existing", "\(existingCount)"),
                            ("db", Paths.stateDatabaseURL.path)])

        // Record success.
        try? FeedBackoff.onSuccess(showSlug: show.slug, store: store)
        // No channelMeta: the yt-dlp `--print channel_id` resolve call and the
        // flat-playlist video enumeration never fetch a channel title/artwork
        // payload, and deliberately adding a fetch just for that would violate
        // the no-second-network-fetch constraint this fix is scoped to. YouTube
        // shows already get `author` backfilled from the parsed @handle above
        // (no fetch); a full channel-title/artwork refresh for YouTube is
        // tracked separately (Welle refresh-metadata's explicit "Settings ▸
        // refresh all metadata" flow already covers it via MetadataRefresher).
        return PollResult(episodes: newEpisodes, channelMeta: nil)
    }

    // MARK: - yt-dlp generic source

    /// Polls a generic yt-dlp playlist/channel URL and upserts new entries.
    ///
    /// Runs `yt-dlp --flat-playlist --dump-json` via ``MediaURLResolver`` and
    /// upserts each entry as a pending episode. The `mp3_url` is the entry's
    /// webpage URL; ``URLSessionDownloader`` routes non-direct-media URLs to
    /// the yt-dlp audio hook.
    ///
    /// Structurally mirrors the YouTube enumerate path, minus YouTube channel-ID
    /// resolution. Respects the W9 per-show auto-download gating.
    private func pollYtDlp(show: Show, store: StateStore, newEpisodeStatus: EpisodeStatus) async throws -> PollResult {
        let feedURL = show.rss
        guard !feedURL.isEmpty else {
            throw FeedIngestorError.unsupportedSource("ytdlp — empty rss URL")
        }

        Log.debug("ytdlp poll starting",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("url", feedURL)])

        let resolver = MediaURLResolver()
        let entries: [ResolvedEntry]
        do {
            entries = try await resolver.enumerate(url: feedURL, limit: youtubeLimit)
        } catch {
            try? FeedBackoff.onFailure(showSlug: show.slug, store: store)
            Log.error("ytdlp enumeration failed",
                      component: "FeedIngestor",
                      context: [("slug", show.slug), ("url", feedURL), ("error", "\(error)")])
            throw FeedIngestorError.fetchFailed(error)
        }

        Log.debug("ytdlp entries enumerated",
                  component: "FeedIngestor",
                  context: [("slug", show.slug), ("count", "\(entries.count)")])

        var newEpisodes: [NewEpisode] = []
        var existingCount = 0
        for entry in entries {
            // Build an episode URL: prefer the resolved URL, fall back to constructing
            // a canonical yt-dlp identifier via the entry id.
            let epURL = entry.url.isEmpty ? feedURL : entry.url
            let guid  = "ytdlp:\(entry.id)"
            if let new = try store.upsertEpisodeFromFeed(
                showSlug:    show.slug,
                guid:        guid,
                title:       entry.title,
                pubDate:     LocalIngestService.isoDate(from: Date()),
                mp3URL:      epURL,
                durationSec: nil,
                initialStatus: newEpisodeStatus
            ) {
                newEpisodes.append(new)
                Log.debug("New ytdlp entry upserted",
                          component: "FeedIngestor",
                          context: [("slug", show.slug), ("guid", guid)])
            } else {
                existingCount += 1
            }
        }

        Log.info("ytdlp poll done",
                 component: "FeedIngestor",
                 context: [("slug", show.slug),
                            ("entries", "\(entries.count)"),
                            ("new", "\(newEpisodes.count)"),
                            ("existing", "\(existingCount)")])

        try? FeedBackoff.onSuccess(showSlug: show.slug, store: store)
        // No channel-level metadata available from flat-playlist enumeration.
        return PollResult(episodes: newEpisodes, channelMeta: nil)
    }

    // MARK: - Duration parsing

    /// Parse an `<itunes:duration>` string into seconds.
    ///
    /// Formats accepted:
    /// - `"HH:MM:SS"` → hours*3600 + minutes*60 + seconds
    /// - `"MM:SS"`    → minutes*60 + seconds
    /// - `"NNN"`      → raw seconds (integer string)
    /// - `"00:00:00"` or empty → `nil`
    ///
    /// Returns `nil` when the value is absent, zero, or unparseable.
    static func parseDurationSeconds(_ duration: String) -> Int? {
        let trimmed = duration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 2).compactMap { Int($0) }
            let seconds: Int
            switch parts.count {
            case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: seconds = parts[0] * 60 + parts[1]
            default: return nil
            }
            return seconds > 0 ? seconds : nil
        } else {
            guard let seconds = Int(trimmed), seconds > 0 else { return nil }
            return seconds
        }
    }

    // MARK: - YouTube handle extraction

    /// Extracts the @handle from a YouTube channel URL/handle input, or nil.
    ///
    /// Returns the handle string (with leading `@`) when the input contains one,
    /// e.g. `"https://youtube.com/@veritasium"` → `"@veritasium"`.
    /// Returns nil for plain channel IDs or unrecognised forms.
    static func youTubeHandleFromInput(_ input: String) -> String? {
        guard let parsed = try? YouTubeURL.parse(input) else { return nil }
        switch parsed.kind {
        case .handle:
            return "@\(parsed.value)"
        case .channelURL:
            // channelURL value is the full URL; try to extract handle from path
            if let comps = URLComponents(string: parsed.value),
               comps.path.hasPrefix("/@") {
                let handle = String(comps.path.dropFirst(2)
                    .components(separatedBy: "/").first ?? "")
                return handle.isEmpty ? nil : "@\(handle)"
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Internal helper errors

private enum FeedIngestorURLError: Error {
    case malformedURL(String)
}
