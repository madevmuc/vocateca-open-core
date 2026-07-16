import Foundation

// MARK: - CreatorAggregatorShow

/// Lightweight description of a single show as the aggregator sees it.
///
/// All fields are plain value types so the aggregator stays pure —
/// no DB access, no UI, no SwiftUI imports.
public struct CreatorAggregatorShow: Sendable, Equatable {
    public let slug: String
    public let title: String
    /// `show.source` raw string, e.g. "podcast", "youtube", "instagram".
    public let source: String
    /// Author/brand field from the feed (may be empty).
    public let author: String
    /// Total episode count in the state database.
    public let episodeCount: Int
    /// Recent episodes — already ordered newest-first.
    public let recentEpisodes: [CreatorAggregatorEpisode]
    /// Explicit creator name from watchlist.yaml `creator` field (optional).
    /// When non-nil/non-empty this takes priority over `author` and title heuristics.
    public let creator: String?
    /// Artwork URL from the show model (e.g. iTunes artwork, YouTube thumbnail).
    /// Empty string when unavailable.
    public let artworkUrl: String
    /// The raw RSS / subscription URL from the show model.
    /// Used to derive a platform @handle via ``displayHandle``.
    /// Empty string when unavailable.
    public let rss: String

    public init(
        slug: String,
        title: String,
        source: String,
        author: String,
        episodeCount: Int,
        recentEpisodes: [CreatorAggregatorEpisode],
        creator: String? = nil,
        artworkUrl: String = "",
        rss: String = ""
    ) {
        self.slug            = slug
        self.title           = title
        self.source          = source
        self.author          = author
        self.episodeCount    = episodeCount
        self.recentEpisodes  = recentEpisodes
        self.creator         = creator
        self.artworkUrl      = artworkUrl
        self.rss             = rss
    }
}

// MARK: - CreatorAggregatorShow + displayHandle

extension CreatorAggregatorShow {

    /// Derives a platform @handle for display from the source URL.
    ///
    /// Delegates to the same logic as ``Show/displayHandle`` — built from
    /// `source` and `rss` (and optionally `author` for YouTube fallback).
    /// Returns `nil` when no handle can be derived.
    public var displayHandle: String? {
        // Reuse Show.displayHandle by constructing a minimal Show shell.
        // This keeps the derivation logic in a single place (Show+DisplayHandle).
        let shell = Show(slug: slug, title: title, rss: rss, source: source, author: author.isEmpty ? nil : author)
        return shell.displayHandle
    }
}

// MARK: - CreatorAggregatorEpisode

/// A single episode record as the aggregator sees it.
public struct CreatorAggregatorEpisode: Sendable, Equatable {
    public let guid: String
    public let title: String
    public let pubDate: String
    public let status: String
    /// Duration in seconds, or nil when unknown.
    public let durationSec: Int?
    /// Source of the parent show (propagated from the show, not the episode).
    public let source: String

    public init(
        guid: String,
        title: String,
        pubDate: String,
        status: String,
        durationSec: Int?,
        source: String
    ) {
        self.guid        = guid
        self.title       = title
        self.pubDate     = pubDate
        self.status      = status
        self.durationSec = durationSec
        self.source      = source
    }
}

// MARK: - AggregatedCreator

/// A single creator formed by grouping one or more shows that belong to the
/// same person/brand across sources.
public struct AggregatedCreator: Sendable, Equatable {
    /// Stable identifier: the normalised grouping key.
    public let id: String
    /// Display name (longest original show title in the group, used as the
    /// best-available human-readable name when no explicit author is present).
    public let displayName: String

    /// Shows that belong to this creator, keyed by normalised source string.
    ///
    /// At most one entry per source type.  If a source has multiple matching
    /// shows (unusual but possible), the first encountered is kept.
    public let showsBySource: [String: CreatorAggregatorShow]

    /// Total episode count across all grouped shows.
    public let totalEpisodeCount: Int

    /// Recent episodes across all grouped shows, merged and sorted by
    /// `pubDate` descending (lexicographic — ISO-8601 sorts correctly).
    public let recentItems: [CreatorAggregatorEpisode]

    // MARK: Convenience accessors

    public var podcastShow: CreatorAggregatorShow? { showsBySource["podcast"] }
    public var youtubeShow: CreatorAggregatorShow? { showsBySource["youtube"] }
    public var instagramShow: CreatorAggregatorShow? { showsBySource["instagram"] }

    public init(
        id: String,
        displayName: String,
        showsBySource: [String: CreatorAggregatorShow],
        totalEpisodeCount: Int,
        recentItems: [CreatorAggregatorEpisode]
    ) {
        self.id                = id
        self.displayName       = displayName
        self.showsBySource     = showsBySource
        self.totalEpisodeCount = totalEpisodeCount
        self.recentItems       = recentItems
    }
}

// MARK: - CreatorAggregator

/// Pure aggregator that groups shows into creators by a normalised key.
///
/// ## Grouping rule
///
/// Shows are grouped by a **normalised key** derived in this priority order:
///
/// 1. If `show.author` is non-empty: normalise the author string (fold to
///    lowercase, strip diacritics, collapse whitespace) and use it as the key.
///
/// 2. Otherwise: normalise `show.title` and strip common source suffixes
///    ("podcast", "youtube", "youtube channel", "instagram", "(ig)", "(yt)")
///    to arrive at a cleaned brand name as the key.
///
/// Example: shows titled "Finance Talk Podcast", "Finance Talk (YT)", and an
/// Instagram show whose author is "Finance Talk" all resolve to the same
/// normalised key `"finance talk"` and are merged into one creator.
///
/// ## Note on cross-source linkage
///
/// When no author field is present on any show, each show's title is the sole
/// grouping signal.  In libraries where titles don't share a common stem, each
/// show becomes its own single-source creator.  This is an acceptable fallback
/// until the watchlist gains an explicit `creator` or `brand` field.
///
/// ## Top creator
///
/// The "top" creator is the one with the highest `totalEpisodeCount`.  Ties
/// are broken by `displayName` lexicographic order.
public enum CreatorAggregator {

    // MARK: - Public API

    /// Groups `shows` into creators and returns them sorted by total episode
    /// count descending.
    ///
    /// Grouping priority per show:
    ///   1. Explicit `creator` field (case-insensitive trim match).
    ///   2. Non-empty `author` field (case-insensitive, diacritics folded).
    ///   3. Title-root heuristic (strip common source suffixes, then normalise).
    ///
    /// - Parameter shows: The full list of shows from the watchlist, each
    ///   carrying its episode count and recent episodes.
    /// - Parameter recentItemsLimit: Maximum number of merged recent items to
    ///   include per creator (default: 50).
    /// - Returns: Creators sorted best-first (highest total episode count).
    ///   Returns an empty array when `shows` is empty.
    public static func aggregate(
        shows: [CreatorAggregatorShow],
        recentItemsLimit: Int = 50
    ) -> [AggregatedCreator] {
        guard !shows.isEmpty else { return [] }

        // 1. Build groups: normalisedKey → [Show]
        var groups: [(key: String, shows: [CreatorAggregatorShow])] = []
        var keyIndex: [String: Int] = [:]  // normalisedKey → index in `groups`

        for show in shows {
            let key = normalisedKey(for: show)
            if let idx = keyIndex[key] {
                groups[idx].shows.append(show)
            } else {
                keyIndex[key] = groups.count
                groups.append((key: key, shows: [show]))
            }
        }

        // 2. Build an AggregatedCreator for each group.
        var creators: [AggregatedCreator] = groups.map { group in
            buildCreator(from: group.shows, key: group.key, recentItemsLimit: recentItemsLimit)
        }

        // 3. Sort: highest total episode count first; ties broken by displayName.
        creators.sort {
            if $0.totalEpisodeCount != $1.totalEpisodeCount {
                return $0.totalEpisodeCount > $1.totalEpisodeCount
            }
            return $0.displayName < $1.displayName
        }

        return creators
    }

    /// Returns all creators sorted by total episode count descending.
    ///
    /// Convenience alias for ``aggregate(shows:recentItemsLimit:)`` with a
    /// semantically clearer name for call sites that want the full list.
    public static func allCreators(
        from shows: [CreatorAggregatorShow],
        recentItemsLimit: Int = 50
    ) -> [AggregatedCreator] {
        aggregate(shows: shows, recentItemsLimit: recentItemsLimit)
    }

    /// Returns the single "top" creator (most total content), or `nil` when
    /// `shows` is empty.
    public static func topCreator(
        from shows: [CreatorAggregatorShow],
        recentItemsLimit: Int = 50
    ) -> AggregatedCreator? {
        allCreators(from: shows, recentItemsLimit: recentItemsLimit).first
    }

    // MARK: - Grouping key

    /// Derives the normalised grouping key for a show.
    ///
    /// Priority order:
    ///   1. Explicit `creator` field (non-empty after trim) — wins over everything.
    ///   2. Non-empty `author` field (normalised case/diacritics).
    ///   3. Title with common source suffixes stripped, then normalised.
    ///
    /// Each tier delegates to ``normalisedKey(forName:)`` — the same
    /// normalisation a raw name string (e.g. a YouTube channel's display
    /// name) goes through in ``matchingShows(forChannelName:in:)`` — so a
    /// show's grouping key and an externally-supplied name's match key can
    /// never silently drift apart.
    static func normalisedKey(for show: CreatorAggregatorShow) -> String {
        if let explicit = show.creator {
            let trimmed = explicit.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return normalisedKey(forName: trimmed)
            }
        }
        let author = show.author.trimmingCharacters(in: .whitespaces)
        if !author.isEmpty {
            return normalisedKey(forName: author)
        }
        return normalisedKey(forName: show.title)
    }

    /// Normalises a raw name string (e.g. a YouTube channel's display name,
    /// or any other externally-supplied creator/brand name) exactly the way
    /// ``normalisedKey(for:)`` normalises a show's `creator`/`author`/
    /// `title` field: fold to lowercase, strip diacritics, collapse
    /// whitespace, and strip the same trailing source suffixes
    /// ``strippedTitle(_:)`` already strips from a title (a no-op for a
    /// plain name with no such suffix).
    ///
    /// Exposed publicly so match logic OUTSIDE this file (e.g. the YouTube
    /// Explorer's "same creator as an existing show" detection) can compute
    /// a key that is guaranteed to agree with how ``aggregate(shows:recentItemsLimit:)``
    /// would actually group that name.
    public static func normalisedKey(forName name: String) -> String {
        normalise(strippedTitle(name))
    }

    // MARK: - Channel-name match (YouTube Explorer "same creator" detection)

    /// Returns the existing NON-YouTube shows in `shows` that plausibly
    /// belong to the same creator as a YouTube channel named `name`.
    ///
    /// A show matches when its normalised grouping key EQUALS the channel's
    /// normalised key, OR one key is a WHOLE-WORD prefix of the other. The
    /// whole-word-prefix rule is what makes the very common real-world shape
    /// work: a podcast titled "The Diary Of A CEO with Steven Bartlett"
    /// (key `"the diary of a ceo with steven bartlett"`) matches a channel
    /// "The Diary Of A CEO" (key `"the diary of a ceo"`), because every word
    /// of the shorter key equals the leading words of the longer. Exact
    /// key-equality alone (what ``aggregate(shows:recentItemsLimit:)``'s
    /// grouping uses) never links those two.
    ///
    /// "Unambiguous" (safe to auto-merge) means exactly one match; zero or
    /// more than one means the caller should fall back to letting the user
    /// pick manually. A short channel name that is a whole-word prefix of
    /// several unrelated shows (e.g. "The Daily" vs. "The Daily Show" +
    /// "The Daily Wire") therefore yields 2 and does NOT auto-link.
    ///
    /// YouTube shows are excluded because the caller (the YouTube Explorer)
    /// is trying to find where an as-yet-unsaved-or-just-saved YouTube video
    /// belongs — matching it against another YouTube show would be
    /// meaningless (and could otherwise match the very show being created).
    ///
    /// Pure + static, no I/O — operates on the same ``Show`` model the
    /// watchlist stores, not ``CreatorAggregatorShow`` (the caller doesn't
    /// need episode counts/recent items just to find a name match).
    ///
    /// - Parameter name: a raw creator/channel display name (e.g. a YouTube
    ///   channel's `%(channel)s`), not yet normalised.
    /// - Parameter shows: the full list of shows to search (typically the
    ///   watchlist's current shows).
    public static func matchingShows(forChannelName name: String, in shows: [Show]) -> [Show] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let key = normalisedKey(forName: trimmed)
        guard !key.isEmpty else { return [] }
        return shows.filter { show in
            show.source.lowercased() != "youtube"
                && keysBelongTogether(key, normalisedKey(forShow: show))
        }
    }

    /// True when two normalised keys should be treated as the same creator:
    /// exact equality, or one is a WHOLE-WORD prefix of the other (split on
    /// spaces; every word of the shorter sequence equals the leading words
    /// of the longer). Whole-word so "the daily" matches "the daily show"
    /// but "the dail" never matches "the daily" (a partial last word is not
    /// a prefix). Empty keys never match anything.
    static func keysBelongTogether(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let wa = a.split(separator: " ")
        let wb = b.split(separator: " ")
        let (shorter, longer) = wa.count <= wb.count ? (wa, wb) : (wb, wa)
        // A single-word key that is a prefix of a multi-word one (e.g.
        // "diary" ⊂ "diary of a ceo") is too weak a signal to auto-link on,
        // but the caller's ambiguity guard (count == 1) already blunts false
        // positives; keep the rule simple and purely whole-word.
        return Array(longer.prefix(shorter.count)) == Array(shorter)
    }

    /// Same priority order as ``normalisedKey(for:)`` (creator > author >
    /// stripped title), operating directly on the ``Show`` model rather than
    /// the aggregator's own ``CreatorAggregatorShow`` shell — used only by
    /// ``matchingShows(forChannelName:in:)``, which works with raw watchlist
    /// shows and has no episode-count/recent-item data to build a full
    /// ``CreatorAggregatorShow`` from.
    private static func normalisedKey(forShow show: Show) -> String {
        if let creator = show.creator {
            let trimmed = creator.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return normalisedKey(forName: trimmed)
            }
        }
        if let author = show.author {
            let trimmed = author.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return normalisedKey(forName: trimmed)
            }
        }
        return normalisedKey(forName: show.title)
    }

    // MARK: - Normalisation helpers

    /// Folds a string to lowercase, removes diacritics, and collapses
    /// interior whitespace runs to a single space.
    static func normalise(_ input: String) -> String {
        // Strip diacritics via Unicode NFD decomposition + ASCII filter.
        let ascii = input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        // Collapse runs of whitespace.
        let words = ascii.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// Removes common trailing source suffixes from a show title so that
    /// "Finance Talk Podcast" and "Finance Talk (YT)" share a key.
    ///
    /// Suffixes stripped (case-insensitive, after whitespace trim):
    ///   "podcast", "youtube", "youtube channel", "instagram",
    ///   "(podcast)", "(ig)", "(yt)", "(youtube)", "(instagram)"
    static func strippedTitle(_ title: String) -> String {
        // Ordered longest-first so "(youtube channel)" doesn't half-strip.
        let suffixes: [String] = [
            "(youtube channel)", "youtube channel",
            "(instagram)", "instagram",
            "(youtube)", "youtube",
            "(podcast)", "podcast",
            "(ig)", "(yt)",
        ]
        var result = title.trimmingCharacters(in: .whitespaces)
        let lower  = result.lowercased()
        for suffix in suffixes {
            if lower.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                break  // strip at most one suffix
            }
        }
        return result
    }

    // MARK: - Creator builder

    private static func buildCreator(
        from shows: [CreatorAggregatorShow],
        key: String,
        recentItemsLimit: Int
    ) -> AggregatedCreator {
        // Display name: prefer explicit creator > non-empty author > shortest title.
        // (Shortest title is most likely the "base" name without source suffix.)
        let displayName: String = {
            if let explicit = shows.compactMap({ $0.creator.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }).first {
                return explicit
            }
            if let authorName = shows.compactMap({ $0.author.isEmpty ? nil : $0.author }).first {
                return authorName
            }
            return shows.map { $0.title }.min(by: { $0.count < $1.count }) ?? key
        }()

        // Source map: keep at most one show per source (first wins).
        var showsBySource: [String: CreatorAggregatorShow] = [:]
        for show in shows {
            let src = show.source.lowercased()
            if showsBySource[src] == nil {
                showsBySource[src] = show
            }
        }

        // Total episode count.
        let total = shows.reduce(0) { $0 + $1.episodeCount }

        // Merge and sort recent items across all shows.
        let allItems: [CreatorAggregatorEpisode] = shows.flatMap { $0.recentEpisodes }
        let sorted = allItems
            .sorted { $0.pubDate > $1.pubDate }
            .prefix(recentItemsLimit)

        return AggregatedCreator(
            id:                key,
            displayName:       displayName,
            showsBySource:     showsBySource,
            totalEpisodeCount: total,
            recentItems:       Array(sorted)
        )
    }
}
