import Foundation
import GRDB

/// Read-only gateway into the Vocateca SQLite state database.
///
/// Opens the database in read-only mode so it is safe to use against the live
/// production file while the Python app is running (WAL sidecars are
/// respected by SQLite's shared-cache and WAL reader protocol).
public struct StateReader: Sendable {
    // MARK: - Storage

    private let dbQueue: DatabaseQueue

    // MARK: - Initialisation

    /// Opens `databaseURL` for **reading** an OWNED database file (a snapshot
    /// copy — NOT the live shared DB).
    ///
    /// Opens read-write but sets `PRAGMA query_only = ON`, which guarantees no
    /// content mutation while still letting SQLite rebuild/attach the `-shm`
    /// shared-memory file. Strict `readonly = true` instead fails with SQLite
    /// error 14 (SQLITE_CANTOPEN) on a WAL-mode database whose copied `-shm` is
    /// stale/absent — which is exactly the case for a snapshot copy.
    ///
    /// - Important: Do NOT point this at the live shared `state.sqlite` — opening
    ///   it read-write would touch its `-wal`/`-shm` sidecars, violating the
    ///   copy-first rule. Use ``openProduction()`` / ``openProductionForReading()``
    ///   (which snapshot first) for the live database.
    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.readonly = false
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
    }

    // MARK: - Convenience factories

    /// Returns a `StateReader` over a **consistent snapshot** of the live
    /// production database, or `nil` when the database file does not yet exist
    /// (fresh install / CI). Snapshots first (copy-first safety) — the live
    /// shared DB is never opened read-write. Alias of ``openProductionForReading()``.
    public static func openProduction() throws -> StateReader? {
        try openProductionForReading()
    }

    /// Returns a `StateReader` over a **consistent snapshot** of the live
    /// production database, or `nil` if it does not exist.
    ///
    /// Copies `state.sqlite` (+ `-wal`/`-shm`) to a temp directory and opens the
    /// COPY via ``init(databaseURL:)`` (read-write + `query_only`). This never
    /// touches the live shared file's sidecars (copy-first safety) and is robust
    /// against the live WAL state (no SQLite error 14). The temp copy is left for
    /// the OS to reap (callers are short-lived, e.g. the CLI).
    public static func openProductionForReading() throws -> StateReader? {
        let url = Paths.stateDatabaseURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Fast path: a read-only WAL connection to the LIVE database — no file
        // copy. SQLite's WAL reader protocol gives each read transaction a
        // consistent view even while the writer (or the Python app) is active, so
        // the previous copy-first snapshot (a ~6 MB `copyItem` on EVERY read) was
        // pure overhead in the app. Copy-first is kept as a fallback for the rare
        // case where a strict read-only open fails (e.g. a stale/absent `-shm`).
        if let live = try? openLiveReadOnly(url: url) { return live }
        let snapshot = try snapshotProduction(of: url)
        return try StateReader(databaseURL: snapshot)
    }

    /// Opens the LIVE database strictly read-only (no copy, no sidecar writes).
    private static func openLiveReadOnly(url: URL) throws -> StateReader {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return StateReader(dbQueue: queue)
    }

    /// Copies the live DB trio to a fresh temp dir and returns the copy's main
    /// `.sqlite` URL. Read-only on the source; safe while the Python app runs.
    public static func snapshotProduction(of source: URL) throws -> URL {
        let fm = FileManager.default
        // Best-effort sweep of stale snapshots (>1h old) so per-invocation copies
        // don't accumulate at rest. Ignore errors — purely housekeeping.
        sweepStaleSnapshots(olderThan: 3600, fileManager: fm)
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("VocatecaSnap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent("state.sqlite")
        try fm.copyItem(at: source, to: dest)
        let dir = source.deletingLastPathComponent()
        for sidecar in ["-wal", "-shm"] {
            let s = dir.appendingPathComponent("state.sqlite\(sidecar)")
            if fm.fileExists(atPath: s.path) {
                try fm.copyItem(at: s, to: tmp.appendingPathComponent("state.sqlite\(sidecar)"))
            }
        }
        return dest
    }

    /// Removes leftover `VocatecaSnap-*` temp directories older than `maxAge`
    /// seconds. Best-effort housekeeping; all errors are ignored.
    private static func sweepStaleSnapshots(olderThan maxAge: TimeInterval, fileManager fm: FileManager) {
        let tmpRoot = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries where url.lastPathComponent.hasPrefix("VocatecaSnap-") {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Memberwise init — used internally by the factories above.
    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Queries

    /// Total number of rows in `episodes`.
    public func episodeCount() throws -> Int {
        try dbQueue.read { db in
            try EpisodeRow.fetchCount(db)
        }
    }

    /// Number of transcribed episodes whose `completed_at` is strictly after the
    /// given ISO timestamp — powers the Library "new since last opened" badge.
    /// A nil/empty cutoff counts all done episodes.
    public func doneCount(completedAfterISO cutoff: String?) throws -> Int {
        try dbQueue.read { db in
            if let cutoff, !cutoff.isEmpty {
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM episodes
                    WHERE status = 'done' AND completed_at IS NOT NULL AND completed_at > ?
                """, arguments: [cutoff]) ?? 0
            }
            return try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM episodes WHERE status = 'done'") ?? 0
        }
    }

    /// Row counts grouped by `status` value (e.g. `["done": 3699, "failed": 2]`).
    public func episodeCountByStatus() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: "SELECT status, COUNT(*) AS cnt FROM episodes GROUP BY status")
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["status"] as String, $0["cnt"] as Int) })
        }
    }

    /// Global summary of literal-`pending` episodes (post-subscribe-nba brief
    /// §2): the count, and the newest `pub_date` among them.
    ///
    /// Deliberately narrower than `episodeCountByStatus()["pending"]`'s sibling
    /// counts used elsewhere (e.g. `ShowsViewModel.ShowItem.pendingCount`,
    /// which is `total - done - failed` and so also counts `deferred`,
    /// `downloading`, etc.) — the Shows „Nächster Schritt"-bar keys on literal
    /// `pending` only, per wave-1 safe-by-default semantics: a `deferred`
    /// episode was deliberately held back (auto-download off for its show),
    /// so it must not read as "ready to transcribe".
    ///
    /// - Returns: `(count, newestPubDate)`. `newestPubDate` is `nil` when
    ///   `count == 0` or every pending row has an empty `pub_date`.
    public func pendingSummary() throws -> (count: Int, newestPubDate: String?) {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT COUNT(*) AS cnt, MAX(pub_date) AS newest
                    FROM episodes
                    WHERE status = 'pending'
                """)
            )
            let count: Int = row?["cnt"] ?? 0
            let newest: String? = row?["newest"]
            return (count: count, newestPubDate: (newest?.isEmpty ?? true) ? nil : newest)
        }
    }

    /// All `guid`s of literal-`pending` episodes, across every show, newest
    /// first — backs the „Nächster Schritt"-Leiste's "Alle transkribieren"
    /// action (post-subscribe-nba brief §2). Sibling to `fetchFailed`'s
    /// cross-show query shape; guid-only (not full `Episode` rows) since the
    /// caller only needs IDs to enqueue.
    public func allPendingGuids() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, SQLRequest(sql: """
                SELECT guid FROM episodes WHERE status = 'pending' ORDER BY pub_date DESC
            """))
        }
    }

    /// Number of distinct `show_slug` values in `episodes`.
    public func distinctShowCount() throws -> Int {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT COUNT(DISTINCT show_slug) AS n FROM episodes")
            )
            return row?["n"] ?? 0
        }
    }

    /// Total number of rows in `meta`.
    public func metaCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, SQLRequest(sql: "SELECT COUNT(*) FROM meta")) ?? 0
        }
    }

    /// Fetches up to `limit` episodes for the given `showSlug`, ordered by
    /// `pub_date` descending.
    public func fetchEpisodes(showSlug: String, limit: Int) throws -> [EpisodeRow] {
        try dbQueue.read { db in
            try EpisodeRow
                .filter(Column("show_slug") == showSlug)
                .order(Column("pub_date").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Returns the `show_slug` with the most episodes, or `nil` if empty.
    public func mostPopularShowSlug() throws -> String? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT show_slug
                    FROM episodes
                    GROUP BY show_slug
                    ORDER BY COUNT(*) DESC
                    LIMIT 1
                """)
            )
            return row?["show_slug"]
        }
    }

    /// All episodes, ordered by `pub_date` descending.
    ///
    /// Used by the Phase 1 oracle test and future diagnostics. For large
    /// databases this materialises the full table; callers that need paged or
    /// filtered results should use `fetchEpisodes(showSlug:limit:)`.
    public func allEpisodes() throws -> [Episode] {
        try dbQueue.read { db in
            try Episode.order(Column("pub_date").desc).fetchAll(db)
        }
    }

    /// The episode with the given `guid`, or `nil`.
    public func episode(guid: String) throws -> Episode? {
        try dbQueue.read { db in
            try Episode.fetchOne(db, key: guid)
        }
    }

    /// Returns the `value` stored in `meta` for the given `key`, or `nil`.
    public func metaValue(forKey key: String) throws -> String? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
            )
            return row?["value"]
        }
    }

    // MARK: - CLI parity queries (Phase 5 WP2)

    /// Counts for all statuses for a given show slug.
    public func episodeCountsByStatus(forShowSlug slug: String) throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: """
                    SELECT status, COUNT(*) AS cnt
                    FROM episodes
                    WHERE show_slug = ?
                    GROUP BY status
                """, arguments: [slug])
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["status"] as String, $0["cnt"] as Int) })
        }
    }

    /// Fetches episodes for a show, with optional status filter and limit.
    /// Ordered by pub_date DESC, matching Python's `ORDER BY pub_date DESC`.
    public func fetchEpisodesBySlug(showSlug: String, statusFilter: String?, limit: Int) throws -> [Episode] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM episodes WHERE show_slug = ?"
            var args: [DatabaseValueConvertible] = [showSlug]
            if let s = statusFilter {
                sql += " AND status = ?"
                args.append(s)
            }
            sql += " ORDER BY pub_date DESC"
            if limit > 0 {
                sql += " LIMIT \(limit)"
            }
            return try Episode.fetchAll(db, SQLRequest(sql: sql, arguments: StatementArguments(args)))
        }
    }

    /// Fetches failed episodes across shows (or for one show), ordered by
    /// `attempted_at DESC NULLS LAST`, matching Python exactly.
    public func fetchFailed(showSlug: String?, limit: Int) throws -> [Episode] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM episodes WHERE status = 'failed'"
            var args: [DatabaseValueConvertible] = []
            if let s = showSlug {
                sql += " AND show_slug = ?"
                args.append(s)
            }
            sql += " ORDER BY attempted_at DESC NULLS LAST"
            if limit > 0 {
                sql += " LIMIT \(limit)"
            }
            return try Episode.fetchAll(db, SQLRequest(sql: sql, arguments: StatementArguments(args)))
        }
    }

    /// Episodes skipped because no speech was detected (e.g. music). These are the
    /// only `.skipped` rows that carry an `error_text` (the skip reason), so the
    /// non-empty `error_text` filter distinguishes them from other skips. Used to
    /// seed the informational "looks like music — no speech" notification.
    public func fetchNoSpeechSkips(limit: Int) throws -> [Episode] {
        try dbQueue.read { db in
            var sql = """
                SELECT * FROM episodes
                WHERE status = 'skipped' AND error_text IS NOT NULL AND error_text != ''
                ORDER BY attempted_at DESC NULLS LAST
            """
            if limit > 0 { sql += " LIMIT \(limit)" }
            return try Episode.fetchAll(db, SQLRequest(sql: sql))
        }
    }

    /// Most recent `pub_date` per show slug —
    /// `SELECT show_slug, MAX(pub_date) FROM episodes GROUP BY show_slug`.
    ///
    /// `pub_date` is stored as an ISO-ish string, so lexical `MAX` matches
    /// chronological order. Shows whose max is `NULL` (no dated episodes) are
    /// omitted. Used by the Shows table "Last release" column and sorting.
    public func latestPubDates() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: "SELECT show_slug, MAX(pub_date) AS latest FROM episodes GROUP BY show_slug")
            )
            var result: [String: String] = [:]
            for row in rows {
                guard let slug: String = row["show_slug"], let latest: String = row["latest"] else { continue }
                result[slug] = latest
            }
            return result
        }
    }

    /// Watchlist keyword-match hits, most recent first (feature B).
    public func fetchWatchlistHits(unreadOnly: Bool = false, limit: Int = 500) throws -> [WatchlistHitRow] {
        try dbQueue.read { db in try StateStore.readWatchlistHits(db, unreadOnly: unreadOnly, limit: limit) }
    }

    /// All distinct `show_slug` values in `episodes`, sorted alphabetically.
    ///
    /// Used by ``LiveDataLoader`` to discover DB-only shows — slugs that exist in
    /// the DB but have been removed from (or not yet written to) watchlist.yaml.
    public func allShowSlugs() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: "SELECT DISTINCT show_slug FROM episodes ORDER BY show_slug")
            )
            return rows.map { $0["show_slug"] as String }
        }
    }

    /// Distinct `show_slug` values whose episodes are **entirely** one-off /
    /// local-origin — every episode GUID is `local:`-prefixed
    /// (``LocalIngestService/isOneOffGuid``), i.e. no feed ever produced any of
    /// them.
    ///
    /// Used by ``LiveDataLoader`` to tell a genuinely-orphaned subscription (a
    /// real feed whose watchlist entry was lost — its episodes carry the feed's
    /// own `<guid>`) apart from a one-off (a single dragged file / folder /
    /// "Import once" URL that never had a pollable feed). A one-off is complete
    /// as-is, so it must NOT be surfaced as "lost its feed" / offered a Reconnect
    /// — see ``OrphanedShows/enumerate(dbShowSlugs:watchlistShows:countsBySlug:oneOffSlugs:)``.
    ///
    /// A slug qualifies iff it has episodes AND none of them has a non-`local:`
    /// GUID. Implemented as "all slugs minus any slug that has at least one
    /// feed-origin (non-`local:`) episode".
    public func localOnlyShowSlugs() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: """
                    SELECT DISTINCT show_slug FROM episodes
                    WHERE show_slug NOT IN (
                        SELECT show_slug FROM episodes WHERE guid NOT LIKE 'local:%'
                    )
                """)
            )
            return Set(rows.map { $0["show_slug"] as String })
        }
    }

    /// COUNT(*) over the events table with optional type/since filters.
    public func countEvents(typeExact: String?, since: String?) throws -> Int {
        try dbQueue.read { db in
            var sql = "SELECT COUNT(*) AS n FROM events"
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let t = typeExact { clauses.append("type = ?"); args.append(t) }
            if let s = since     { clauses.append("ts >= ?");  args.append(s) }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            let row = try Row.fetchOne(db, SQLRequest(sql: sql, arguments: StatementArguments(args)))
            return row?["n"] ?? 0
        }
    }

    /// Realtime factor matching Python's `realtime_factor()` in `core/stats.py`.
    /// Computed from the most recent `sampleLimit` completed episodes.
    /// Returns 0.25 when there is no usable history (matching Python default).
    public func realtimeFactor(sampleLimit: Int = 50) throws -> Double {
        let rowTuples: [(String, String, Int)] = try dbQueue.read { db in
            let raw = try Row.fetchAll(
                db,
                SQLRequest(sql: """
                    SELECT attempted_at, completed_at, duration_sec
                    FROM episodes
                    WHERE status='done'
                      AND attempted_at IS NOT NULL
                      AND completed_at IS NOT NULL
                      AND duration_sec > 0
                    ORDER BY completed_at DESC
                    LIMIT ?
                """, arguments: [sampleLimit])
            )
            return raw.compactMap { row -> (String, String, Int)? in
                guard
                    let a: String = row["attempted_at"],
                    let b: String = row["completed_at"],
                    let d: Int    = row["duration_sec"]
                else { return nil }
                return (a, b, d)
            }
        }
        if rowTuples.isEmpty { return 0.25 }

        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String) -> Date? {
            isoWithFrac.date(from: s) ?? isoBasic.date(from: s)
        }

        var totalWall  = 0.0
        var totalAudio = 0
        for (a, b, d) in rowTuples {
            guard let da = parseDate(a), let db2 = parseDate(b) else { continue }
            let wall = db2.timeIntervalSince(da)
            if wall < 5 || wall > 3600 { continue }
            totalWall  += wall
            totalAudio += d
        }
        if totalAudio <= 0 { return 0.25 }
        return totalWall / Double(totalAudio)
    }

    /// Builds the dashboard summary dict matching Python's `dashboard_summary()`.
    /// Keys: throughput_per_day, success_rate, realtime_factor, done, pending, failed.
    public func dashboardSummary(windowDays: Int) throws -> [String: Any] {
        let wDays = max(windowDays, 1)
        let cutoff: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            formatter.timeZone = TimeZone(identifier: "UTC")
            let cutoffDate = Date().addingTimeInterval(-Double(wDays) * 86400)
            return formatter.string(from: cutoffDate)
        }()

        let transcribedWindow = try countEvents(typeExact: "episode.transcribed", since: cutoff)
        let transcribedAll    = try countEvents(typeExact: "episode.transcribed", since: nil)
        let failedAll         = try countEvents(typeExact: "episode.failed",       since: nil)
        let finished          = transcribedAll + failedAll
        let successRate       = finished > 0 ? Double(transcribedAll) / Double(finished) : 0.0
        let tpd               = Double(transcribedWindow) / Double(wDays)
        let rf                = try realtimeFactor()
        let byStatus          = try episodeCountByStatus()

        return [
            "throughput_per_day": tpd,
            "success_rate":       successRate,
            "realtime_factor":    rf,
            "done":               byStatus["done"]    ?? 0,
            "pending":            byStatus["pending"] ?? 0,
            "failed":             byStatus["failed"]  ?? 0,
        ]
    }
}
