import Foundation

// MARK: - YouTubeURL

/// Oracle-locked port of `core/youtube.py` URL-parsing + RSS helpers.
///
/// Every function must produce **byte-for-byte identical output** to the Python
/// reference implementation for all inputs in the golden fixture file
/// `Tests/VocatecaCoreTests/Fixtures/oracle/youtube_parse_url.json`.
///
/// Do NOT change these algorithms without regenerating the golden fixtures and
/// running `swift test --filter OracleYouTubeTests`.
public struct YouTubeURL: Sendable, Equatable {

    // MARK: - Kind

    /// The kind of YouTube entity identified by the URL.
    ///
    /// Raw-value strings match the Python `YoutubeKind` Literal exactly so
    /// golden-fixture JSON can be compared with string equality.
    public enum Kind: String, Sendable, Equatable {
        case video       = "video"
        case channelID   = "channel_id"
        case handle      = "handle"
        case channelURL  = "channel_url"
        case playlist    = "playlist"
    }

    // MARK: - Properties

    /// The entity kind.
    public let kind: Kind

    /// The extracted value:
    /// - `.video`: 11-char video ID
    /// - `.channelID`: `UC…` 24-char channel ID
    /// - `.handle`: handle without the leading `@`
    /// - `.channelURL`: the full URL (stripped of leading/trailing whitespace)
    /// - `.playlist`: the playlist ID from `list=`
    public let value: String

    // MARK: - Init

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

// MARK: - Error

/// Thrown when a URL is not a recognisable YouTube video/channel/handle URL.
///
/// Port of `core.youtube.YoutubeUrlError`.
public enum YouTubeURLError: Error, Equatable {
    case unrecognised(String)
}

// MARK: - parse(_:)

extension YouTubeURL {

    // Regex constants (compiled once). Both match the Python equivalents exactly.
    private static let videoIDPattern  = try! NSRegularExpression(pattern: #"^[\w-]{11}$"#)
    private static let channelIDPattern = try! NSRegularExpression(pattern: #"^UC[\w-]{22}$"#)

    private static func matchesVideoID(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return videoIDPattern.firstMatch(in: s, range: r) != nil
    }

    private static func matchesChannelID(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return channelIDPattern.firstMatch(in: s, range: r) != nil
    }

    /// Parses a YouTube URL string into a ``YouTubeURL``.
    ///
    /// Port of `parse_youtube_url(url)` from `core/youtube.py`. Replicates
    /// every branch and error case exactly, including:
    /// - `youtu.be` short links (with query params stripped)
    /// - `youtube.com`, `m.youtube.com`, `music.youtube.com` hosts
    /// - `/playlist?list=`, `/watch?v=`, `/channel/UC…`, `/@handle`, `/c/`, `/user/`
    /// - Bare `@handle` and bare name (no scheme, no host)
    ///
    /// - Parameter url: The raw URL string (leading/trailing whitespace is stripped).
    /// - Returns: A ``YouTubeURL`` value.
    /// - Throws: ``YouTubeURLError/unrecognised(_:)`` for any URL that does not match.
    public static func parse(_ url: String) throws -> YouTubeURL {
        let stripped = url.trimmingCharacters(in: .whitespaces)

        // Parse into components. Use URLComponents which tolerates missing schemes.
        // We need netloc and path, mirroring Python's urllib.parse.urlparse.
        let urlComponents = URLComponents(string: stripped)

        // Derive host: lowercase, strip "www." prefix.
        var host = (urlComponents?.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        let path = urlComponents?.path ?? ""
        let netloc = urlComponents?.host ?? ""  // original (for empty-check)

        // --- youtu.be ---
        if host == "youtu.be" {
            // Python: path.lstrip("/").split("/", 1)[0]
            let vid = path.drop(while: { $0 == "/" }).components(separatedBy: "/").first ?? ""
            if matchesVideoID(vid) {
                return YouTubeURL(kind: .video, value: vid)
            }
            throw YouTubeURLError.unrecognised(stripped)
        }

        // --- youtube.com family ---
        if host == "youtube.com" || host == "m.youtube.com" || host == "music.youtube.com" {
            // /playlist
            if path.hasPrefix("/playlist") {
                let queryItems = urlComponents?.queryItems ?? []
                let pid = queryItems.first(where: { $0.name == "list" })?.value ?? ""
                if !pid.isEmpty {
                    return YouTubeURL(kind: .playlist, value: pid)
                }
                throw YouTubeURLError.unrecognised(stripped)
            }
            // /watch
            if path.hasPrefix("/watch") {
                let queryItems = urlComponents?.queryItems ?? []
                let v = queryItems.first(where: { $0.name == "v" })?.value ?? ""
                if matchesVideoID(v) {
                    return YouTubeURL(kind: .video, value: v)
                }
                throw YouTubeURLError.unrecognised(stripped)
            }
            // /channel/UC…
            if path.hasPrefix("/channel/") {
                // Python: path.split("/", 2)[2].split("/", 1)[0]
                // path = "/channel/UCxxx/subpath" -> split on "/" -> ["", "channel", "UCxxx", "subpath"]
                let parts = path.components(separatedBy: "/")
                // parts[0]="" parts[1]="channel" parts[2]=cid (parts[3+]=subpath)
                let cid = parts.count > 2 ? parts[2] : ""
                if matchesChannelID(cid) {
                    return YouTubeURL(kind: .channelID, value: cid)
                }
                throw YouTubeURLError.unrecognised(stripped)
            }
            // /@handle
            if path.hasPrefix("/@") {
                // Python: path[2:].split("/", 1)[0]
                let afterAt = String(path.dropFirst(2))  // drop "/@"
                let handle = afterAt.components(separatedBy: "/").first ?? ""
                if !handle.isEmpty {
                    return YouTubeURL(kind: .handle, value: handle)
                }
                // empty handle falls through to raise
            }
            // /c/ or /user/
            if path.hasPrefix("/c/") || path.hasPrefix("/user/") {
                return YouTubeURL(kind: .channelURL, value: stripped)
            }
        }

        // --- Bare "@handle" or bare "name" (no scheme, no host) ---
        // Python: only when urlparse produced no netloc.
        // URLComponents sets host to nil when there is no authority component.
        if netloc.isEmpty {
            var remainder = stripped
            if remainder.hasPrefix("@") {
                remainder = String(remainder.dropFirst())
            }
            // Valid bare handle/name: non-empty, no "/" in it, no whitespace.
            // Python: `"/" not in remainder and not any(c.isspace() for c in remainder)`
            let hasSlash = remainder.contains("/")
            let hasSpace = remainder.contains(where: { $0.isWhitespace })
            if !remainder.isEmpty && !hasSlash && !hasSpace {
                return YouTubeURL(kind: .channelURL, value: "https://www.youtube.com/@\(remainder)")
            }
        }

        throw YouTubeURLError.unrecognised(stripped)
    }
}

// MARK: - RSS helpers

extension YouTubeURL {

    /// Returns the YouTube channel RSS feed URL for a channel ID.
    ///
    /// Port of `rss_url_for_channel_id(channel_id)` from `core/youtube.py`.
    public static func rssURL(forChannelID channelID: String) -> String {
        "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
    }

    /// Returns the YouTube playlist RSS feed URL for a playlist ID.
    ///
    /// Port of `rss_url_for_playlist_id(playlist_id)` from `core/youtube.py`.
    public static func rssURL(forPlaylistID playlistID: String) -> String {
        "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistID)"
    }

    /// Extracts the `channel_id` query parameter from a YouTube channel feed URL.
    ///
    /// Returns `""` when the URL carries no such parameter (e.g. a podcast RSS URL).
    /// Permissive on purpose — does not validate the `UC…` shape.
    ///
    /// Port of `channel_id_from_feed_url(feed_url)` from `core/youtube.py`.
    public static func channelID(fromFeedURL feedURL: String) -> String {
        let trimmed = feedURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let items = comps.queryItems else { return "" }
        return items.first(where: { $0.name == "channel_id" })?.value ?? ""
    }
}
