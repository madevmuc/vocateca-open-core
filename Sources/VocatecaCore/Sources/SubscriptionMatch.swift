import Foundation

// MARK: - SubscriptionMatch

/// Pure logic for deciding whether a discovery search result is ALREADY a
/// subscribed show — so the Add / search UIs can mark it "Subscribed" and stop
/// the user re-adding a duplicate.
///
/// Extracted from the UI so it can be unit-tested without a live watchlist or
/// the SwiftUI layer. Two independent signals are used (either one is a match):
///
/// 1. **Feed URL** — the result's RSS `feedURL` equals an existing show's `rss`,
///    compared after light normalization (trimmed, lowercased, trailing slash
///    dropped, `http`↔`https` folded). This is the strongest signal: the same
///    feed is unambiguously the same subscription.
/// 2. **Slug** — the slug the subscribe path WOULD create from the result's
///    title (`WatchlistStore.slugify(title)`) already exists among the shows'
///    slugs. This catches a subscription added under a slightly different feed
///    URL (e.g. an `http` vs `https` variant the normalization above missed, or
///    a feed that moved) but the same title.
public enum SubscriptionMatch {

    /// Normalizes a feed URL for comparison: trims whitespace, lowercases,
    /// folds `http://`→`https://`, and drops a single trailing slash. Returns an
    /// empty string for an empty/whitespace input (never matches).
    public static func normalizeFeedURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Builds the lookup sets a UI needs to test many results cheaply against the
    /// current subscriptions: normalized feed URLs and existing slugs.
    ///
    /// - Parameter shows: The live subscribed shows (e.g.
    ///   `liveData.showsVM.items.map(\.show)` or `WatchlistStore.watchlist.shows`).
    /// - Returns: `(feedURLs, slugs)` — pass to ``isSubscribed(feedURL:title:in:)``.
    public static func index(shows: [Show]) -> (feedURLs: Set<String>, slugs: Set<String>) {
        var feedURLs: Set<String> = []
        var slugs: Set<String> = []
        for show in shows {
            let n = normalizeFeedURL(show.rss)
            if !n.isEmpty { feedURLs.insert(n) }
            if !show.slug.isEmpty { slugs.insert(show.slug) }
        }
        return (feedURLs, slugs)
    }

    /// Returns `true` when a result with this `feedURL` / `title` is already
    /// subscribed, given a precomputed index from ``index(shows:)``.
    public static func isSubscribed(
        feedURL: String,
        title: String,
        in index: (feedURLs: Set<String>, slugs: Set<String>)
    ) -> Bool {
        let normalized = normalizeFeedURL(feedURL)
        if !normalized.isEmpty, index.feedURLs.contains(normalized) { return true }
        let slug = WatchlistStore.slugify(title)
        if !slug.isEmpty, index.slugs.contains(slug) { return true }
        return false
    }
}
