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
    /// entry, is not the local-ingest pseudo-show bucket
    /// (``LocalIngestService/localFilesBucketSlug``), and is not a **one-off**
    /// (see `oneOffSlugs`), sorted alphabetically for a stable, deterministic
    /// order.
    ///
    /// ## Why one-offs are excluded
    /// A DB-only slug can be one of two very different things:
    ///   • a **genuinely-orphaned subscription** — a real RSS/YouTube feed whose
    ///     watchlist entry was lost; it should still offer "Reconnect", and
    ///   • a **one-off** — a single manually-transcribed item (drag-drop file,
    ///     folder, or "Import once" URL) that never had a pollable feed. A one-off
    ///     is complete as-is; there is no feed to "lose", so surfacing the "This
    ///     show lost its feed" banner + Reconnect flow for it is wrong (it would
    ///     offer to bind an unrelated podcast as "the lost feed").
    ///
    /// The caller distinguishes the two by the episode-GUID origin marker: a
    /// one-off's episodes all carry `local:<hash>` GUIDs (``LocalIngestService/isOneOffGuid``)
    /// — no feed produced them — whereas a feed-polled episode carries the feed's
    /// own `<guid>`. `oneOffSlugs` is the set of DB slugs whose episodes are ALL
    /// `local:`-origin (see ``StateReader/localOnlyShowSlugs()``). This is an
    /// explicit provenance signal, not an episode-count heuristic.
    ///
    /// - Parameters:
    ///   - dbShowSlugs:    Every distinct `show_slug` present in `episodes`
    ///                     (e.g. from `StateReader.allShowSlugs()`).
    ///   - watchlistShows: The current subscription list (from watchlist.yaml).
    ///   - countsBySlug:   Done/total episode counts keyed by slug (covers at
    ///                     least the DB-only slugs).
    ///   - oneOffSlugs:    DB slugs whose episodes are entirely `local:`-origin —
    ///                     one-offs with no feed to reconnect. Excluded from the
    ///                     result. Defaults to empty (every DB-only slug treated
    ///                     as a genuine orphan, the pre-fix behaviour).
    public static func enumerate(
        dbShowSlugs: [String],
        watchlistShows: [Show],
        countsBySlug: [String: (done: Int, total: Int)],
        oneOffSlugs: Set<String> = []
    ) -> [OrphanedShow] {
        let watchlistSlugs = Set(watchlistShows.map(\.slug))
        return dbShowSlugs
            .filter { slug in
                !watchlistSlugs.contains(slug)
                    && slug != LocalIngestService.localFilesBucketSlug
                    && !oneOffSlugs.contains(slug)
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
