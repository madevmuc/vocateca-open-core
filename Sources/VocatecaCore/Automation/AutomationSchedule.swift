// swift/Sources/VocatecaCore/Automation/AutomationSchedule.swift
import Foundation

/// Whether the app shows a Dock icon (`.regular`) or is menu-bar-only (`.accessory`).
/// Pure Core enum; `VocatecaUI` maps it to `NSApplication.ActivationPolicy`.
public enum DockPolicy: Sendable, Equatable { case regular, accessory }

/// Pure, timezone-injectable scheduling + gating helpers for the automation
/// daemon. Kept in Core (no AppKit) so it is fully unit-testable; `AutomationRunner`
/// (closed Pro module) calls into it.
public enum AutomationSchedule {

    /// Seconds until the next `HH:MM` fire in `calendar`'s timezone (default local).
    /// Replaces the old UTC-only computation.
    public static func nextFireDelayLocal(
        dailyTimeHHMM: String, reference: Date, calendar: Calendar = .current
    ) -> TimeInterval {
        guard let slot = slotToday(dailyTimeHHMM, reference: reference, calendar: calendar) else { return 0 }
        let delay = slot.timeIntervalSince(reference)
        return delay > 0 ? delay : delay + 86_400
    }

    /// True when today's slot has already passed and the last successful run was
    /// before it — i.e. a run was missed (app closed / asleep at the slot).
    public static func didMissSlot(
        lastRunISO: String?, dailyTimeHHMM: String, now: Date, calendar: Calendar = .current
    ) -> Bool {
        guard let slot = slotToday(dailyTimeHHMM, reference: now, calendar: calendar) else { return false }
        guard slot <= now else { return false }               // today's slot not reached yet
        guard let lastISO = lastRunISO,
              let last = ISO8601DateFormatter().date(from: lastISO) else { return true }  // never ran
        return last < slot                                    // last run predates today's slot
    }

    /// The single reason the heavy drain will (`.ok`) or won't run, in priority order.
    public static func skipReason(
        isPro: Bool, dailyCheckEnabled: Bool, withinWindow: Bool,
        onBattery: Bool, lowPowerMode: Bool, hasAutoShows: Bool
    ) -> AutomationSkipReason {
        if !isPro { return .notPro }
        if !dailyCheckEnabled { return .dailyCheckDisabled }
        if lowPowerMode { return .lowPowerMode }
        if onBattery { return .onBattery }
        if !withinWindow { return .outsideProcessingWindow }
        if !hasAutoShows { return .noAutoDownloadShows }
        return .ok
    }

    /// Dock icon visibility: hidden only when background mode is on, the user opted
    /// to hide it, and no window is currently open.
    public static func dockPolicy(
        runInBackground: Bool, hideDockIconInBackground: Bool, windowOpen: Bool
    ) -> DockPolicy {
        (runInBackground && hideDockIconInBackground && !windowOpen) ? .accessory : .regular
    }

    // MARK: - Private

    private static func slotToday(_ hhmm: String, reference: Date, calendar: Calendar) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: reference)
        comps.hour = h; comps.minute = m; comps.second = 0
        return calendar.date(from: comps)
    }
}
