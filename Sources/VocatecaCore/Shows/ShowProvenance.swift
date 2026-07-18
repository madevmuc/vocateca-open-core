import Foundation

/// The platform a show's episodes originate from. Persisted as `Show.source`
/// (a raw string) and mirrored here as a typed enum for routing.
public enum SourcePlatform: String, Codable, Sendable, Equatable, CaseIterable {
    case podcast, youtube, instagram, other

    /// Map a raw `Show.source` string (tolerant of unknowns → `.other`).
    ///
    /// `"ytdlp"` (a generic yt-dlp playlist/channel subscription — see
    /// `WatchlistStore.addYtDlp`) maps to `.youtube`: it is a real, pollable
    /// `Show.source` with no dedicated pick sheet, and the YouTube add sheet is
    /// the closest URL-resolving reconnect surface. Without this it would fall to
    /// `.other` → the podcast/RSS picker → bind `source = "podcast"` → the show
    /// becomes unpollable (RSS parse against a non-RSS URL).
    public init(showSource: String) {
        switch showSource.lowercased() {
        case "ytdlp": self = .youtube
        case let raw:  self = SourcePlatform(rawValue: raw) ?? .other
        }
    }
}

/// Durable, orphaning-proof provenance for one show slug. Stored in the DB
/// `meta` table under `provenance:<slug>` so it survives the loss of the
/// `watchlist.yaml` entry (which is exactly what "orphaned" means).
public struct ShowProvenance: Codable, Sendable, Equatable {
    public var platform: SourcePlatform
    /// The re-usable origin address: RSS URL, YouTube channel URL, or Instagram
    /// profile URL/handle. May be empty when only the platform is known.
    public var sourceURL: String
    /// ISO8601 timestamp when this record was last written.
    public var capturedAt: String
    /// When set (ISO8601, future), reconnect for this show is soft-deferred —
    /// used by the Instagram "retry tomorrow" path. `nil` = active.
    public var deferredUntil: String?

    public init(platform: SourcePlatform, sourceURL: String,
                capturedAt: String, deferredUntil: String? = nil) {
        self.platform = platform
        self.sourceURL = sourceURL
        self.capturedAt = capturedAt
        self.deferredUntil = deferredUntil
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public init(jsonString: String) throws {
        self = try JSONDecoder().decode(ShowProvenance.self,
                                        from: Data(jsonString.utf8))
    }

    /// The DB `meta` key for a slug.
    public static func metaKey(slug: String) -> String { "provenance:\(slug)" }
}

/// Pure reconstruction of a show's platform + a re-usable seed from its episode
/// rows, for legacy orphans that never wrote a provenance record. Extracted so
/// it is unit-testable without a DB (mirrors `OrphanedShows`).
public enum ProvenanceRecovery {
    /// The only episode fields provenance recovery needs.
    public struct EpisodeSignal: Sendable, Equatable {
        public var guid: String
        public var mp3Url: String
        public var igProfile: String?
        public init(guid: String, mp3Url: String, igProfile: String?) {
            self.guid = guid; self.mp3Url = mp3Url; self.igProfile = igProfile
        }
    }

    /// Recovered platform + seed. `sourceURL` is a best-effort address: an
    /// Instagram profile when known, otherwise a de-slugified title to seed the
    /// platform's search (YouTube/podcast have no direct URL recoverable from a
    /// media URL alone).
    public static func recover(slug: String, signals: [EpisodeSignal]) -> ShowProvenance {
        let seed = deslugify(slug)
        // Instagram: any episode carrying a profile is decisive.
        if let ig = signals.compactMap({ $0.igProfile })
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return ShowProvenance(platform: .instagram, sourceURL: ig,
                                  capturedAt: "", deferredUntil: nil)
        }
        // YouTube: guid `yt:` prefix or a youtube/googlevideo media host.
        let looksYouTube = signals.contains { s in
            s.guid.hasPrefix("yt:") || hostContains(s.mp3Url, any: ["youtube.", "googlevideo.", "ytimg."])
        }
        if looksYouTube {
            return ShowProvenance(platform: .youtube, sourceURL: seed,
                                  capturedAt: "", deferredUntil: nil)
        }
        // Default: podcast (rss unknown → user searches with the seed).
        return ShowProvenance(platform: .podcast, sourceURL: seed,
                              capturedAt: "", deferredUntil: nil)
    }

    static func deslugify(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
    }

    private static func hostContains(_ urlString: String, any needles: [String]) -> Bool {
        let host = URL(string: urlString)?.host?.lowercased() ?? urlString.lowercased()
        return needles.contains { host.contains($0) }
    }
}
