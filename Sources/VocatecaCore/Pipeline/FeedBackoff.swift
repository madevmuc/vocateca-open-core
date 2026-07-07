import Foundation

// MARK: - FeedBackoff

/// Feed polling backoff: after `_THRESHOLD` consecutive failures, pause the
/// feed for an escalating number of days.
///
/// Ported byte-for-byte from `core/backoff.py`. Meta keys are identical to the
/// Python implementation so they interoperate with an existing state database:
///
/// | Meta key                      | Content                              |
/// |-------------------------------|--------------------------------------|
/// | `feed_fail_count:<slug>`      | Consecutive failure count (int str)  |
/// | `feed_backoff_until:<slug>`   | ISO-8601 UTC timestamp (or `""`)     |
/// | `feed_health:<slug>`          | `"ok"` or `"fail"`                   |
/// | `feed_fail_category:<slug>`   | Short error category string          |
/// | `feed_fail_message:<slug>`    | Last raw error text (truncated)      |
/// | `feed_fail_at:<slug>`         | ISO-8601 timestamp of last failure   |
///
/// ## Backoff schedule (from Python constants)
/// - `_THRESHOLD = 3`           — first backoff triggers at the 3rd failure
/// - `_STAGES_DAYS = (1, 3, 7)` — failure 3 → 1 day, failure 4 → 3 days,
///                                 failure 5+ → 7 days
///
/// `now` is injected for deterministic unit tests; production callers pass
/// `Date()`.
public enum FeedBackoff {

    // MARK: - Constants (mirrors Python)

    /// Consecutive-failure count that triggers the first backoff.
    /// `_THRESHOLD = 3` in `core/backoff.py`.
    static let threshold: Int = 3

    /// Pause durations for each escalation stage (days).
    /// `_STAGES_DAYS = (1, 3, 7)` in `core/backoff.py`.
    static let stagesDays: [Int] = [1, 3, 7]

    // MARK: - onSuccess

    /// Records a successful feed poll: resets the failure count and clears the
    /// backoff timestamp and health fields.
    ///
    /// Mirrors `backoff.on_success(state, slug)`:
    /// ```python
    /// state.set_meta(f"feed_fail_count:{slug}", "0")
    /// state.set_meta(f"feed_backoff_until:{slug}", "")
    /// state.set_meta(f"feed_health:{slug}", "ok")
    /// state.set_meta(f"feed_fail_category:{slug}", "")
    /// state.set_meta(f"feed_fail_message:{slug}", "")
    /// state.set_meta(f"feed_fail_at:{slug}", "")
    /// ```
    ///
    /// - Parameters:
    ///   - showSlug: The show's slug (used as the meta-key suffix).
    ///   - store:    The state store to write into.
    public static func onSuccess(showSlug: String, store: StateStore) throws {
        try store.setMeta(key: "feed_fail_count:\(showSlug)", value: "0")
        try store.setMeta(key: "feed_backoff_until:\(showSlug)", value: "")
        try store.setMeta(key: "feed_health:\(showSlug)", value: "ok")
        try store.setMeta(key: "feed_fail_category:\(showSlug)", value: "")
        try store.setMeta(key: "feed_fail_message:\(showSlug)", value: "")
        try store.setMeta(key: "feed_fail_at:\(showSlug)", value: "")
    }

    // MARK: - onFailure

    /// Records a failed feed poll: increments the consecutive failure count and
    /// sets a backoff timestamp when the count reaches the threshold.
    ///
    /// Mirrors `backoff.on_failure(state, slug, exc)` (exc is omitted here; the
    /// caller may set `feed_fail_category`/`feed_fail_message`/`feed_fail_at`
    /// separately if needed):
    ///
    /// ```python
    /// count = int(raw) + 1
    /// if count >= _THRESHOLD:
    ///     stage_idx = min(count - _THRESHOLD, len(_STAGES_DAYS) - 1)
    ///     days = _STAGES_DAYS[stage_idx]
    ///     until = datetime.now(timezone.utc) + timedelta(days=days)
    ///     state.set_meta(f"feed_backoff_until:{slug}", until.isoformat())
    /// state.set_meta(f"feed_health:{slug}", "fail")
    /// ```
    ///
    /// - Parameters:
    ///   - showSlug: The show's slug.
    ///   - store:    The state store to write into.
    ///   - now:      Current time (inject for deterministic tests).
    /// - Returns: The new consecutive failure count.
    @discardableResult
    public static func onFailure(showSlug: String, store: StateStore, now: Date = Date()) throws -> Int {
        let raw = try store.metaValue("feed_fail_count:\(showSlug)") ?? "0"
        let count = (Int(raw) ?? 0) + 1
        try store.setMeta(key: "feed_fail_count:\(showSlug)", value: "\(count)")

        if count >= threshold {
            let stageIdx = min(count - threshold, stagesDays.count - 1)
            let days = stagesDays[stageIdx]
            let until = now.addingTimeInterval(Double(days) * 86400.0)
            // Mirror Python's datetime.isoformat() with explicit +00:00 UTC offset,
            // which is what Python produces for timezone.utc aware datetimes.
            // Example: "2026-06-29T12:34:56.789000+00:00"
            let isoString = isoISO8601(until)
            try store.setMeta(key: "feed_backoff_until:\(showSlug)", value: isoString)
        }

        try store.setMeta(key: "feed_health:\(showSlug)", value: "fail")
        return count
    }

    // MARK: - inBackoff

    /// Returns `true` if the feed is currently in backoff (should not be polled).
    ///
    /// Mirrors `backoff.in_backoff(state, slug)`:
    /// ```python
    /// until = state.get_meta(f"feed_backoff_until:{slug}") or ""
    /// if not until:
    ///     return False
    /// return datetime.fromisoformat(until) > datetime.now(timezone.utc)
    /// ```
    ///
    /// - Parameters:
    ///   - showSlug: The show's slug.
    ///   - store:    The state store to read from.
    ///   - now:      Current time (inject for deterministic tests).
    /// - Returns: `true` if `now` is before the backoff-until timestamp.
    public static func inBackoff(showSlug: String, store: StateStore, now: Date = Date()) throws -> Bool {
        let until = try store.metaValue("feed_backoff_until:\(showSlug)") ?? ""
        guard !until.isEmpty else { return false }
        guard let untilDate = parseISO8601(until) else { return false }
        return untilDate > now
    }

    // MARK: - ISO-8601 helpers

    /// Format a `Date` as an ISO-8601 string with microseconds and `+00:00` suffix,
    /// matching Python's `datetime.isoformat()` for UTC-aware datetimes.
    ///
    /// Python: `datetime.now(timezone.utc).isoformat()`
    /// produces e.g. `"2026-06-29T12:34:56.789000+00:00"` (6 decimal places).
    ///
    /// We emit 6 decimal places to match Python's microsecond precision.
    static func isoISO8601(_ date: Date) -> String {
        // TimeInterval is in seconds; extract microseconds.
        let ti = date.timeIntervalSince1970
        let wholeSeconds = Int64(floor(ti))
        let microseconds = Int(((ti - floor(ti)) * 1_000_000).rounded())

        var t = time_t(wholeSeconds)
        var tm = tm()
        gmtime_r(&t, &tm)

        let year   = Int(tm.tm_year) + 1900
        let month  = Int(tm.tm_mon) + 1
        let day    = Int(tm.tm_mday)
        let hour   = Int(tm.tm_hour)
        let minute = Int(tm.tm_min)
        let second = Int(tm.tm_sec)

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00",
            year, month, day, hour, minute, second, microseconds
        )
    }

    /// Parse an ISO-8601 timestamp string into a `Date`.
    ///
    /// Accepts the formats Python emits for `timezone.utc` datetimes:
    /// - `"2026-06-29T12:34:56.789000+00:00"`
    /// - `"2026-06-29T12:34:56+00:00"`
    /// - `"2026-06-29T12:34:56.789000"` (no offset, treated as UTC per Python fromisoformat)
    /// - `"2026-06-29T12:34:56"`
    ///
    /// Returns `nil` for unparseable strings (matching Python's `ValueError` handler).
    static func parseISO8601(_ s: String) -> Date? {
        // Try the system ISO8601 parser with fractional seconds first.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }

        // Without fractional seconds.
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: s) { return d }

        // Python fromisoformat without timezone suffix — treat as UTC.
        let noOffset = DateFormatter()
        noOffset.locale = Locale(identifier: "en_US_POSIX")
        noOffset.timeZone = TimeZone(identifier: "UTC")
        noOffset.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let d = noOffset.date(from: s) { return d }
        noOffset.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return noOffset.date(from: s)
    }
}
