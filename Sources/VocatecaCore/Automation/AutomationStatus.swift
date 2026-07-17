// swift/Sources/VocatecaCore/Automation/AutomationStatus.swift
import Foundation

/// Why the daemon's heavy drain did (or didn't) run on the last cycle.
public enum AutomationSkipReason: String, Codable, Sendable {
    case ok
    case notPro
    case dailyCheckDisabled
    case outsideProcessingWindow
    case onBattery
    case lowPowerMode
    case noAutoDownloadShows
}

/// Observable snapshot of the automation daemon, persisted in StateStore meta so
/// it survives restart and is readable by the menu bar, Settings, and the CLI.
public struct AutomationStatus: Codable, Sendable, Equatable {
    public var lastRunAt: String?
    public var nextRunAt: String?
    public var processed: Int
    public var done: Int
    public var failed: Int
    /// The highest-priority blocker — the one-line summary.
    public var lastSkipReason: AutomationSkipReason
    /// EVERY blocker in effect on the last cycle. Blockers stack (Low Power Mode
    /// AND on battery), and a surface that names only the first sends the user to
    /// fix one thing and watch nothing change. Empty for older records written
    /// before this field existed → falls back to `[lastSkipReason]` on decode.
    public var lastSkipReasons: [AutomationSkipReason]

    public init(lastRunAt: String? = nil, nextRunAt: String? = nil,
                processed: Int = 0, done: Int = 0, failed: Int = 0,
                lastSkipReason: AutomationSkipReason = .ok,
                lastSkipReasons: [AutomationSkipReason]? = nil) {
        self.lastRunAt = lastRunAt; self.nextRunAt = nextRunAt
        self.processed = processed; self.done = done; self.failed = failed
        self.lastSkipReason = lastSkipReason
        self.lastSkipReasons = lastSkipReasons ?? (lastSkipReason == .ok ? [] : [lastSkipReason])
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastRunAt = try c.decodeIfPresent(String.self, forKey: .lastRunAt)
        nextRunAt = try c.decodeIfPresent(String.self, forKey: .nextRunAt)
        processed = try c.decodeIfPresent(Int.self, forKey: .processed) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        let reason = try c.decodeIfPresent(AutomationSkipReason.self, forKey: .lastSkipReason) ?? .ok
        lastSkipReason = reason
        lastSkipReasons = try c.decodeIfPresent([AutomationSkipReason].self, forKey: .lastSkipReasons)
            ?? (reason == .ok ? [] : [reason])
    }

    /// The StateStore meta key this status is persisted under.
    public static let metaKey = "automation_status"

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) -> AutomationStatus? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutomationStatus.self, from: data)
    }
}
