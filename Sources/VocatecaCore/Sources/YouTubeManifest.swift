import Foundation

// MARK: - YouTubeManifest

/// Oracle-locked port of `manifest_from_videos` from `core/youtube.py`.
///
/// Converts a flat yt-dlp playlist output into the canonical manifest the
/// upsert/backlog path expects.
///
/// Do NOT change this algorithm without regenerating the golden fixtures and
/// running `swift test --filter OracleYouTubeTests`.
public enum YouTubeManifest {

    // MARK: - ManifestEntry

    /// One entry in the manifest, mirroring the Python dict keys exactly
    /// (snake_case) so oracle JSON round-trips without any key remapping.
    public struct Entry: Sendable, Equatable {
        public let guid: String
        public let title: String
        public let pubDate: String
        public let mp3URL: String
        public let description: String
        /// `nil` when Python would emit `null` (missing, None, bool, or NaN duration).
        public let durationSec: Int?

        public init(
            guid: String,
            title: String,
            pubDate: String,
            mp3URL: String,
            description: String,
            durationSec: Int?
        ) {
            self.guid = guid
            self.title = title
            self.pubDate = pubDate
            self.mp3URL = mp3URL
            self.description = description
            self.durationSec = durationSec
        }
    }

    // MARK: - fromVideos(_:)

    /// Converts a list of yt-dlp video dicts into manifest entries.
    ///
    /// Port of `manifest_from_videos(videos)` from `core/youtube.py`:
    ///
    /// - Skips entries that have neither `id` nor `url`.
    /// - `guid` = `id` ?? `url`.
    /// - `pubDate`: derived from Unix epoch `timestamp` → `"YYYY-MM-DD"` (UTC),
    ///   or from `upload_date` `"YYYYMMDD"` → `"YYYY-MM-DD"`, else `""`.
    ///   A falsy `timestamp` (0, 0.0, null/missing) falls through to `upload_date`.
    /// - `mp3_url` = `"https://www.youtube.com/watch?v=<guid>"`.
    /// - `duration_sec`: `int(dur)` when `dur` is numeric and NOT bool; else `nil`.
    ///   Python's `isinstance(dur, bool)` guard means `True`/`False` → `nil`.
    ///
    /// - Parameter videos: Array of heterogeneous video dicts using ``JSONValue``.
    /// - Returns: Filtered, transformed manifest entries.
    public static func fromVideos(_ videos: [[String: JSONValue]]) -> [Entry] {
        var result: [Entry] = []

        for v in videos {
            // guid = v.get("id") or v.get("url") — skip if neither
            guard let guid = stringOrNil(v["id"]) ?? stringOrNil(v["url"]) else {
                continue
            }

            // pubDate derivation
            let pub = derivePubDate(timestamp: v["timestamp"], uploadDate: v["upload_date"])

            // duration_sec: numeric (not bool) -> int; else nil
            let durationSec = deriveDuration(v["duration"])

            result.append(Entry(
                guid: guid,
                title: stringOrNil(v["title"]) ?? guid,
                pubDate: pub,
                mp3URL: "https://www.youtube.com/watch?v=\(guid)",
                description: "",
                durationSec: durationSec
            ))
        }
        return result
    }

    // MARK: - mergeEntries(videos:shorts:)

    /// Merge the `/videos` tab and `/shorts` tab enumeration results into a
    /// single manifest.
    ///
    /// Order: `videos` entries first, then `shorts` entries, de-duplicated by
    /// `guid` (a video can appear in both tabs in edge cases). The first
    /// occurrence wins — since `videos` is listed first, a `guid` present in
    /// both keeps its `videos`-tab entry.
    ///
    /// - Parameters:
    ///   - videos: Entries from the `/videos` tab (possibly empty).
    ///   - shorts: Entries from the `/shorts` tab (possibly empty).
    /// - Returns: Combined, de-duplicated entries preserving relative order.
    public static func mergeEntries(videos: [Entry], shorts: [Entry]) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for entry in videos + shorts {
            guard !seen.contains(entry.guid) else { continue }
            seen.insert(entry.guid)
            result.append(entry)
        }
        return result
    }

    // MARK: - Private helpers

    /// Extract a non-empty String from a JSONValue, or nil.
    private static func stringOrNil(_ val: JSONValue?) -> String? {
        guard case .string(let s) = val, !s.isEmpty else { return nil }
        return s
    }

    /// Derive the pub date string from timestamp + upload_date.
    ///
    /// Mirrors Python:
    /// ```python
    /// ts = v.get("timestamp") or 0
    /// if ts:
    ///     pub = time.strftime("%Y-%m-%d", time.gmtime(int(ts)))
    /// elif v.get("upload_date"):
    ///     ud = str(v["upload_date"])
    ///     if len(ud) == 8 and ud.isdigit():
    ///         pub = f"{ud[:4]}-{ud[4:6]}-{ud[6:8]}"
    ///     else:
    ///         pub = ud
    /// ```
    private static func derivePubDate(timestamp: JSONValue?, uploadDate: JSONValue?) -> String {
        // ts = v.get("timestamp") or 0
        // Python `or 0` short-circuits to 0 when the value is falsy (None, 0, 0.0, False)
        let tsDouble: Double
        switch timestamp {
        case .number(let n) where n != 0.0:
            tsDouble = n
        default:
            tsDouble = 0
        }

        if tsDouble != 0 {
            // time.strftime("%Y-%m-%d", time.gmtime(int(ts)))
            let epochDate = Date(timeIntervalSince1970: floor(tsDouble))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let comps = cal.dateComponents([.year, .month, .day], from: epochDate)
            return String(
                format: "%04d-%02d-%02d",
                comps.year!, comps.month!, comps.day!
            )
        }

        // Fall through to upload_date
        // Python: `elif v.get("upload_date"):` — truthy (non-empty string)
        if let ud = uploadDateString(uploadDate), !ud.isEmpty {
            if ud.count == 8 && ud.allSatisfy(\.isNumber) {
                let y = String(ud.prefix(4))
                let m = String(ud.dropFirst(4).prefix(2))
                let d = String(ud.dropFirst(6).prefix(2))
                return "\(y)-\(m)-\(d)"
            } else {
                return ud
            }
        }
        return ""
    }

    /// Extract upload_date as a string from a JSONValue (it may be a number in some yt-dlp versions).
    private static func uploadDateString(_ val: JSONValue?) -> String? {
        switch val {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return String(Int(n))
        default: return nil
        }
    }

    /// Derive duration_sec from a JSONValue.
    ///
    /// Python: `int(dur) if isinstance(dur, (int, float)) and not isinstance(dur, bool) else None`
    ///
    /// In JSON there are no bool-typed numbers, BUT the Python fixtures encode
    /// `True`/`False` as JSON `true`/`false` (`.bool` case in JSONValue), so we
    /// exclude `.bool` and only accept `.number`.
    private static func deriveDuration(_ val: JSONValue?) -> Int? {
        guard case .number(let n) = val else { return nil }
        return Int(n)
    }
}
