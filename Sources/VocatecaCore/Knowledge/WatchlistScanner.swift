import Foundation

/// Turns Watchlist terms + a transcript into persisted `watchlist_hits`.
///
/// One hit row per (term, episode) — repeated matches of the same term in the
/// same episode collapse to a single row (first snippet). Idempotent: a
/// (term, episode) that already has a hit is skipped, so re-scans and the
/// one-time library backfill never duplicate or clobber read-state.
public struct WatchlistScanner: Sendable {

    private let store: StateStore

    public init(store: StateStore) {
        self.store = store
    }

    /// Scans one transcript against `terms`, inserting new hits. Returns the rows
    /// actually inserted (empty when nothing new matched).
    @discardableResult
    public func scan(
        episodeGuid: String,
        showSlug: String,
        text: String,
        terms: [WatchTerm],
        nowISO: String
    ) throws -> [WatchlistHitRow] {
        let hits = KeywordWatch.evaluate(text: text, terms: terms)
        guard !hits.isEmpty else { return [] }

        var inserted: [WatchlistHitRow] = []
        var seenTerms = Set<String>()
        for hit in hits {
            guard !seenTerms.contains(hit.termID) else { continue }  // one row per (term, episode)
            seenTerms.insert(hit.termID)
            if try store.watchlistHitExists(termID: hit.termID, episodeGuid: episodeGuid) { continue }
            let row = WatchlistHitRow(
                id: "\(hit.termID)::\(episodeGuid)",
                termID: hit.termID,
                showSlug: showSlug,
                episodeGuid: episodeGuid,
                snippet: hit.snippet,
                matchedAt: nowISO,
                read: false
            )
            try store.insertWatchlistHit(row)
            inserted.append(row)
        }
        if !inserted.isEmpty {
            Log.info("Watchlist scan matched", component: "Watchlist",
                     context: [("guid", episodeGuid), ("newHits", "\(inserted.count)")])
        }
        return inserted
    }
}
