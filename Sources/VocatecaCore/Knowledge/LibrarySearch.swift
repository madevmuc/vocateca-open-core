import Foundation

// MARK: - LibrarySearch

/// Full-text search over the indexed episode library.
///
/// ## Ranking formula
///
/// Given a query `q` and episode `(title, body, show)`:
///
/// ```
/// score(q, title, body, show) = tf_title × W_TITLE
///                              + tf_body  × W_BODY
///                              + showBonus
/// ```
///
/// Where:
///
/// - `tf_title` = (count of distinct query terms found in the lowercased title)
///               / (total distinct query terms)  ∈ [0, 1]
/// - `tf_body`  = (count of distinct query terms found in the lowercased body)
///               / (total distinct query terms)  ∈ [0, 1]
/// - `W_TITLE`  = 3.0   — title hits are 3× more valuable than body hits
/// - `W_BODY`   = 1.0
/// - `showBonus`= 0.5 when any query term appears in the lowercased show slug or
///               show title; 0.0 otherwise
///
/// Term splitting: the query is split on whitespace; each non-empty token is
/// lowercased. Matching is case-insensitive substring containment.
///
/// Results are filtered to score > 0 and returned sorted by score descending.
///
/// ## Empty query rule
///
/// An empty or whitespace-only query returns an empty result array (rather than
/// all episodes). Callers that want "show everything" should not use the search
/// function for that purpose — return all episodes from `LibraryIndex.indexedEpisodes()`.
public struct LibrarySearch: Sendable {

    public init() {}

    // MARK: - Weight constants

    /// Weight applied to query-term hits in the episode title.
    public static let titleWeight: Double = 3.0

    /// Weight applied to query-term hits in the transcript body.
    public static let bodyWeight: Double = 1.0

    /// Bonus score awarded when any query term matches the show slug or show name.
    public static let showBonus: Double = 0.5

    // MARK: - Pure scoring function

    /// Computes a relevance score for a single candidate.
    ///
    /// - Parameters:
    ///   - query: The search query string. Tokenised on whitespace.
    ///   - title: Episode title.
    ///   - body: Full transcript text (or body text loaded from the `.md` file).
    ///   - show: Show slug (or title) to compute the show-name bonus.
    /// - Returns: A non-negative score. Zero means no match at all.
    public static func score(query: String, title: String, body: String, show: String) -> Double {
        let terms = query
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return 0.0 }

        let totalTerms = Double(terms.count)
        let lcTitle = title.lowercased()
        let lcBody  = body.lowercased()
        let lcShow  = show.lowercased()

        var titleHits = 0
        var bodyHits  = 0
        var showHit   = false

        for term in terms {
            if lcTitle.contains(term) { titleHits += 1 }
            if lcBody.contains(term)  { bodyHits  += 1 }
            if lcShow.contains(term)  { showHit   = true }
        }

        let tfTitle = Double(titleHits) / totalTerms
        let tfBody  = Double(bodyHits) / totalTerms
        let showBonusValue = showHit ? showBonus : 0.0

        return tfTitle * titleWeight + tfBody * bodyWeight + showBonusValue
    }

    // MARK: - Search

    /// Searches a list of `IndexedEpisode` values, returning results sorted by
    /// relevance score descending.
    ///
    /// Zero-score episodes are filtered out. Results with equal score maintain
    /// stable (but unspecified) order relative to each other.
    ///
    /// This method loads the transcript body from disk for each episode that has
    /// a `transcriptURL`. Episodes without a transcript are scored on title and
    /// show alone.
    ///
    /// - Parameters:
    ///   - query: The search query.
    ///   - episodes: The pool of candidates to score.
    /// - Returns: Filtered, sorted `[SearchResult]` (highest score first).
    public func search(_ query: String, in episodes: [IndexedEpisode]) -> [SearchResult] {
        let terms = query
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var results: [SearchResult] = []

        for ep in episodes {
            let body = loadBody(ep.transcriptURL)
            let s = Self.score(
                query: query,
                title: ep.episode.title,
                body: body,
                show: ep.episode.showSlug
            )
            if s > 0 {
                results.append(SearchResult(indexedEpisode: ep, score: s))
            }
        }

        results.sort { $0.score > $1.score }
        return results
    }

    // MARK: - Private helpers

    /// Loads the plain-text body of a transcript `.md` file, stripping YAML
    /// frontmatter. Returns an empty string when the file is missing or
    /// unreadable.
    private func loadBody(_ url: URL?) -> String {
        guard let url = url,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return stripFrontmatter(from: text)
    }

    /// Removes the leading `---` … `---` YAML frontmatter block and returns
    /// the remainder of the document (the transcript body).
    private func stripFrontmatter(from text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        var inFM = false
        var bodyStart = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFM { inFM = true; continue }
                else { bodyStart = i + 1; break }
            }
        }
        if bodyStart == 0 { return text }
        return lines[bodyStart...].joined(separator: "\n")
    }
}
