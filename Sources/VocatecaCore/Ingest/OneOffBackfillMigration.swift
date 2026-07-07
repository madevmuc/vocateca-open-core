import Foundation

// MARK: - OneOffBackfillMigration

/// One-time, idempotent backfill that upgrades **pre-overhaul one-offs** in
/// watchlist.yaml to the new persisted one-off model.
///
/// Before the one-off overhaul, `LocalIngestService.ensureLocalShow` wrote every
/// one-off (a single dragged file OR a pasted YouTube / Instagram / other URL)
/// with `source: "local"` and no `one_off` flag — so it decoded as
/// `one_off: false` and was indistinguishable from a real subscription. The new
/// model relies on a persisted ``Show/oneOff`` `== true` for three behaviours:
///   • the last-episode delete → redirect + remove (F2),
///   • the Monitor / Auto-download feed-gate (12b), and
///   • the source-classified filter tabs — YouTube / Instagram / Other (N4).
///
/// This migration rewrites those legacy entries so they behave exactly like
/// freshly-created one-offs.
///
/// **Rule (safe + narrow):** a watchlist show with `source == "local"` is a
/// pre-overhaul one-off. Set `oneOff = true` and re-derive its real source from
/// the slug / title / rss (contains "youtube"/"youtu.be" → `youtube`,
/// "instagram" → `instagram`, otherwise → `other`). The folder-watch drop target
/// uses `source == "local-drop"` and is deliberately **not** matched, so it is
/// never mis-flagged as a one-off. Real subscriptions (`podcast` / `youtube` /
/// `instagram`) are untouched.
///
/// **Idempotent:** the rewrite always moves `source` off `"local"`, so a second
/// run matches nothing and is a no-op — safe to call on every launch.
public enum OneOffBackfillMigration {

    /// The pre-overhaul one-off source marker written by the old
    /// `ensureLocalShow` default.
    static let legacyOneOffSource = "local"

    /// Runs the backfill against the watchlist at `url`.
    ///
    /// - Returns: the number of shows rewritten (0 when nothing matched or the
    ///   watchlist could not be loaded).
    @discardableResult
    public static func run(watchlistURL: URL) -> Int {
        guard var watchlist = try? Watchlist.load(from: watchlistURL) else { return 0 }

        var changed = 0
        for i in watchlist.shows.indices where watchlist.shows[i].source == legacyOneOffSource {
            watchlist.shows[i].source = derivedSource(for: watchlist.shows[i])
            watchlist.shows[i].oneOff = true
            changed += 1
        }

        guard changed > 0 else { return 0 }
        do {
            try watchlist.saveAtomic(to: watchlistURL)
            Log.info("OneOffBackfillMigration: upgraded \(changed) legacy one-off(s) to the persisted one-off model",
                     component: "Migration")
        } catch {
            Log.warn("OneOffBackfillMigration: failed to save watchlist after backfill",
                     component: "Migration", context: [("error", "\(error)")])
            return 0
        }
        return changed
    }

    /// Re-derives the real source for a legacy one-off from its slug / title /
    /// rss. YouTube and Instagram are detected by substring (a one-off's slug is
    /// the mangled origin URL, e.g. `https-www-youtube-com-watch-v-…`);
    /// everything else falls into the generic `other` bucket, matching the
    /// `SourceBadge` / Shows-filter classification.
    static func derivedSource(for show: Show) -> String {
        let haystack = "\(show.slug) \(show.title) \(show.rss)".lowercased()
        if haystack.contains("youtube") || haystack.contains("youtu.be") {
            return "youtube"
        }
        if haystack.contains("instagram") {
            return "instagram"
        }
        return "other"
    }
}
