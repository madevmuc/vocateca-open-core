import Foundation

// MARK: - RefreshedMetadata

/// The refreshed metadata for a single show returned by ``MetadataRefresher``.
///
/// A `nil` or empty value means "no data available — do NOT overwrite the
/// existing value in the watchlist". Callers should only persist non-nil,
/// non-empty fields.
public struct RefreshedMetadata: Sendable, Equatable {
    /// Channel / account display name. nil/empty = don't overwrite.
    public var title: String?
    /// Author / publisher name. nil/empty = don't overwrite.
    public var author: String?
    /// Artwork URL string. nil/empty = don't overwrite.
    public var artworkURL: String?
    /// Platform handle (e.g. YouTube @handle, Instagram handle without @).
    /// nil when not applicable or not resolvable.
    public var handle: String?

    public init(title: String?, author: String?, artworkURL: String?, handle: String?) {
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.handle = handle
    }
}

// MARK: - MetadataRefresher

/// Fetches fresh metadata for a single show from its origin source.
///
/// ## Dispatch rules
/// - `"podcast"` — fetch the RSS feed via ``URLSafety`` (SSRF guard + byte cap)
///   and parse title/author/artwork from the channel-level elements.
/// - `"youtube"` — use ``YouTubeResolver`` to obtain a ``ChannelPreview`` that
///   carries the channel title and thumbnail URL. Handle is extracted from the
///   feed URL using ``YouTubeURL``.
/// - `"instagram"` — **NO network**. Handle is derived purely from `show.rss`
///   via ``InstagramURL``. artworkURL is always nil.
///
/// All network operations respect ``URLSafety.safeURL`` and
/// ``URLSafety.boundedData`` — raw `URLSession.shared.data` is never used.
public enum MetadataRefresher {

    private static let component = "MetadataRefresher"

    /// Fetch fresh metadata for one show from its origin.
    ///
    /// Network is used only for podcast and YouTube sources.
    /// Instagram is a pure, synchronous derivation (no network).
    ///
    /// - Parameters:
    ///   - show: The watchlist show to re-fetch metadata for.
    ///   - youtubeResolver: Injected resolver (default `YouTubeResolver()`).
    /// - Returns: A ``RefreshedMetadata`` value; nil/empty fields mean
    ///   "no new value — keep existing".
    /// - Throws: Network / parsing errors for podcast and YouTube sources.
    ///   Never throws for the Instagram branch.
    public static func fetch(
        for show: Show,
        youtubeResolver: YouTubeResolver = YouTubeResolver()
    ) async throws -> RefreshedMetadata {
        Log.debug("fetch started",
                  component: component,
                  context: [("slug", show.slug), ("source", show.source)])

        switch show.source {
        case "podcast":
            return try await fetchPodcastMetadata(show: show)
        case "youtube":
            return try await fetchYouTubeMetadata(show: show, resolver: youtubeResolver)
        case "instagram":
            return fetchInstagramMetadata(show: show)
        default:
            Log.warn("unknown source — skipping",
                     component: component,
                     context: [("slug", show.slug), ("source", show.source)])
            return RefreshedMetadata(title: nil, author: nil, artworkURL: nil, handle: nil)
        }
    }

    // MARK: - Podcast

    /// Fetch RSS feed and parse channel-level title/author/artwork.
    private static func fetchPodcastMetadata(show: Show) async throws -> RefreshedMetadata {
        Log.info("fetching podcast feed",
                 component: component,
                 context: [("slug", show.slug), ("url", show.rss)])

        // SSRF guard: validate before fetching.
        do {
            try URLSafety.safeURL(show.rss)
        } catch {
            Log.error("podcast URL safety violation",
                      component: component,
                      context: [("slug", show.slug), ("url", show.rss), ("error", "\(error)")])
            throw error
        }

        guard let feedURL = URL(string: show.rss) else {
            Log.error("malformed podcast feed URL",
                      component: component,
                      context: [("slug", show.slug), ("url", show.rss)])
            throw URLError(.badURL)
        }

        let data = try await URLSafety.boundedData(
            from: feedURL,
            maxBytes: URLSafety.maxFeedBytes,
            timeout: 30
        )

        Log.debug("podcast feed fetched",
                  component: component,
                  context: [("slug", show.slug), ("bytes", "\(data.count)")])

        let title   = RSSManifest.parseFeedTitle(fromXML: data)
        let author  = RSSManifest.parseFeedAuthor(fromXML: data)
        let artwork = RSSManifest.parseFeedArtwork(fromXML: data)

        Log.info("podcast metadata parsed",
                 component: component,
                 context: [
                     ("slug",    show.slug),
                     ("title",   title.isEmpty   ? "(empty)" : title),
                     ("author",  author.isEmpty  ? "(empty)" : author),
                     ("artwork", artwork.isEmpty ? "(empty)" : artwork),
                 ])

        return RefreshedMetadata(
            title:      title.isEmpty   ? nil : title,
            author:     author.isEmpty  ? nil : author,
            artworkURL: artwork.isEmpty ? nil : artwork,
            handle:     nil
        )
    }

    // MARK: - YouTube

    /// Use YouTubeResolver to get channel title + thumbnail; derive @handle from feed URL.
    private static func fetchYouTubeMetadata(
        show: Show,
        resolver: YouTubeResolver
    ) async throws -> RefreshedMetadata {
        Log.info("resolving YouTube channel",
                 component: component,
                 context: [("slug", show.slug), ("url", show.rss)])

        let channelID = try await resolver.resolveChannelID(from: show.rss)
        Log.debug("YouTube channel ID resolved",
                  component: component,
                  context: [("slug", show.slug), ("channelID", channelID)])

        let preview = try await resolver.channelPreview(channelID: channelID)
        Log.info("YouTube channel preview fetched",
                 component: component,
                 context: [
                     ("slug",    show.slug),
                     ("title",   preview.title),
                     ("artwork", preview.artworkURL.isEmpty ? "(empty)" : preview.artworkURL),
                 ])

        // Derive the @handle from the RSS/feed URL if possible.
        let handle: String?
        if let parsed = try? YouTubeURL.parse(show.rss) {
            switch parsed.kind {
            case .handle:
                handle = parsed.value
                Log.debug("YouTube handle derived from URL",
                          component: component,
                          context: [("slug", show.slug), ("handle", parsed.value)])
            default:
                handle = nil
            }
        } else {
            handle = nil
        }

        return RefreshedMetadata(
            title:      preview.title.isEmpty      ? nil : preview.title,
            author:     preview.title.isEmpty      ? nil : preview.title,  // channel name is the author
            artworkURL: preview.artworkURL.isEmpty ? nil : preview.artworkURL,
            handle:     handle
        )
    }

    // MARK: - Instagram (pure — no network)

    /// Derive @handle from the show's rss field. No network calls.
    private static func fetchInstagramMetadata(show: Show) -> RefreshedMetadata {
        Log.debug("deriving Instagram handle (no network)",
                  component: component,
                  context: [("slug", show.slug), ("rss", show.rss)])

        guard let parsed = try? InstagramURL.parse(show.rss) else {
            Log.warn("could not parse Instagram handle from rss field",
                     component: component,
                     context: [("slug", show.slug), ("rss", show.rss)])
            return RefreshedMetadata(title: nil, author: nil, artworkURL: nil, handle: nil)
        }

        // For profile/story kinds: value is the handle (lowercase).
        // For reel/post kinds: value is a shortcode — not a handle, so skip.
        let handle: String?
        switch parsed.kind {
        case .profile, .story:
            handle = parsed.value
        case .reel, .post:
            handle = nil
            Log.debug("Instagram URL is a reel/post shortcode — no handle",
                      component: component,
                      context: [("slug", show.slug)])
        }

        Log.info("Instagram metadata derived",
                 component: component,
                 context: [("slug", show.slug), ("handle", handle ?? "(none)")])

        // Title = handle (without @) if we have one; otherwise nil.
        return RefreshedMetadata(
            title:      handle,
            author:     nil,     // author populated by updateMetadata from handle
            artworkURL: nil,
            handle:     handle
        )
    }
}
