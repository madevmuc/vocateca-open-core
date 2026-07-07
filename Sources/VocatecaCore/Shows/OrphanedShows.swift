import Foundation

// MARK: - OrphanedShow

/// A DB-only show slug: episodes exist in `state.sqlite` under this slug, but
/// there is no matching entry in `watchlist.yaml` — no title, no artwork, no
/// RSS feed to poll. Surfaced by the Repair tool's "Reconnect orphaned shows"
/// section so the user can re-attach a feed to the existing slug and keep the
/// already-transcribed episodes (see ``WatchlistStore/reconnectShow(slug:rss:title:author:artworkURL:to:)``).
public struct OrphanedShow: Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let episodeCount: Int
    public let doneCount: Int

    public init(slug: String, episodeCount: Int, doneCount: Int) {
        self.slug = slug
        self.episodeCount = episodeCount
        self.doneCount = doneCount
    }
}

// MARK: - OrphanedShows

/// Pure enumeration logic for orphaned (DB-only) shows — extracted so it can be
/// unit-tested without a real DB connection or the UI layer, mirroring
/// ``ShowsMerge``.
public enum OrphanedShows {

    /// Returns every `dbShowSlugs` entry that has NO matching `watchlistShows`
    /// entry and is not the local-ingest pseudo-show bucket
    /// (``LocalIngestService/localFilesBucketSlug``), sorted alphabetically for a
    /// stable, deterministic order.
    ///
    /// - Parameters:
    ///   - dbShowSlugs:    Every distinct `show_slug` present in `episodes`
    ///                     (e.g. from `StateReader.allShowSlugs()`).
    ///   - watchlistShows: The current subscription list (from watchlist.yaml).
    ///   - countsBySlug:   Done/total episode counts keyed by slug (covers at
    ///                     least the DB-only slugs).
    public static func enumerate(
        dbShowSlugs: [String],
        watchlistShows: [Show],
        countsBySlug: [String: (done: Int, total: Int)]
    ) -> [OrphanedShow] {
        let watchlistSlugs = Set(watchlistShows.map(\.slug))
        return dbShowSlugs
            .filter { slug in
                !watchlistSlugs.contains(slug) && slug != LocalIngestService.localFilesBucketSlug
            }
            .sorted()
            .map { slug in
                let counts = countsBySlug[slug]
                return OrphanedShow(
                    slug: slug,
                    episodeCount: counts?.total ?? 0,
                    doneCount: counts?.done ?? 0
                )
            }
    }
}
