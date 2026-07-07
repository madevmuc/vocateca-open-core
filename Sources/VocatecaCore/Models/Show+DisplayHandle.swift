import Foundation

// MARK: - Show+DisplayHandle

extension Show {

    /// A best-effort platform @handle for display, derived from the source URL.
    ///
    /// - **youtube**: `"@" + handle` when `rss` is a `/@handle` URL
    ///   (``YouTubeURL`` `.handle` kind); else if `author` looks like a handle
    ///   (starts with `"@"`) return `author` unchanged; else `nil`.
    /// - **instagram**: `"@" + handle` when `rss` parses to an
    ///   ``InstagramURL`` `.profile` or `.story` kind.
    /// - **podcast / anything else**: `nil`.
    ///
    /// Always `nil` for empty or unparseable input. Never throws.
    /// Never produces a double-`@@` result — any existing leading `@` on the
    /// extracted value is stripped before the single `@` is prepended.
    public var displayHandle: String? {
        switch source {
        case "youtube":
            return youtubeDisplayHandle
        case "instagram":
            return instagramDisplayHandle
        default:
            return nil
        }
    }

    // MARK: - Private helpers

    private var youtubeDisplayHandle: String? {
        guard !rss.isEmpty else { return nil }

        // Try to parse the RSS URL as a YouTube /@handle URL.
        if let parsed = try? YouTubeURL.parse(rss), parsed.kind == .handle {
            // .value is the handle without leading "@"
            let raw = parsed.value.hasPrefix("@") ? String(parsed.value.dropFirst()) : parsed.value
            return "@\(raw)"
        }

        // Fallback: if `author` itself looks like an @handle, use it as-is.
        if let a = author, a.hasPrefix("@"), !a.dropFirst().isEmpty {
            return a
        }

        return nil
    }

    private var instagramDisplayHandle: String? {
        guard !rss.isEmpty else { return nil }

        guard let parsed = try? InstagramURL.parse(rss) else { return nil }

        switch parsed.kind {
        case .profile, .story:
            // .value is already lowercased and without leading "@"
            let raw = parsed.value.hasPrefix("@") ? String(parsed.value.dropFirst()) : parsed.value
            return "@\(raw)"
        case .reel, .post:
            // Reel/post shortcodes are not account handles
            return nil
        }
    }
}
