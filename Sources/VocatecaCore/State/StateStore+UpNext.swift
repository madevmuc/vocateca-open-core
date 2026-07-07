import Foundation
import GRDB

extension StateStore {

    /// Guids currently in Up Next (`pending`, `priority > 0`), ordered top→bottom.
    public func upNextGuidsOrdered() throws -> [String] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT guid FROM episodes
                WHERE status = 'pending' AND priority > 0
                ORDER BY priority DESC
            """).map { $0["guid"] as String }
        }
    }

    /// Rewrite Up Next `priority` so `orderedGuids` are ranked top→bottom (dense
    /// descending). Only affects `pending` rows; Coming-up (priority 0) is untouched.
    public func reorderUpNext(orderedGuids: [String]) throws {
        try dbQueue.write { db in
            let ranks = UpNextRanker.rank(count: orderedGuids.count)
            for (i, g) in orderedGuids.enumerated() {
                try db.execute(
                    sql: "UPDATE episodes SET priority = ? WHERE guid = ? AND status = 'pending'",
                    arguments: [ranks[i], g])
            }
        }
        Log.info("UpNext: reorder", component: "Pipeline",
                 context: [("count", "\(orderedGuids.count)")])
        emitUpNextEvent(EventType.queueUpNextReordered, guids: orderedGuids)
    }

    /// Add `guids` to Up Next at `position`. Eligible statuses: `pending`/`deferred`
    /// (deferred is flipped to `pending`). In-flight/terminal guids are skipped.
    /// The whole Up Next set is re-ranked so it stays dense + above Coming-up.
    public func moveToUpNext(guids: [String], position: UpNextPosition) throws {
        var eligible: [String] = []
        try dbQueue.write { db in
            for g in guids {
                let st = try String.fetchOne(db,
                    sql: "SELECT status FROM episodes WHERE guid = ?", arguments: [g])
                guard st == "pending" || st == "deferred" else { continue }
                try db.execute(sql: "UPDATE episodes SET status = 'pending' WHERE guid = ?",
                               arguments: [g])
                eligible.append(g)
            }
            guard !eligible.isEmpty else { return }

            let current = try Row.fetchAll(db, sql: """
                SELECT guid FROM episodes
                WHERE status = 'pending' AND priority > 0
                ORDER BY priority DESC
            """).map { $0["guid"] as String }.filter { !eligible.contains($0) }

            let newOrder = (position == .top) ? (eligible + current) : (current + eligible)
            let ranks = UpNextRanker.rank(count: newOrder.count)
            for (i, g) in newOrder.enumerated() {
                try db.execute(sql: "UPDATE episodes SET priority = ? WHERE guid = ?",
                               arguments: [ranks[i], g])
            }
        }
        Log.info("UpNext: add", component: "Pipeline",
                 context: [("count", "\(guids.count)"), ("pos", position == .top ? "top" : "bottom")])
        emitUpNextEvent(EventType.queueUpNextAdded, guids: eligible,
                        extra: ["position": .string(position == .top ? "top" : "bottom")])
    }

    /// Drop `guids` from Up Next back to Coming up (`priority = 0`), keeping `pending`.
    public func removeFromUpNext(guids: [String]) throws {
        var affected: [String] = []
        try dbQueue.write { db in
            for g in guids {
                // Only rows actually IN Up Next (pending, priority > 0) are real
                // removals — capture them for the audit event before zeroing.
                let inUpNext = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM episodes WHERE guid = ? AND status = 'pending' AND priority > 0",
                    arguments: [g]) ?? 0
                try db.execute(
                    sql: "UPDATE episodes SET priority = 0 WHERE guid = ? AND status = 'pending'",
                    arguments: [g])
                if inUpNext > 0 { affected.append(g) }
            }
        }
        Log.info("UpNext: remove", component: "Pipeline", context: [("count", "\(guids.count)")])
        emitUpNextEvent(EventType.queueUpNextRemoved, guids: affected)
    }

    /// Appends a durable audit event for an Up-Next curation action, post-commit.
    /// Best-effort: a logging failure never rolls back the (already committed)
    /// priority change — it is logged and swallowed. No-op when `guids` is empty
    /// (nothing actually changed). For a single-guid action the event carries that
    /// guid for per-episode filterability; batches use `guid = nil` + the payload
    /// `guids` array.
    private func emitUpNextEvent(_ type: String, guids: [String], extra: [String: JSONValue] = [:]) {
        guard !guids.isEmpty else { return }
        var payload: [String: JSONValue] = [
            "count": .number(Double(guids.count)),
            "guids": .array(guids.map { .string($0) }),
        ]
        for (k, v) in extra { payload[k] = v }
        let single = guids.count == 1 ? guids[0] : nil
        let event = Event(type: type, showSlug: nil, guid: single, payload: payload)
        do {
            try appendEvent(type: type, showSlug: nil, guid: single,
                            payloadJSON: event.payloadJSONString())
        } catch {
            Log.error("UpNext: audit event append failed", component: "Pipeline",
                      context: [("type", type), ("error", "\(error)")])
        }
    }
}
