import Foundation

// MARK: - OPMLImportResult

/// Outcome of importing a batch of ``OPMLFeed`` entries into the watchlist.
public struct OPMLImportResult: Sendable, Equatable {
    public let added: [String]
    public let skipped: [String]
    public let failed: [FailedFeed]

    public init(added: [String], skipped: [String], failed: [FailedFeed]) {
        self.added = added
        self.skipped = skipped
        self.failed = failed
    }
}

/// A feed that could not be imported, with a human-readable reason.
public struct FailedFeed: Sendable, Equatable {
    public let title: String
    public let error: String

    public init(title: String, error: String) {
        self.title = title
        self.error = error
    }
}

// MARK: - OPMLImporter

/// Subscribes parsed OPML feeds into the watchlist. Network-free: never
/// fetches feeds, only writes `Show` entries to the watchlist file.
public enum OPMLImporter {

    /// Imports every feed in `feeds` into the watchlist at `watchlistURL`.
    ///
    /// Each feed is classified as added (genuinely new show), skipped
    /// (already subscribed — same slug or `rss`), or failed (empty feed URL,
    /// or the watchlist could not be loaded). The watchlist is saved once
    /// after the whole batch, not per feed.
    public static func importFeeds(_ feeds: [OPMLFeed], into watchlistURL: URL) -> OPMLImportResult {
        Log.info("OPML import started", component: "OPML",
                 context: [("count", "\(feeds.count)")])

        guard let store = try? WatchlistStore.load(from: watchlistURL) else {
            let failed = feeds.map { FailedFeed(title: $0.title, error: "failed to load watchlist") }
            Log.info("OPML import aborted: watchlist load failed", component: "OPML",
                     context: [("count", "\(feeds.count)")])
            return OPMLImportResult(added: [], skipped: [], failed: failed)
        }

        var added: [String] = []
        var skipped: [String] = []
        var failed: [FailedFeed] = []

        for feed in feeds {
            guard !feed.feedURL.trimmingCharacters(in: .whitespaces).isEmpty else {
                failed.append(FailedFeed(title: feed.title, error: "empty feed URL"))
                Log.debug("OPML feed failed: empty feed URL", component: "OPML",
                          context: [("title", feed.title)])
                continue
            }

            let slug = WatchlistStore.slugify(feed.title)
            // Bulk OPML import defaults to `.onlyNew` (NOT `.all` like a single
            // manual add): importing hundreds of feeds with `.all` would put every
            // feed's entire back-catalogue in scope, which for a Pro auto-download
            // user is an enqueue avalanche. Back-catalogue is opt-in via the
            // Pro-gated `--backfill` path instead.
            let show = Show(
                slug: slug,
                title: feed.title,
                rss: feed.feedURL,
                artworkUrl: Show.defaultArtworkUrl,
                source: "podcast",
                backfillMode: BackfillMode.onlyNew.rawValue,
                backfillN: 10,
                backfillSince: "",
                author: nil
            )

            if store.add(show) {
                added.append(show.slug)
                Log.debug("OPML feed added", component: "OPML",
                          context: [("slug", show.slug), ("feedURL", feed.feedURL)])
            } else {
                skipped.append(show.slug)
                Log.debug("OPML feed skipped: already subscribed", component: "OPML",
                          context: [("slug", show.slug), ("feedURL", feed.feedURL)])
            }
        }

        try? store.save(to: watchlistURL)

        Log.info("OPML import finished", component: "OPML",
                 context: [("added", "\(added.count)"),
                            ("skipped", "\(skipped.count)"),
                            ("failed", "\(failed.count)")])

        return OPMLImportResult(added: added, skipped: skipped, failed: failed)
    }
}
