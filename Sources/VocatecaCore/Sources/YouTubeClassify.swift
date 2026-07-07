import Foundation

// MARK: - YouTubeClassify

/// Oracle-locked port of `core/youtube_classify.py`.
///
/// Routes a YouTube video into a processing category from either yt-dlp metadata
/// (a dict) or a yt-dlp stderr error string. Pure function — no network, no I/O.
///
/// Do NOT change these algorithms without regenerating the golden fixtures and
/// running `swift test --filter OracleYouTubeTests`.
public enum YouTubeClassify {

    // MARK: - Category string constants

    /// Normal downloadable video (no message).
    public static let ok             = "ok"
    /// A YouTube Short (<= 60 s or `/shorts/` URL).
    public static let short          = "short"
    /// Live stream or premiere that has not finished (retry later).
    public static let live           = "live"
    /// Channel-members-only content.
    public static let membersOnly    = "members_only"
    /// Age-restricted video requiring sign-in.
    public static let ageRestricted  = "age_restricted"
    /// Blocked in the current region.
    public static let regionLocked   = "region_locked"

    // MARK: - User-facing messages (match Python _MESSAGES exactly)

    private static let messages: [String: String] = [
        short:         "YouTube Short.",
        live:          "Live/premiere \u{2014} will retry once it finishes.",
        membersOnly:   "Members-only video \u{2014} can't be downloaded.",
        ageRestricted: "Age-restricted \u{2014} needs sign-in, can't be downloaded.",
        regionLocked:  "Blocked in this region.",
    ]

    // MARK: - classify(meta:)

    /// Classify a video from yt-dlp metadata (dict).
    ///
    /// Port of `_classify_meta(meta)` from `core/youtube_classify.py`.
    ///
    /// Priority order:
    /// 1. Live/premiere (`live_status` in `{"is_live","is_upcoming","post_live"}` or `is_live` truthy)
    /// 2. Short (`/shorts/` URL or `duration <= 60`, None/missing duration is NOT a short)
    /// 3. `availability == "subscriber_only"` → members_only
    /// 4. `availability == "needs_auth"` or `age_limit >= 18` → age_restricted
    /// 5. Otherwise: ok
    ///
    /// - Parameter meta: The yt-dlp metadata dict encoded as `[String: JSONValue]`.
    /// - Returns: `(category, message)` tuple; message is `""` for `"ok"`.
    public static func classify(meta: [String: JSONValue]) -> (category: String, message: String) {
        // 1. Live / premiere
        let liveStatus = stringValue(meta["live_status"])
        if liveStatus == "is_live" || liveStatus == "is_upcoming" || liveStatus == "post_live" {
            return result(live)
        }
        if isTruthy(meta["is_live"]) {
            return result(live)
        }

        // 2. Short — /shorts/ URL or duration <= 60. None/missing is NOT a short.
        let url = stringValue(meta["url"]) ?? stringValue(meta["webpage_url"]) ?? ""
        if url.contains("/shorts/") {
            return result(short)
        }
        if let dur = numberValue(meta["duration"]) {
            if dur <= 60 {
                return result(short)
            }
        }

        // 3. Availability / age gates
        let availability = stringValue(meta["availability"])
        if availability == "subscriber_only" {
            return result(membersOnly)
        }
        let ageLimit = intValue(meta["age_limit"]) ?? 0
        if availability == "needs_auth" || ageLimit >= 18 {
            return result(ageRestricted)
        }

        return (ok, "")
    }

    // MARK: - classify(errorText:)

    /// Classify a video from a yt-dlp stderr/error string.
    ///
    /// Port of `_classify_error(text)` from `core/youtube_classify.py`.
    /// Matches known phrases case-insensitively as substrings, in priority order.
    ///
    /// - Parameter errorText: A yt-dlp stderr line or error description.
    /// - Returns: `(category, message)` tuple; `("ok", "")` for unrecognised errors.
    public static func classify(errorText: String) -> (category: String, message: String) {
        let lowered = errorText.lowercased()
        for (phrase, category) in errorPhrases {
            if lowered.contains(phrase) {
                return result(category)
            }
        }
        return (ok, "")
    }

    // MARK: - Private helpers

    private static func result(_ category: String) -> (String, String) {
        (category, messages[category] ?? "")
    }

    private static func stringValue(_ val: JSONValue?) -> String? {
        guard case .string(let s) = val else { return nil }
        return s
    }

    private static func numberValue(_ val: JSONValue?) -> Double? {
        guard case .number(let n) = val else { return nil }
        return n
    }

    private static func intValue(_ val: JSONValue?) -> Int? {
        guard case .number(let n) = val else { return nil }
        return Int(n)
    }

    private static func isTruthy(_ val: JSONValue?) -> Bool {
        switch val {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .null, nil: return false
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    // MARK: - Error phrases (ordered by priority, matches Python _ERROR_PHRASES)

    private static let errorPhrases: [(String, String)] = [
        ("join this channel to get access", membersOnly),
        ("members-only",                    membersOnly),
        ("members only",                    membersOnly),
        ("sign in to confirm your age",     ageRestricted),
        ("confirm your age",                ageRestricted),
        ("age-restricted",                  ageRestricted),
        ("inappropriate for some users",    ageRestricted),
        ("not made this video available in your country", regionLocked),
        ("not available in your country",   regionLocked),
        ("in your country",                 regionLocked),
        ("geo restrict",                    regionLocked),
        ("this live event will begin",      live),
        ("live event will begin",           live),
        ("premiere will begin",             live),
        ("premieres in",                    live),
        ("is live and",                     live),
    ]
}
