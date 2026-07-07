import Foundation

// MARK: - PodcastSearchResult

/// One podcast match from the iTunes Search API.
/// Port of `core/discovery.py :: PodcastMatch`.
public struct PodcastSearchResult: Sendable, Equatable, Identifiable {
    public let title: String
    public let author: String
    public let feedURL: String
    public let artworkURL: String?
    public let collectionID: Int?
    /// Episode count reported by iTunes (`trackCount`), when present.
    public let episodeCount: Int?
    /// Primary genre / category (`primaryGenreName`), when present.
    public let genre: String?
    /// Most-recent release date (`releaseDate`, ISO-8601), when present.
    public let releaseDate: String?
    /// Storefront country code reported by iTunes (`country`, e.g. "USA"), when present.
    public let country: String?
    /// Whether iTunes flags the podcast as explicit — derived from
    /// `collectionExplicitness` / `trackExplicitness`. `nil` when unknown.
    public let explicit: Bool?

    public var id: String { feedURL }

    public init(title: String, author: String, feedURL: String,
                artworkURL: String?, collectionID: Int?,
                episodeCount: Int? = nil, genre: String? = nil,
                releaseDate: String? = nil, country: String? = nil,
                explicit: Bool? = nil) {
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.collectionID = collectionID
        self.episodeCount = episodeCount
        self.genre = genre
        self.releaseDate = releaseDate
        self.country = country
        self.explicit = explicit
    }
}

// MARK: - PodcastSearch

/// Podcast discovery via the iTunes Search API — port of
/// `core/discovery.py :: search_itunes`. Searching by a free-text term returns
/// podcasts (with their own RSS `feedUrl`); Apple is only the search index.
public enum PodcastSearch {

    public static let searchHost = "https://itunes.apple.com/search"

    /// Search the iTunes podcast directory for `term`.
    ///
    /// - Parameters:
    ///   - term: free-text query (podcast name).
    ///   - limit: max results (iTunes caps at 200).
    ///   - country: storefront, e.g. "de" / "us".
    public static func search(
        term: String,
        limit: Int = 50,
        country: String = "us",
        timeout: TimeInterval = 10
    ) async throws -> [PodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: searchHost)!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
            URLQueryItem(name: "country", value: country),
        ]
        guard let urlString = components.url?.absoluteString else { return [] }

        // Route through the SSRF guard (public host; redirects re-validated).
        let safe = try URLSafety.safeURL(urlString)
        guard let url = URL(string: safe) else { return [] }

        let data = try await URLSafety.boundedData(from: url, maxBytes: 2_000_000, timeout: timeout)
        return parse(data)
    }

    // MARK: - Pure parsing (testable without IO)

    /// Parse the iTunes search JSON into matches, skipping entries without a
    /// `feedUrl` (matching the Python behaviour).
    public static func parse(_ data: Data) -> [PodcastSearchResult] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = root["results"] as? [[String: Any]]
        else { return [] }

        return results.compactMap { item in
            guard let feed = item["feedUrl"] as? String, !feed.isEmpty else { return nil }
            return PodcastSearchResult(
                title: item["collectionName"] as? String ?? "",
                author: item["artistName"] as? String ?? "",
                feedURL: feed,
                artworkURL: (item["artworkUrl600"] as? String) ?? (item["artworkUrl100"] as? String),
                collectionID: item["collectionId"] as? Int,
                episodeCount: item["trackCount"] as? Int,
                genre: item["primaryGenreName"] as? String,
                releaseDate: item["releaseDate"] as? String,
                country: item["country"] as? String,
                explicit: explicitness(item["collectionExplicitness"] as? String
                                       ?? item["trackExplicitness"] as? String)
            )
        }
    }

    /// Map an iTunes explicitness string to a tri-state boolean.
    /// `"explicit"` → true; `"cleaned"` / `"notExplicit"` → false; else `nil`.
    static func explicitness(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "explicit": return true
        case "cleaned", "notexplicit": return false
        default: return nil
        }
    }
}
