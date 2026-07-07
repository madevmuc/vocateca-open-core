import Foundation

// MARK: - SpotifyResolved

/// The result of resolving a Spotify episode/show link to human-readable names.
///
/// Spotify audio is DRM-protected — we never fetch or transcribe it. Instead we
/// resolve the link to the show name (and episode title, for episode links) so
/// the UI can route into the existing iTunes podcast directory search.
public struct SpotifyResolved: Sendable, Equatable {
    public let kind: SpotifyURL.Kind
    public let showName: String
    /// `nil` for `.show` links.
    public let episodeTitle: String?

    public init(kind: SpotifyURL.Kind, showName: String, episodeTitle: String?) {
        self.kind = kind
        self.showName = showName
        self.episodeTitle = episodeTitle
    }
}

// MARK: - SpotifyResolverError

/// Errors thrown by ``SpotifyResolver/resolve(_:)``.
public enum SpotifyResolverError: Error, Sendable, Equatable {
    /// The input string is not a recognisable Spotify episode/show link.
    case notSpotifyURL
    /// The page could not be fetched (network error or SSRF guard rejection).
    case fetchFailed
    /// The page was fetched but no usable `og:title`/`og:description` metadata
    /// could be found in it.
    case metadataNotFound
}

// MARK: - SpotifyResolver

/// Resolves a Spotify podcast episode/show link to its show name (and episode
/// title, for episodes) by scraping the Open Graph `<meta>` tags off the public
/// `open.spotify.com` page — no Spotify API credentials required.
public struct SpotifyResolver: Sendable {

    /// A desktop-Safari User-Agent. `open.spotify.com` serves a stripped page
    /// without the Open Graph `<meta>` tags to the default CFNetwork agent
    /// (intermittently → "no OG metadata"); a browser UA reliably returns the
    /// full page with `og:title` / `og:description`.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    public init() {}

    /// Resolve a Spotify episode/show link to a ``SpotifyResolved`` value.
    ///
    /// 1. Parses `url` via ``SpotifyURL/parse(_:)``; throws `.notSpotifyURL` if
    ///    it isn't a recognisable Spotify episode/show link.
    /// 2. Fetches the page HTML over HTTPS via the SSRF-safe bounded fetch
    ///    helper (``URLSafety/boundedData(from:maxBytes:timeout:session:)``);
    ///    throws `.fetchFailed` on any network/SSRF error.
    /// 3. Decodes the response as UTF-8 (lossy — never crashes on odd bytes).
    /// 4. Extracts Open Graph metadata via ``parseOGMetadata(html:kind:)``;
    ///    throws `.metadataNotFound` if the expected tags aren't present.
    ///
    /// Not unit tested by design (live network call) — only the pure HTML
    /// parsing in ``parseOGMetadata(html:kind:)`` is covered by tests.
    public func resolve(_ url: String) async throws -> SpotifyResolved {
        guard let spotifyURL = SpotifyURL.parse(url) else {
            throw SpotifyResolverError.notSpotifyURL
        }
        Log.info("Spotify: resolving link",
                 component: "Spotify", context: [("kind", "\(spotifyURL.kind)"), ("id", spotifyURL.id)])

        // Use the lightweight EMBED page (designed for third-party embedding):
        // ~12 KB vs ~120 KB for the full page, and far more tolerant of
        // automated fetches (it still answers when the main page is being
        // rate-limited). Its `__NEXT_DATA__` entity carries the episode title
        // (`name`/`title`) and the show name (`subtitle`).
        let pageURLString = "https://open.spotify.com/embed/\(spotifyURL.kind == .episode ? "episode" : "show")/\(spotifyURL.id)"

        let data: Data
        do {
            try URLSafety.safeURL(pageURLString)
            guard let pageURL = URL(string: pageURLString) else {
                throw SpotifyResolverError.fetchFailed
            }
            data = try await URLSafety.boundedData(
                from: pageURL,
                maxBytes: URLSafety.maxFeedBytes,
                timeout: 30,
                userAgent: Self.browserUserAgent
            )
        } catch {
            Log.error("Spotify: page fetch failed",
                      component: "Spotify", context: [("id", spotifyURL.id), ("error", "\(error)")])
            throw SpotifyResolverError.fetchFailed
        }

        let html = String(decoding: data, as: UTF8.self)

        // Prefer the embed page's structured entity; fall back to Open Graph
        // tags (the embed page carries those too) so a layout change on either
        // path still resolves.
        guard let resolved = Self.parseEmbedMetadata(html: html, kind: spotifyURL.kind)
                ?? Self.parseOGMetadata(html: html, kind: spotifyURL.kind) else {
            Log.error("Spotify: no metadata (exclusive show, rate-limited, or unexpected page)",
                      component: "Spotify", context: [("id", spotifyURL.id)])
            throw SpotifyResolverError.metadataNotFound
        }

        Log.info("Spotify: resolved show",
                 component: "Spotify",
                 context: [("show", resolved.showName), ("episode", resolved.episodeTitle ?? "—")])
        return resolved
    }

    // MARK: - Pure parser (unit tested)

    private static let ogTitlePattern = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:title"\s+content="([^"]*)"\s*/?>"#,
        options: [.caseInsensitive]
    )
    private static let ogDescriptionPattern = try! NSRegularExpression(
        pattern: #"<meta\s+property="og:description"\s+content="([^"]*)"\s*/?>"#,
        options: [.caseInsensitive]
    )

    /// Extract the show name (and, for episodes, the episode title) from a
    /// Spotify episode/show page's raw HTML by scraping its Open Graph
    /// `<meta property="og:title">` / `<meta property="og:description">` tags.
    ///
    /// ## Episode extraction
    /// - `episodeTitle` = decoded/trimmed `og:title`.
    /// - `showName` = the decoded `og:description`, split on `" · "`, with a
    ///   trailing `"Episode"`/`"Podcast"` segment dropped, remainder re-joined
    ///   with `" · "`.
    ///
    /// Example (real Spotify HTML):
    /// - `og:title` = `" Folge #193, Sascha Firtina, Co-Founder von gocomo"`
    /// - `og:description` = `"What's Next, Agencies? · Episode"`
    /// - → `showName` = `"What's Next, Agencies?"`,
    ///   `episodeTitle` = `"Folge #193, Sascha Firtina, Co-Founder von gocomo"`
    ///
    /// ## Show extraction
    /// - `showName` = decoded/trimmed `og:title`.
    /// - `episodeTitle` = `nil`.
    ///
    /// Returns `nil` if `og:title` (and, for `.episode`, `og:description`)
    /// cannot be found in `html`.
    public static func parseOGMetadata(html: String, kind: SpotifyURL.Kind) -> SpotifyResolved? {
        guard let rawTitle = firstMatch(of: ogTitlePattern, in: html) else {
            return nil
        }
        let title = decodeHTMLEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        switch kind {
        case .show:
            return SpotifyResolved(kind: .show, showName: title, episodeTitle: nil)

        case .episode:
            guard let rawDescription = firstMatch(of: ogDescriptionPattern, in: html) else {
                return nil
            }
            let description = decodeHTMLEntities(rawDescription).trimmingCharacters(in: .whitespacesAndNewlines)
            let showName = showName(fromEpisodeDescription: description)
            guard !showName.isEmpty else { return nil }
            return SpotifyResolved(kind: .episode, showName: showName, episodeTitle: title)
        }
    }

    // MARK: - Embed-page parser (unit tested)

    private static let embedEpisodePattern = try! NSRegularExpression(
        pattern: #""title":"([^"]*)","subtitle":"([^"]*)""#, options: []
    )
    private static let embedTitlePattern = try! NSRegularExpression(
        pattern: #""title":"([^"]*)""#, options: []
    )

    /// Extract the show name (and, for episodes, the episode title) from a
    /// Spotify **embed** page's `__NEXT_DATA__` entity JSON.
    ///
    /// - Episode entity: adjacent `"title":"<episode>","subtitle":"<show>"`.
    /// - Show entity: the first `"title":"<show>"`.
    ///
    /// Returns `nil` if the expected fields aren't present (caller falls back to
    /// the Open Graph parser).
    public static func parseEmbedMetadata(html: String, kind: SpotifyURL.Kind) -> SpotifyResolved? {
        switch kind {
        case .episode:
            let range = NSRange(html.startIndex..., in: html)
            guard let m = embedEpisodePattern.firstMatch(in: html, range: range),
                  m.numberOfRanges > 2,
                  let titleRange = Range(m.range(at: 1), in: html),
                  let subtitleRange = Range(m.range(at: 2), in: html)
            else { return nil }
            let episodeTitle = decodeHTMLEntities(String(html[titleRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let showName = decodeHTMLEntities(String(html[subtitleRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !episodeTitle.isEmpty, !showName.isEmpty else { return nil }
            return SpotifyResolved(kind: .episode, showName: showName, episodeTitle: episodeTitle)

        case .show:
            guard let raw = firstMatch(of: embedTitlePattern, in: html) else { return nil }
            let showName = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !showName.isEmpty else { return nil }
            return SpotifyResolved(kind: .show, showName: showName, episodeTitle: nil)
        }
    }

    /// Derive the show name from an episode's `og:description`, e.g.
    /// `"What's Next, Agencies? · Episode"` → `"What's Next, Agencies?"`.
    ///
    /// Splits on `" · "`, drops a trailing `"Episode"`/`"Podcast"` segment, and
    /// re-joins any remaining parts with `" · "`.
    private static func showName(fromEpisodeDescription description: String) -> String {
        var parts = description.components(separatedBy: " · ")
        if let last = parts.last, last == "Episode" || last == "Podcast" {
            parts.removeLast()
        }
        return parts.joined(separator: " · ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return the first capture group of `pattern`'s first match in `text`, or
    /// `nil` if there is no match.
    private static func firstMatch(of pattern: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    /// Decode the small set of HTML entities that appear in Spotify's
    /// `og:title`/`og:description` content attributes.
    ///
    /// Handles: `&amp;` `&quot;` `&#x27;` `&#39;` `&lt;` `&gt;` `&#x2F;`.
    /// `&amp;` is decoded last so that decoding a literal `&amp;amp;` does not
    /// double-unescape.
    private static func decodeHTMLEntities(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&#x2F;", with: "/")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
}
