import Foundation

// MARK: - ProcessingWindows

/// Pure gate for the Pro daemon's "only process within these time windows"
/// feature. Wires `Settings.processingWindowsEnabled` + `processingWindows`.
///
/// Each window is `"HH:MM-HH:MM"` (24h, local wall-clock). A window whose start is
/// later than its end wraps midnight (e.g. `"22:00-06:00"` = 22:00 → 06:00 next
/// day). When the feature is disabled or no valid windows are configured, the gate
/// is open (always allowed) — so an empty config never silently blocks the daemon.
public enum ProcessingWindows {

    /// Minutes-since-midnight for `"HH:MM"`, or `nil` if malformed.
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Parses `"HH:MM-HH:MM"` into (startMin, endMin), or `nil` if malformed.
    static func parse(_ window: String) -> (start: Int, end: Int)? {
        let parts = window.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let s = minutes(parts[0].trimmingCharacters(in: .whitespaces)),
              let e = minutes(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (s, e)
    }

    /// Whether `minuteOfDay` (0…1439) falls inside one window.
    static func contains(minuteOfDay: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }          // zero-length window matches nothing
        if start < end { return minuteOfDay >= start && minuteOfDay < end }
        // Overnight wrap: [start, 24:00) ∪ [00:00, end)
        return minuteOfDay >= start || minuteOfDay < end
    }

    /// The gate: is processing allowed at `now`?
    public static func isAllowed(now: Date, enabled: Bool, windows: [String],
                                 calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        let parsed = windows.compactMap(parse)
        guard !parsed.isEmpty else { return true }   // enabled but nothing valid → open
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return parsed.contains { contains(minuteOfDay: minuteOfDay, start: $0.start, end: $0.end) }
    }
}
