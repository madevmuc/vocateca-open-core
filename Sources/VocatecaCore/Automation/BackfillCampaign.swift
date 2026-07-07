import Foundation

/// One show's bulk-backfill campaign — a controlled, resumable un-deferring of its
/// `.deferred` back-catalog into the queue in throttled top-ups. Persisted as one
/// JSON blob per show in StateStore meta (`backfill_campaign:<slug>`), mirroring
/// `AutomationStatus`.
public struct BackfillCampaign: Codable, Sendable, Equatable {
    public var active: Bool
    public var paused: Bool
    /// Max campaign episodes kept in the queue at once (keep-K-in-flight throttle).
    public var batchSize: Int
    /// Scope vocabulary, reused from backfill: "all" / "last_n" / "since_date".
    public var scope: String
    public var scopeN: Int
    public var scopeSince: String
    /// Scope size at campaign start (denominator for progress).
    public var total: Int
    /// Episodes transcribed so far (numerator).
    public var done: Int
    public var startedAt: String

    public init(active: Bool, paused: Bool, batchSize: Int, scope: String,
                scopeN: Int, scopeSince: String, total: Int, done: Int, startedAt: String) {
        self.active = active; self.paused = paused; self.batchSize = batchSize
        self.scope = scope; self.scopeN = scopeN; self.scopeSince = scopeSince
        self.total = total; self.done = done; self.startedAt = startedAt
    }

    public static func metaKey(slug: String) -> String { "backfill_campaign:\(slug)" }

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func decode(_ json: String) -> BackfillCampaign? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BackfillCampaign.self, from: data)
    }
}

/// Pure keep-K-in-flight top-up math. `toEnqueue` = how many more of a show's
/// `.deferred` episodes to un-defer so the queue holds at most `batchSize`
/// campaign episodes at once.
public enum BackfillPlanner {
    public static func toEnqueue(batchSize: Int, activeCampaignCount: Int, remainingDeferred: Int) -> Int {
        max(0, min(remainingDeferred, batchSize - activeCampaignCount))
    }
}
