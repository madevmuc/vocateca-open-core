import Foundation

// MARK: - InstagramURL

/// Represents a parsed Instagram URL or handle.
///
/// ## Parse Rules (documented spec interpretation)
///
/// Instagram handles are case-insensitive; we normalise to **lowercase** throughout.
/// Shortcodes preserve original case (they are case-sensitive base-62 identifiers).
///
/// | Input form                                              | Kind      | value                     |
/// |---------------------------------------------------------|-----------|---------------------------|
/// | `@someuser`                                             | .profile  | `someuser`                |
/// | `someuser`  (bare, no scheme, no special chars)         | .profile  | `someuser`                |
/// | `https://www.instagram.com/someuser`                    | .profile  | `someuser`                |
/// | `https://www.instagram.com/someuser/`                   | .profile  | `someuser`                |
/// | `instagram.com/someuser`                                | .profile  | `someuser`                |
/// | `https://www.instagram.com/reel/CxYzABCD/`             | .reel     | `CxYzABCD`               |
/// | `instagram.com/reel/CxYzABCD`                          | .reel     | `CxYzABCD`               |
/// | `https://www.instagram.com/p/CxYzABCD/`                | .post     | `CxYzABCD`               |
/// | `instagram.com/p/CxYzABCD`                             | .post     | `CxYzABCD`               |
/// | `https://www.instagram.com/stories/someuser/12345678/`  | .story    | `someuser` (handle)       |
/// | `instagram.com/stories/someuser/12345678`               | .story    | `someuser` (handle)       |
///
/// **Profile handle normalisation:** the leading `@` is stripped, the result is
/// lowercased. Instagram handles are 1–30 chars, `[A-Za-z0-9._]`, not starting or
/// ending with a period, and may not contain consecutive periods — we do NOT validate
/// those constraints here (the field comes from user input; validation belongs in the
/// add-flow UI). We do reject obviously-invalid inputs (empty, contains slashes or
/// spaces after stripping).
///
/// **Stories value:** for stories we return the **handle** (the account whose story
/// it is), not the story media-id. The media-id is ephemeral and not useful for
/// deduplication or routing.
///
/// **Scheme tolerance:** inputs with or without `https://`, `http://`, or bare
/// `instagram.com/…` (no scheme at all) are all accepted.
public struct InstagramURL: Sendable, Equatable {

    // MARK: - Kind

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case profile
        case reel
        case post
        case story
    }

    // MARK: - Properties

    public let kind: Kind
    /// The extracted value — handle (lowercased) for profile/story, shortcode for reel/post.
    public let value: String

    // MARK: - Init

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

// MARK: - Error

public enum InstagramURLError: Error, Equatable {
    case unrecognised(String)
}

// MARK: - Parsing

extension InstagramURL {

    // Shortcode: base-62 chars [A-Za-z0-9_-], typically 11 chars, but Instagram
    // has used lengths from 10 to 12. We accept 1–30 non-empty, no slash chars.
    private static let shortcodePattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_\-]{1,30}$"#)
    // Handle: 1-30 chars from [A-Za-z0-9._]. Lowercased after extraction.
    private static let handlePattern    = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._]{1,30}$"#)

    private static func looksLikeShortcode(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return shortcodePattern.firstMatch(in: s, range: r) != nil
    }

    private static func looksLikeHandle(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return handlePattern.firstMatch(in: s, range: r) != nil
    }

    /// Parses an Instagram URL or handle string into an ``InstagramURL``.
    ///
    /// - Parameter input: Raw user input. Leading/trailing whitespace is stripped.
    /// - Returns: An ``InstagramURL`` on success.
    /// - Throws: ``InstagramURLError/unrecognised(_:)`` when the input cannot be
    ///   mapped to a known Instagram URL shape.
    public static func parse(_ input: String) throws -> InstagramURL {
        let stripped = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // ── 1. Bare @handle ────────────────────────────────────────────────
        if stripped.hasPrefix("@") {
            let handle = String(stripped.dropFirst()).lowercased()
            guard !handle.isEmpty, !handle.contains("/"), !handle.contains(" ") else {
                throw InstagramURLError.unrecognised(stripped)
            }
            return InstagramURL(kind: .profile, value: handle)
        }

        // ── 2. Try to parse as URL ─────────────────────────────────────────
        // Normalise: if no scheme, prepend https:// so URLComponents can parse it.
        let urlString: String
        let lc = stripped.lowercased()
        if lc.hasPrefix("http://") || lc.hasPrefix("https://") {
            urlString = stripped
        } else if lc.hasPrefix("instagram.com") || lc.hasPrefix("www.instagram.com") {
            urlString = "https://\(stripped)"
        } else {
            // Could be a bare handle (no scheme, no instagram.com).
            urlString = stripped
        }

        if let comps = URLComponents(string: urlString),
           let host = comps.host?.lowercased(),
           (host == "instagram.com" || host == "www.instagram.com")
        {
            return try parseInstagramPath(comps.path, original: stripped)
        }

        // ── 3. Bare handle (no scheme, no instagram.com host) ─────────────
        // Must be non-empty, no slashes, no whitespace.
        let hasSlash     = stripped.contains("/")
        let hasSpace     = stripped.contains(where: { $0.isWhitespace })
        let hasColon     = stripped.contains(":")
        let isDot        = stripped == "."
        if !stripped.isEmpty && !hasSlash && !hasSpace && !hasColon && !isDot {
            let handle = stripped.lowercased()
            if looksLikeHandle(stripped) {
                return InstagramURL(kind: .profile, value: handle)
            }
        }

        throw InstagramURLError.unrecognised(stripped)
    }

    // MARK: - Path routing

    /// Routes an instagram.com path to the correct `Kind`.
    ///
    /// `path` is already percent-decoded by URLComponents.
    private static func parseInstagramPath(_ path: String, original: String) throws -> InstagramURL {
        // Normalise trailing slash: split on "/" and drop empty components.
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        // parts[0] = first path segment (e.g. "reel", "p", "stories", or handle)

        switch parts.first?.lowercased() {
        case "reel":
            // /reel/<shortcode>[/…]
            guard parts.count >= 2 else { throw InstagramURLError.unrecognised(original) }
            let sc = parts[1]
            guard looksLikeShortcode(sc) else { throw InstagramURLError.unrecognised(original) }
            return InstagramURL(kind: .reel, value: sc)

        case "p":
            // /p/<shortcode>[/…]
            guard parts.count >= 2 else { throw InstagramURLError.unrecognised(original) }
            let sc = parts[1]
            guard looksLikeShortcode(sc) else { throw InstagramURLError.unrecognised(original) }
            return InstagramURL(kind: .post, value: sc)

        case "stories":
            // /stories/<username>[/<media-id>[/…]]
            guard parts.count >= 2 else { throw InstagramURLError.unrecognised(original) }
            let handle = parts[1].lowercased()
            guard looksLikeHandle(parts[1]) else { throw InstagramURLError.unrecognised(original) }
            return InstagramURL(kind: .story, value: handle)

        case nil, "":
            throw InstagramURLError.unrecognised(original)

        default:
            // /someuser[/…] — treat as profile if the segment looks like a handle.
            let segment = parts[0]
            // Reject known non-profile segments.
            let reservedSegments: Set<String> = [
                "explore", "accounts", "direct", "reels", "tv",
                "about", "legal", "help", "login", "signup",
            ]
            let lcSeg = segment.lowercased()
            if reservedSegments.contains(lcSeg) {
                throw InstagramURLError.unrecognised(original)
            }
            guard looksLikeHandle(segment) else {
                throw InstagramURLError.unrecognised(original)
            }
            return InstagramURL(kind: .profile, value: segment.lowercased())
        }
    }
}
