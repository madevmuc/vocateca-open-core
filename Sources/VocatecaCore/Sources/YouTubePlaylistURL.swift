import Foundation

/// Parses a YouTube playlist ID out of either a dedicated playlist link
/// (`/playlist?list=…`) or a video link that also carries a playlist
/// (`watch?v=…&list=…`). Sibling parser to `YouTubeURL` — kept separate
/// because `YouTubeURL.parse` classifies `watch?v=` links as `.video` and
/// never inspects a co-present `list=` query item.
public enum YouTubePlaylistURL {
    public static func playlistID(from url: String) -> String? {
        guard let comps = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = comps.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be")
        else { return nil }
        guard let raw = comps.queryItems?.first(where: { $0.name == "list" })?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return nil }
        return trimmed
    }
}
