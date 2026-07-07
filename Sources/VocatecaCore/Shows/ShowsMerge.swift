import Foundation

// MARK: - ShowsMerge

/// Pure merge logic for the subscription + DB shows list.
///
/// Extracted from ``LiveDataLoader`` so it can be unit-tested without the UI
/// or a real DB connection. The result is a list of ``MergedItem`` that the
/// loader maps to ``ShowsViewModel.ShowItem``.
///
/// Merge rules:
/// 1. Watchlist shows appear first, in watchlist order.
/// 2. DB-only shows (slugs present in `countsBySlug` but absent from
///    `watchlistShows`) are appended at the end, sorted alphabetically by slug.
/// 3. De-dupe by slug: the watchlist entry wins when both sources contain
///    the same slug (which should not occur in practice, but is guarded).
/// 4. A freshly-subscribed show in `watchlistShows` that has no matching
///    entry in `countsBySlug` gets (done: 0, pending: 0).
public enum ShowsMerge {

    /// A single merged show entry — output of ``merge(watchlistShows:countsBySlug:)``.
    public struct MergedItem {
        public let show: Show
        public let doneCount: Int
        public let pendingCount: Int
        /// True for a one-off / orphan rather than a real subscription — either a
        /// persisted one-off in watchlist.yaml (`Show.oneOff == true`) or a
        /// DB-only slug absent from the watchlist entirely.
        public let isOneOff: Bool

        public init(show: Show, doneCount: Int, pendingCount: Int, isOneOff: Bool = false) {
            self.show = show
            self.doneCount = doneCount
            self.pendingCount = pendingCount
            self.isOneOff = isOneOff
        }
    }

    /// Merges watchlist subscriptions with DB episode counts.
    ///
    /// - Parameters:
    ///   - watchlistShows: The authoritative subscription list (from watchlist.yaml).
    ///                     Freshly-added shows appear here before any DB ingestion.
    ///   - countsBySlug:   Done/pending counts keyed by slug. May cover DB-only slugs
    ///                     (those present in the DB but not in `watchlistShows`).
    ///
    /// - Returns: Merged list, watchlist-order first; DB-only slugs appended at the end.
    public static func merge(
        watchlistShows: [Show],
        countsBySlug: [String: (done: Int, pending: Int)]
    ) -> [MergedItem] {

        var seen = Set<String>()
        var result: [MergedItem] = []

        // 1. Watchlist shows in order (DB counts fall back to 0 for new shows).
        for show in watchlistShows {
            let slug = show.slug
            guard seen.insert(slug).inserted else { continue }  // guard duplicate watchlist slugs
            let counts = countsBySlug[slug]
            result.append(MergedItem(
                show: show,
                doneCount: counts?.done ?? 0,
                pendingCount: counts?.pending ?? 0,
                // A persisted one-off (source "local"/"other", written by
                // LocalIngestService) carries `oneOff: true` in watchlist.yaml —
                // honour it here rather than assuming every watchlist entry is a
                // real subscription. Real subs decode `oneOff: false`.
                isOneOff: show.oneOff
            ))
        }

        // 2. DB-only slugs: present in countsBySlug but absent from the watchlist.
        //    Sorted alphabetically for a stable, deterministic order.
        let watchlistSlugs = Set(watchlistShows.map(\.slug))
        for (slug, counts) in countsBySlug.sorted(by: { $0.key < $1.key }) {
            guard !watchlistSlugs.contains(slug) else { continue }
            guard seen.insert(slug).inserted else { continue }
            // Synthetic Show — no watchlist entry; use slug as the title placeholder.
            let syntheticShow = Show(slug: slug, title: slug, rss: "")
            result.append(MergedItem(
                show: syntheticShow,
                doneCount: counts.done,
                pendingCount: counts.pending,
                isOneOff: true
            ))
        }

        return result
    }
}
