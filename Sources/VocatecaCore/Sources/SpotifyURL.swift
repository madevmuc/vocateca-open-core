import Foundation

// MARK: - SpotifyURL

/// Detects and classifies Spotify podcast episode/show links.
///
/// Spotify audio is DRM-protected and cannot be downloaded/transcribed directly.
/// This type only recognises the link shape and extracts the entity id — the
/// resolved show/episode name is then used to route into the existing iTunes
/// podcast directory search (see ``SpotifyResolver``).
///
/// Recognised forms:
/// - `https://open.spotify.com/episode/<id>` / `https://open.spotify.com/show/<id>`
/// - `http://` variant of the above
/// - Trailing slash tolerated
/// - Query string (e.g. `?si=...`) stripped and ignored
/// - URI form: `spotify:episode:<id>` / `spotify:show:<id>`
///
/// Any other input (non-Spotify URL, malformed, or another Spotify path such as
/// `/track/` or `/playlist/`) returns `nil` from ``parse(_:)``.
public struct SpotifyURL: Sendable, Equatable {

    // MARK: - Kind

    /// The kind of Spotify entity identified by the link.
    public enum Kind: Sendable, Equatable {
        case episode
        case show
    }

    // MARK: - Properties

    /// The entity kind.
    public let kind: Kind

    /// The base62-ish Spotify id (alphanumeric).
    public let id: String

    // MARK: - Init

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

// MARK: - Parsing

extension SpotifyURL {

    // Spotify ids are alphanumeric (base62-ish).
    private static let idPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9]+$"#)

    private static func looksLikeID(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let r = NSRange(s.startIndex..., in: s)
        return idPattern.firstMatch(in: s, range: r) != nil
    }

    /// Parses a Spotify episode/show link into a ``SpotifyURL``.
    ///
    /// - Parameter raw: The raw URL or URI string. Leading/trailing whitespace
    ///   is stripped.
    /// - Returns: A ``SpotifyURL`` on success, `nil` for anything unrecognised.
    public static func parse(_ raw: String) -> SpotifyURL? {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }

        // ── URI form: spotify:episode:<id> / spotify:show:<id> ────────────────
        if stripped.hasPrefix("spotify:") {
            let parts = stripped.components(separatedBy: ":")
            guard parts.count == 3 else { return nil }
            let kindString = parts[1]
            let id = parts[2]
            guard looksLikeID(id) else { return nil }
            switch kindString {
            case "episode": return SpotifyURL(kind: .episode, id: id)
            case "show":    return SpotifyURL(kind: .show, id: id)
            default:        return nil
            }
        }

        // ── URL form: https://open.spotify.com/<episode|show>/<id> ───────────
        guard let comps = URLComponents(string: stripped),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased(),
              host == "open.spotify.com"
        else {
            return nil
        }

        // Query string is already excluded from `comps.path` by URLComponents.
        let parts = comps.path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        let kindString = parts[0].lowercased()
        let id = parts[1]
        guard looksLikeID(id) else { return nil }

        switch kindString {
        case "episode": return SpotifyURL(kind: .episode, id: id)
        case "show":    return SpotifyURL(kind: .show, id: id)
        default:        return nil
        }
    }
}
