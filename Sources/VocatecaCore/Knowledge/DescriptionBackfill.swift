import Foundation

// MARK: - DescriptionFetcher

/// Protocol for fetching an episode description from a provider.
///
/// Injected into ``DescriptionBackfill`` so tests can supply fakes without
/// network access. Production callers supply ``RSSDescriptionFetcher`` (podcasts),
/// ``YouTubeDescriptionFetcher`` (YouTube), or a stub for Instagram.
public protocol DescriptionFetcher: Sendable {
    /// Fetches the description for `episode`, or returns `nil` when unavailable.
    ///
    /// - Returns: The description string, or `nil` when the fetcher cannot
    ///   produce one (e.g. no network, unknown provider, Instagram stub).
    /// - Throws: Any transient error worth surfacing to the orchestrator.
    func fetchDescription(for episode: Episode) async throws -> String?
}

// MARK: - BackfillResult

/// Summary of one ``DescriptionBackfill`` run.
public struct BackfillResult: Sendable, Equatable {
    /// Number of episodes that already had a description (skipped).
    public let skipped: Int
    /// Number of episodes successfully backfilled with a description.
    public let updated: Int
    /// Number of episodes where the fetcher returned `nil` or threw.
    public let failed: Int

    public init(skipped: Int, updated: Int, failed: Int) {
        self.skipped = skipped
        self.updated = updated
        self.failed = failed
    }
}

// MARK: - DescriptionBackfill

/// Backfills missing episode descriptions from their provider.
///
/// ## What it does
/// 1. Reads all episodes from `store` (via the v2 schema `description` column).
/// 2. For each episode where `description == nil`, calls the injected `fetcher`
///    to retrieve the description from the provider (RSS, YouTube, or stub for Instagram).
/// 3. Writes the description back to `store` via a targeted UPDATE — only the
///    `description` column is modified; all other fields are preserved.
///
/// ## Skip-existing contract
/// Episodes that already have a non-nil `description` are **always skipped** —
/// the backfill never overwrites an existing description. This prevents
/// accidental data loss when re-running the backfill.
///
/// ## Safety
/// `store` must be a Swift-owned copy (temp or v2 database). Never pass the
/// live shared `state.sqlite` — see `StateStore` safety docs.
///
/// ## Testability
/// Inject a fake `DescriptionFetcher` to run without network. The store is
/// created in a temp directory by tests.
public struct DescriptionBackfill: Sendable {

    // MARK: - Properties

    /// The state store to read from and write to.
    private let store: StateStore

    /// The fetcher used to retrieve descriptions for episodes.
    private let fetcher: any DescriptionFetcher

    // MARK: - Initialisation

    public init(store: StateStore, fetcher: any DescriptionFetcher) {
        self.store = store
        self.fetcher = fetcher
    }

    // MARK: - Run

    /// Runs the backfill over all episodes in `store`.
    ///
    /// - Returns: A ``BackfillResult`` summarising how many episodes were
    ///   skipped, updated, or failed.
    public func run() async -> BackfillResult {
        let episodes: [Episode]
        do {
            episodes = try store.allEpisodes()
        } catch {
            // Treat a complete read failure as 0 processed.
            return BackfillResult(skipped: 0, updated: 0, failed: 0)
        }

        var skipped = 0
        var updated = 0
        var failed  = 0

        for episode in episodes {
            // Skip episodes that already have a description.
            if episode.description != nil {
                skipped += 1
                continue
            }

            do {
                if let desc = try await fetcher.fetchDescription(for: episode) {
                    // Write description via targeted UPDATE.
                    try updateDescription(guid: episode.guid, description: desc)
                    updated += 1
                } else {
                    // Fetcher returned nil: no description available.
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }

        return BackfillResult(skipped: skipped, updated: updated, failed: failed)
    }

    // MARK: - Private write helper

    /// Performs a targeted SQL UPDATE of only the `description` column for the
    /// given episode `guid`. Preserves all other column values.
    private func updateDescription(guid: String, description: String) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET description = ? WHERE guid = ?",
                arguments: [description, guid]
            )
        }
    }
}

// MARK: - RSSDescriptionFetcher

/// Production fetcher for podcast RSS episodes.
///
/// Re-fetches the RSS feed for the episode's `mp3Url` (using the show's RSS
/// URL if available via `StateStore`), parses it with `RSSManifest`, and
/// returns the matching entry's description.
///
/// Falls back to returning `nil` when the feed is unavailable or the episode
/// isn't found by GUID.
///
/// Note: This fetcher requires an RSS URL. In production, the RSS URL is
/// typically available from the show's watchlist entry, not the episode row
/// itself. For simplicity this fetcher accepts the RSS URL directly.
public struct RSSDescriptionFetcher: DescriptionFetcher {

    /// The RSS feed URL to fetch from.
    private let feedURL: URL

    public init(feedURL: URL) {
        self.feedURL = feedURL
    }

    public func fetchDescription(for episode: Episode) async throws -> String? {
        _ = try URLSafety.safeURL(feedURL.absoluteString)
        let data = try await URLSafety.boundedData(from: feedURL, maxBytes: URLSafety.maxFeedBytes)
        let entries = try RSSManifest.build(fromXML: data)
        return entries.first { $0.guid == episode.guid }?.description
    }
}

// MARK: - YouTubeDescriptionFetcher

/// Production fetcher for YouTube episodes.
///
/// Uses the stored `mp3Url` (a `https://www.youtube.com/watch?v=…` URL) to
/// reconstruct the channel atom feed URL, fetches and parses it, and returns
/// the matching entry's description.
///
/// Returns `nil` when the episode's URL cannot be parsed as a YouTube URL or
/// the entry is not found in the feed.
public struct YouTubeDescriptionFetcher: DescriptionFetcher {

    public init() {}

    public func fetchDescription(for episode: Episode) async throws -> String? {
        guard let videoURL = URL(string: episode.mp3Url),
              let videoID = extractVideoID(from: videoURL) else {
            return nil
        }

        // Build the atom feed URL for this video's channel.
        // We use the video's own oembed-like atom URL to get just this video.
        // The YouTube atom feed for a single video is:
        //   https://www.youtube.com/feeds/videos.xml?v=<videoID>
        // This is not official but commonly available.
        guard let feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?v=\(videoID)") else {
            return nil
        }

        _ = try URLSafety.safeURL(feedURL.absoluteString)
        let data = try await URLSafety.boundedData(from: feedURL, maxBytes: URLSafety.maxFeedBytes)
        let entries = try RSSManifest.build(fromXML: data)
        return entries.first(where: { $0.guid == videoID || $0.guid == episode.guid })?.description
    }

    private func extractVideoID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              host.contains("youtube.com") else { return nil }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }
}

// MARK: - InstagramDescriptionFetcher (stub)

/// Stub fetcher for Instagram episodes.
///
/// Instagram captions are fetched at enumeration time (via gallery-dl) and
/// stored directly as `Episode.description` — there is no re-fetch path.
/// This stub always returns `nil` so the backfill skips Instagram episodes
/// gracefully.
public struct InstagramDescriptionFetcher: DescriptionFetcher {
    public init() {}

    public func fetchDescription(for episode: Episode) async throws -> String? {
        // No live re-fetch path for Instagram captions.
        return nil
    }
}
