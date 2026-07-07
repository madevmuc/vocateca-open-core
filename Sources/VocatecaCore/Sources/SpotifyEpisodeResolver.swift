import Foundation

// MARK: - SpotifyEpisodeMatcher (pure, unit-tested)

/// Fuzzy title matching used to line a Spotify episode up with the same episode
/// in a podcast's public RSS feed. Kept pure (no IO) so it is fully unit-tested;
/// the network orchestration lives in ``SpotifyEpisodeResolver``.
public enum SpotifyEpisodeMatcher {

    /// Normalize a title for fuzzy comparison: fold diacritics + case, replace
    /// every non-alphanumeric run with a single space, collapse whitespace.
    /// e.g. `"Folge #193, Sascha Firtina, Co-Founder von gocomo"`
    ///    → `"folge 193 sascha firtina co founder von gocomo"`.
    public static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Word-token set of a normalized title.
    static func tokens(_ s: String) -> Set<String> {
        Set(normalize(s).split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    /// Jaccard similarity (0…1) of two titles' word-token sets.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// Pick the feed entry that best matches `episodeTitle`. An exact normalized
    /// match wins outright; otherwise the highest Jaccard similarity ≥
    /// `threshold`. Returns `nil` when nothing clears the bar — the caller then
    /// falls back to the podcast subscribe flow rather than transcribing the
    /// wrong episode.
    public static func bestMatch(
        episodeTitle: String,
        in entries: [ManifestEntry],
        threshold: Double = 0.6
    ) -> ManifestEntry? {
        let target = normalize(episodeTitle)
        guard !target.isEmpty, !entries.isEmpty else { return nil }

        if let exact = entries.first(where: { !$0.mp3URL.isEmpty && normalize($0.title) == target }) {
            return exact
        }

        var best: (entry: ManifestEntry, score: Double)?
        for e in entries where !e.mp3URL.isEmpty {
            let s = similarity(episodeTitle, e.title)
            if best == nil || s > best!.score { best = (e, s) }
        }
        if let best, best.score >= threshold { return best.entry }
        return nil
    }

    /// Pick the iTunes search result whose show title best matches `showName`.
    /// Exact normalized match wins; otherwise the highest similarity ≥
    /// `threshold`. `nil` → treat as "no public feed" (Spotify-exclusive).
    public static func bestShow(
        named showName: String,
        in results: [PodcastSearchResult],
        threshold: Double = 0.5
    ) -> PodcastSearchResult? {
        let target = normalize(showName)
        guard !target.isEmpty, !results.isEmpty else { return nil }

        if let exact = results.first(where: { normalize($0.title) == target }) {
            return exact
        }
        var best: (result: PodcastSearchResult, score: Double)?
        for r in results where !r.feedURL.isEmpty {
            let s = similarity(showName, r.title)
            if best == nil || s > best!.score { best = (r, s) }
        }
        if let best, best.score >= threshold { return best.result }
        return nil
    }
}

// MARK: - SpotifyEpisodeOutcome

/// The result of trying to line a Spotify link up with a transcribable podcast
/// episode. Spotify audio is DRM-protected, so we never fetch it directly —
/// instead we resolve to the same episode in the show's **public RSS feed**.
public enum SpotifyEpisodeOutcome: Sendable, Equatable {
    /// The Spotify episode was matched to an item in the show's public feed.
    /// `audioURL` is the RSS enclosure — ready to enqueue as a one-off.
    /// `artworkURL` is the show's iTunes artwork (from the ``PodcastSearch``
    /// lookup used to find the public feed), empty when iTunes had none.
    case matched(showName: String, episodeTitle: String,
                 itemTitle: String, audioURL: String, feedURL: String,
                 artworkURL: String)

    /// A `/show/` link (not an episode). Route to subscribe.
    case showLink(showName: String)

    /// The show has a public feed but the specific episode couldn't be matched
    /// (e.g. not yet in the feed). Offer the subscribe/search flow.
    case episodeNotMatched(showName: String, feedURL: String)

    /// No public feed found for the show — Spotify-exclusive / Original.
    case noPublicFeed(showName: String)

    /// The Spotify page couldn't be read at all.
    case failed(String)

    /// The resolved show name, when known (everything except `.failed`).
    public var showName: String? {
        switch self {
        case .matched(let s, _, _, _, _, _),
             .showLink(let s),
             .episodeNotMatched(let s, _),
             .noPublicFeed(let s):
            return s
        case .failed:
            return nil
        }
    }
}

// MARK: - SpotifyEpisodeResolver (network orchestration)

/// Resolves a Spotify **episode** link to the same episode in the show's public
/// RSS feed so it can be transcribed as a one-off. Pipeline:
///
/// 1. ``SpotifyResolver`` scrapes the show name + episode title off the public
///    `open.spotify.com` page.
/// 2. ``PodcastSearch`` (iTunes) finds the show's RSS `feedUrl`.
/// 3. The feed is fetched (SSRF-guarded) and parsed via ``RSSManifest``.
/// 4. ``SpotifyEpisodeMatcher/bestMatch(episodeTitle:in:threshold:)`` lines the
///    episode up with a feed item and returns its audio enclosure URL.
///
/// Not unit-tested (live network) — only the pure matching in
/// ``SpotifyEpisodeMatcher`` is covered by tests.
public struct SpotifyEpisodeResolver: Sendable {

    public init() {}

    /// Resolves `url`, returning a cached result when one exists. Successful
    /// resolves are cached process-wide (keyed by the trimmed URL) so re-opening
    /// the one-off sheet or a re-fired debounced resolve for the same link does
    /// NOT re-hit Spotify + iTunes + the feed — the main way heavy use tripped
    /// Spotify's rate limit. Failures are never cached, so a transient rate-limit
    /// clears on the next attempt.
    public func resolve(_ url: String, country: String = "us") async -> SpotifyEpisodeOutcome {
        let key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, let hit = await SpotifyResolveCache.shared.cached(key) {
            Log.info("Spotify: resolve cache hit", component: "Spotify", context: [("url", key)])
            return hit
        }
        let outcome = await resolveUncached(url, country: country)
        if !key.isEmpty, case .failed = outcome {
            // don't cache transient failures
        } else if !key.isEmpty {
            await SpotifyResolveCache.shared.store(key, outcome)
        }
        return outcome
    }

    private func resolveUncached(_ url: String, country: String = "us") async -> SpotifyEpisodeOutcome {
        // 1. Show name + episode title from the public Spotify page.
        let resolved: SpotifyResolved
        do {
            resolved = try await SpotifyResolver().resolve(url)
        } catch {
            // Two common causes, indistinguishable from the stripped page we get
            // back: a genuinely Spotify-exclusive show (no public feed), or
            // Spotify temporarily rate-limiting this machine (it then serves a
            // minimal page without the Open Graph tags). Say both so the user can
            // just retry.
            return .failed("Couldn't read the Spotify page. Either the show is Spotify-exclusive (no public feed), or Spotify is rate-limiting — wait a moment and try again, or use Add Subscription ▸ Podcast.")
        }

        guard resolved.kind == .episode,
              let episodeTitle = resolved.episodeTitle,
              !episodeTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .showLink(showName: resolved.showName)
        }

        // 2. iTunes → the show's public RSS feed.
        let results = (try? await PodcastSearch.search(term: resolved.showName, limit: 25, country: country)) ?? []
        guard let show = SpotifyEpisodeMatcher.bestShow(named: resolved.showName, in: results) else {
            Log.info("Spotify: no public feed for show",
                     component: "Spotify", context: [("show", resolved.showName)])
            return .noPublicFeed(showName: resolved.showName)
        }

        // 3. Fetch + parse the feed, match the episode.
        guard let feedData = try? await fetchFeed(show.feedURL),
              let entries = try? RSSManifest.build(fromXML: feedData) else {
            Log.info("Spotify: feed fetch/parse failed",
                     component: "Spotify", context: [("show", resolved.showName), ("feed", show.feedURL)])
            return .episodeNotMatched(showName: resolved.showName, feedURL: show.feedURL)
        }

        guard let item = SpotifyEpisodeMatcher.bestMatch(episodeTitle: episodeTitle, in: entries),
              !item.mp3URL.isEmpty else {
            Log.info("Spotify: episode not matched in feed",
                     component: "Spotify",
                     context: [("show", resolved.showName), ("episode", episodeTitle), ("feedItems", "\(entries.count)")])
            return .episodeNotMatched(showName: resolved.showName, feedURL: show.feedURL)
        }

        let artworkURL = show.artworkURL ?? ""
        Log.info("Spotify: episode matched to public feed item",
                 component: "Spotify",
                 context: [("show", resolved.showName), ("episode", episodeTitle),
                            ("item", item.title), ("audio", item.mp3URL),
                            ("artwork", artworkURL.isEmpty ? "none" : "yes")])
        return .matched(showName: resolved.showName, episodeTitle: episodeTitle,
                        itemTitle: item.title, audioURL: item.mp3URL, feedURL: show.feedURL,
                        artworkURL: artworkURL)
    }

    private func fetchFeed(_ feedURL: String) async throws -> Data {
        let safe = try URLSafety.safeURL(feedURL)
        guard let url = URL(string: safe) else { throw SpotifyResolverError.fetchFailed }
        return try await URLSafety.boundedData(from: url, maxBytes: URLSafety.maxFeedBytes, timeout: 30)
    }
}

// MARK: - SpotifyResolveCache

/// Process-wide, in-memory cache of successful ``SpotifyEpisodeOutcome``s keyed
/// by the trimmed input URL. Actor-isolated for safe concurrent access. Cleared
/// only on app restart (metadata is stable enough that a session-lifetime cache
/// is fine and dramatically cuts request volume to Spotify).
public actor SpotifyResolveCache {
    public static let shared = SpotifyResolveCache()
    private var byURL: [String: SpotifyEpisodeOutcome] = [:]

    public func cached(_ url: String) -> SpotifyEpisodeOutcome? { byURL[url] }
    public func store(_ url: String, _ outcome: SpotifyEpisodeOutcome) { byURL[url] = outcome }

    /// Number of cached resolves (shown next to the "Clear" button).
    public func count() -> Int { byURL.count }

    /// Empties the cache — the next resolve of any link re-fetches from Spotify.
    public func clear() { byURL.removeAll() }
}
