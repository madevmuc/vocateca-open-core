import Foundation
import GRDB

/// A persisted Watchlist keyword-match hit (row of `watchlist_hits`).
public struct WatchlistHitRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let termID: String
    public let showSlug: String?
    public let episodeGuid: String?
    public let snippet: String
    public let matchedAt: String
    public let read: Bool

    public init(
        id: String, termID: String, showSlug: String?, episodeGuid: String?,
        snippet: String, matchedAt: String, read: Bool
    ) {
        self.id = id
        self.termID = termID
        self.showSlug = showSlug
        self.episodeGuid = episodeGuid
        self.snippet = snippet
        self.matchedAt = matchedAt
        self.read = read
    }
}

extension StateStore {

    /// Inserts (or replaces by id) a Watchlist hit.
    public func insertWatchlistHit(_ hit: WatchlistHitRow) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO watchlist_hits
                        (id, term_id, show_slug, episode_guid, snippet, matched_at, read)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [hit.id, hit.termID, hit.showSlug, hit.episodeGuid,
                            hit.snippet, hit.matchedAt, hit.read ? 1 : 0]
            )
        }
        Log.debug("Watchlist hit stored", component: "Watchlist",
                  context: [("term", hit.termID), ("show", hit.showSlug ?? "-")])
    }

    /// Marks one hit read/unread.
    public func markWatchlistHitRead(id: String, read: Bool = true) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE watchlist_hits SET read = ? WHERE id = ?",
                           arguments: [read ? 1 : 0, id])
        }
    }

    /// Marks every hit read.
    public func markAllWatchlistHitsRead() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE watchlist_hits SET read = 1 WHERE read = 0")
        }
    }

    /// Deletes all hits for a term (e.g. when the term is removed).
    public func deleteWatchlistHits(termID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM watchlist_hits WHERE term_id = ?", arguments: [termID])
        }
    }

    /// Deletes hits whose term no longer exists (orphans). Pass the CURRENT term
    /// IDs; anything not in the set is removed. With an empty set, all hits are
    /// deleted (no terms → no hits). Used to clean up after a term is deleted
    /// mid-scan (the scan can re-insert hits for a just-deleted term).
    public func deleteOrphanWatchlistHits(keepingTermIDs termIDs: [String]) throws {
        try dbQueue.write { db in
            if termIDs.isEmpty {
                try db.execute(sql: "DELETE FROM watchlist_hits")
                return
            }
            let placeholders = databaseQuestionMarks(count: termIDs.count)
            try db.execute(
                sql: "DELETE FROM watchlist_hits WHERE term_id NOT IN (\(placeholders))",
                arguments: StatementArguments(termIDs))
        }
    }

    public func fetchWatchlistHits(unreadOnly: Bool = false, limit: Int = 500) throws -> [WatchlistHitRow] {
        try dbQueue.read { db in try StateStore.readWatchlistHits(db, unreadOnly: unreadOnly, limit: limit) }
    }

    public func unreadWatchlistHitCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watchlist_hits WHERE read = 0") ?? 0
        }
    }

    /// Whether a hit already exists for this (term, episode) pair — used by the
    /// backfill to stay idempotent.
    public func watchlistHitExists(termID: String, episodeGuid: String) throws -> Bool {
        try dbQueue.read { db in
            let n = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM watchlist_hits WHERE term_id = ? AND episode_guid = ?",
                arguments: [termID, episodeGuid]
            ) ?? 0
            return n > 0
        }
    }

    /// Shared row reader (used by both `StateStore` and `StateReader`).
    static func readWatchlistHits(_ db: Database, unreadOnly: Bool, limit: Int) throws -> [WatchlistHitRow] {
        var sql = "SELECT * FROM watchlist_hits"
        if unreadOnly { sql += " WHERE read = 0" }
        sql += " ORDER BY matched_at DESC"
        if limit > 0 { sql += " LIMIT \(limit)" }
        let rows = try Row.fetchAll(db, sql: sql)
        return rows.map { r in
            WatchlistHitRow(
                id: r["id"], termID: r["term_id"],
                showSlug: r["show_slug"], episodeGuid: r["episode_guid"],
                snippet: r["snippet"] ?? "", matchedAt: r["matched_at"],
                read: (r["read"] as Int? ?? 0) != 0
            )
        }
    }
}
