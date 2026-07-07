import Foundation

// MARK: - shouldCatchUp

/// Pure port of `core/scheduler.py :: should_catch_up`.
///
/// Decides whether a missed daily run should fire immediately on app launch.
///
/// ## Python signature (mirrored exactly):
/// ```python
/// def should_catch_up(
///     last_check_iso: Optional[str],
///     daily_time_hhmm: str,
///     now: Optional[datetime] = None
/// ) -> bool:
/// ```
///
/// ## Logic (port of Python implementation):
/// 1. Parse `dailyTimeHHMM` into (hour, minute).
/// 2. Build `todaySlot`: today's date (in the same timezone as `now`) at (hour, minute, second=0).
/// 3. If `lastCheckISO` is `nil`, return `true` — never ran, catch up unconditionally.
/// 4. If `now >= todaySlot` AND `lastCheck < todaySlot` → return `true`.
/// 5. Otherwise return `false`.
///
/// The injected `now` parameter makes this function fully testable without
/// depending on the real clock.
///
/// - Parameters:
///   - lastCheckISO: ISO-8601 string of the last successful check, or `nil` if never run.
///   - dailyTimeHHMM: The daily check time in `"HH:MM"` format (e.g. `"09:00"`).
///   - now: The current time. Defaults to `Date()` (UTC).
/// - Returns: `true` if the daily run was missed and should fire now.
///
/// - Note: Legacy/unused in production — superseded by `AutomationSchedule.didMissSlot`,
///   which is local-timezone (this function is UTC-only). Kept as a preserved
///   Python-parity artifact for `CatchUpOracleTests`; do not wire it back in.
public func shouldCatchUp(
    lastCheckISO: String?,
    dailyTimeHHMM: String,
    now: Date = Date()
) -> Bool {
    // Parse the HH:MM into components.
    let parts = dailyTimeHHMM.split(separator: ":")
    guard parts.count == 2,
          let hour = Int(parts[0]),
          let minute = Int(parts[1]) else {
        // Malformed time string — safe default: don't catch up.
        return false
    }

    // Build today's slot in UTC (matching Python's `timezone.utc` default).
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // Extract year/month/day from `now` in UTC.
    let nowComponents = cal.dateComponents([.year, .month, .day], from: now)
    var slotComponents = DateComponents()
    slotComponents.year   = nowComponents.year
    slotComponents.month  = nowComponents.month
    slotComponents.day    = nowComponents.day
    slotComponents.hour   = hour
    slotComponents.minute = minute
    slotComponents.second = 0
    slotComponents.timeZone = TimeZone(identifier: "UTC")!

    guard let todaySlot = cal.date(from: slotComponents) else {
        return false
    }

    // nil lastCheck → never ran → catch up.
    guard let isoString = lastCheckISO else {
        return true
    }

    // Parse the last-check ISO-8601 string.
    guard let lastCheck = parseISO8601(isoString) else {
        // Unparseable last-check → treat as never ran → catch up.
        return true
    }

    // Past today's slot & last check was before today's slot → catch up.
    return now >= todaySlot && lastCheck < todaySlot
}

// MARK: - ISO-8601 parsing

/// Parses an ISO-8601 date string into a `Date`. Accepts the full range of
/// formats Python's `datetime.fromisoformat` handles (offset-aware and naive).
///
/// Order of formats tried:
/// 1. `"yyyy-MM-dd'T'HH:mm:ssZZZZZ"` — with UTC offset (e.g. `+00:00`)
/// 2. `"yyyy-MM-dd'T'HH:mm:ssZ"` — with `Z` suffix
/// 3. `"yyyy-MM-dd'T'HH:mm:ss"` — naive (no timezone → interpreted as UTC)
/// 4. `"yyyy-MM-dd"` — date-only
private func parseISO8601(_ string: String) -> Date? {
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
    ]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")!
    for fmt in formats {
        formatter.dateFormat = fmt
        if let date = formatter.date(from: string) {
            return date
        }
    }
    return nil
}
