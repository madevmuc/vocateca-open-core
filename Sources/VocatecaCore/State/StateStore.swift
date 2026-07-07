import Foundation
import GRDB

/// Read-write state store for **Swift-owned** Vocateca databases.
///
/// `StateStore` is the counterpart to `StateReader`:
///
/// | Type          | Opens as   | Runs migrations | Use for                         |
/// |---------------|------------|-----------------|---------------------------------|
/// | `StateReader` | read-only  | never           | Live production DB (Python app) |
/// | `StateStore`  | read-write | yes (v2 schema) | Swift-owned DBs, test DBs       |
///
/// ## Safety contract
/// Do **not** instantiate `StateStore` against the production database at
/// `~/Library/Application Support/Vocateca/state.sqlite`. That file is
/// co-owned by the Python app; opening it read-write (or running migrations on
/// it) would corrupt the production data. Use `StateReader.openProduction()`
/// for the live file.
///
/// ## Thread safety
/// `DatabaseQueue` serialises all database access through a single internal
/// serial queue. `StateStore` is `Sendable` and safe to call from any actor or
/// thread.
public struct StateStore: Sendable {

    // MARK: - Storage

    // `internal` (not private) so Pipeline/StateStore+Worker.swift extensions
    // within the same module can access the queue directly without re-exporting
    // full DB access publicly.
    internal let dbQueue: DatabaseQueue

    // MARK: - Initialisation

    /// Opens (or creates) a SQLite database at `databaseURL` in **read-write**
    /// mode and — when `runMigrations` is `true` (the default) — runs
    /// `Schema.migrator` to bring it up to the v2 schema.
    ///
    /// - Parameters:
    ///   - databaseURL: File URL for the SQLite database. Created if absent.
    ///   - runMigrations: Whether to run `Schema.migrator` on open. Pass
    ///     `false` only in tests that want to inspect a specific schema state.
    /// - Throws: Any GRDB or migration error.
    public init(databaseURL: URL, runMigrations: Bool = true) throws {
        Log.debug("StateStore opening",
                  component: "StateStore",
                  context: [("path", databaseURL.path),
                             ("migrations", runMigrations ? "yes" : "no")])
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: Self.makeConfiguration(isInMemory: false)
        )
        try self.init(dbQueue: queue, label: databaseURL.path, runMigrations: runMigrations)
    }

    /// Opens an ephemeral in-memory database (migrations applied). Used for
    /// preview/no-op controllers and degraded fallback — nothing is written to
    /// disk, so a failed production-DB open can never silently spill ingested
    /// data into a throwaway `/tmp` file.
    public static func inMemory() throws -> StateStore {
        Log.debug("StateStore opening (in-memory)", component: "StateStore", context: [])
        // No-path init gives an independent, process-local in-memory database
        // (GRDB 6.x `DatabaseQueue()` — see GRDB/Core/DatabaseQueue.swift).
        let queue = try DatabaseQueue(configuration: Self.makeConfiguration(isInMemory: true))
        return try StateStore(dbQueue: queue, label: ":memory:", runMigrations: true)
    }

    /// Shared setup: runs migrations (if requested) and the additive-tables
    /// safety net against an already-opened `DatabaseQueue`.
    private init(dbQueue: DatabaseQueue, label: String, runMigrations: Bool) throws {
        self.dbQueue = dbQueue
        if runMigrations {
            // The production DB may already carry the full v2 schema but an
            // empty/external `grdb_migrations` record (created by the Python/v1
            // path or promoted from an earlier DB). The GRDB migrator then sees
            // zero applied migrations and tries to re-CREATE existing tables,
            // which throws "table already exists" on EVERY open — previously that
            // was caught and logged as a WARN with the full CREATE-TABLE dump on
            // each of the many opens per session (noisy + alarming). Detect the
            // already-initialised case up front and SKIP the base migrator (no
            // throw, no warning); the additive-tables ensure below still runs so
            // v2/v3 tables are present. (Long-term: stamp grdb_migrations.)
            let alreadyInitialised = (try? dbQueue.read { db in
                try db.tableExists("episodes")
            }) ?? false
            if alreadyInitialised {
                Log.debug("StateStore: base schema already present — skipping migrator",
                          component: "StateStore", context: [("path", label)])
            } else {
                Log.debug("StateStore running migrations", component: "StateStore",
                          context: [("path", label)])
                do {
                    try Schema.migrator.migrate(dbQueue)
                } catch {
                    // M6: on a FRESH DB (no `episodes` table yet — e.g. disk full
                    // during CREATE TABLE, or a genuinely new install), a migrator
                    // failure must THROW rather than warn-and-continue. The old
                    // behaviour let the app run against a tableless DB: every
                    // subsequent write went through a `try?` at the call site and
                    // was silently swallowed (ingested episodes vanished with no
                    // error surfaced anywhere). Callers of this initializer
                    // already have a degraded path for a throwing open — see
                    // `QueueController`, `IngestCoordinator.openProductionStore()`,
                    // and the `AppShell` daemon-store guard, all of which log +
                    // surface a banner and skip just that subsystem rather than
                    // limping along on a half-built schema.
                    //
                    // The EXISTING-DB skip path above (`alreadyInitialised == true`)
                    // is untouched — this only fires for a genuinely fresh DB.
                    Log.error("StateStore migration failed on a fresh DB — aborting open",
                              component: "StateStore",
                              context: [("path", label), ("error", "\(error)")])
                    throw error
                }
            }
            // Safety net: whether or not the migrator ran, ensure the additive
            // v2/v3 tables exist. On the Python-owned production DB the migrator
            // aborts on v1_base, so watchlist_hits / Instagram tables would
            // otherwise be missing (silently breaking the Watchlist).
            do {
                try dbQueue.write { db in try Schema.ensureAdditiveTables(db) }
            } catch {
                Log.warn("StateStore: ensureAdditiveTables failed",
                         component: "StateStore",
                         context: [("path", label), ("error", "\(error)")])
            }
        }
        Log.debug("StateStore ready",
                  component: "StateStore",
                  context: [("path", label)])
    }

    /// Builds the shared `Configuration` — WAL + busy timeout — used by every
    /// `StateStore` connection.
    ///
    /// Multiple `StateStore` connections (ingest, queue worker, UI, plus the
    /// read-only `StateReader`) open the SAME file concurrently. With the
    /// default config a second writer — or a migration — that hits a held
    /// lock gets `SQLITE_BUSY` *immediately* and throws. Callers wrapped that
    /// in `try?` and silently fell back to a throwaway `/tmp` DB, so freshly
    /// ingested episodes were written to a temp file and lost (e.g. "Ingest
    /// complete new=850" but 0 rows in the real DB). Fix: WAL (concurrent
    /// reader + single writer) and a busy timeout so writers/migrations WAIT
    /// for the lock instead of failing.
    private static func makeConfiguration(isInMemory: Bool) -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // Capture the actual journal mode SQLite applied — in-memory
            // databases can never be WAL (SQLite silently uses "memory"
            // instead), so only warn on a real on-disk downgrade.
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            let lowered = mode?.lowercased() ?? ""
            if !isInMemory && lowered != "wal" {
                Log.warn("StateStore: WAL not enabled — concurrency downgraded",
                         component: "StateStore", context: [("mode", mode ?? "nil")])
            }
        }
        return config
    }

    // MARK: - Read: episodes

    /// All episodes, ordered by `pub_date` descending.
    public func allEpisodes() throws -> [Episode] {
        try dbQueue.read { db in
            try Episode.order(Column("pub_date").desc).fetchAll(db)
        }
    }

    /// The episode with the given `guid`, or `nil` if not found.
    public func episode(guid: String) throws -> Episode? {
        try dbQueue.read { db in
            try Episode.fetchOne(db, key: guid)
        }
    }

    /// All episodes belonging to `showSlug`, ordered by `pub_date` descending.
    public func episodes(showSlug: String) throws -> [Episode] {
        try dbQueue.read { db in
            try Episode
                .filter(Column("show_slug") == showSlug)
                .order(Column("pub_date").desc)
                .fetchAll(db)
        }
    }

    /// All episodes currently parked as `.deferred` ("Zurückgestellt"), ordered
    /// by `pub_date` descending (newest first — mirrors the default queue order).
    ///
    /// Backs the Queue screen's collapsible "Zurückgestellt (N)" section: these
    /// episodes were removed from the active queue via `removeFromQueue` but are
    /// NOT deleted — they stay queryable here until the user either reinstates
    /// them (`requeue(guids:)` → back to `pending`) or terminally removes them
    /// (`setStatus(.skipped)`).
    public func deferredEpisodes() throws -> [Episode] {
        try dbQueue.read { db in
            try Episode
                .filter(Column("status") == EpisodeStatus.deferred.rawValue)
                .order(Column("pub_date").desc)
                .fetchAll(db)
        }
    }

    /// Total number of rows in `episodes`.
    public func episodeCount() throws -> Int {
        try dbQueue.read { db in
            try Episode.fetchCount(db)
        }
    }

    /// Row counts grouped by `status` value.
    public func episodeCountByStatus() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                SQLRequest(sql: "SELECT status, COUNT(*) AS cnt FROM episodes GROUP BY status")
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["status"] as String, $0["cnt"] as Int) })
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

    // MARK: - Read: meta

    /// The `value` stored for `key` in the `meta` table, or `nil`.
    public func metaValue(_ key: String) throws -> String? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
            )
            return row?["value"]
        }
    }

    // MARK: - Write: episodes

    /// Inserts `episode` or **fully replaces** the existing row with the same
    /// `guid` (GRDB `PersistableRecord.upsert`, INSERT OR REPLACE semantics).
    ///
    /// - Warning: This is a *full-row* replace. It is NOT the Python feed-refresh
    ///   upsert (`state.py::upsert_episode`), which preserves pipeline state on
    ///   conflict (keeps `status`/`attempts`/`transcript_path`, only updates
    ///   `title`/`pub_date`/`mp3_url`, `COALESCE`s `duration_sec`). Phase 2 must
    ///   add that targeted feed-ingest upsert separately — do NOT use this to
    ///   ingest feed items or it will wipe in-flight episode state.
    public func upsert(_ episode: Episode) throws {
        try dbQueue.write { db in
            try episode.upsert(db)
        }
    }

    /// Resets orphaned in-flight episodes (`downloading` / `transcribing`) back to
    /// `pending`. Call this on startup / when the queue is not running: a fresh
    /// process has nothing actually in-flight, so any such rows are leftovers from
    /// a previous session that was killed mid-download/-transcribe. Without this,
    /// the Queue shows stale "Downloading"/"Now transcribing" while stopped.
    ///
    /// `downloaded` is intentionally left as-is (a valid resumable checkpoint).
    ///
    /// ## Poison-pill guard
    /// Each reclaim now **bumps `attempts`** on the reclaimed rows. Previously it
    /// didn't, and because `attempts` only increments on *caught* errors, an
    /// episode that crashes the process mid-transcribe (OOM / Metal fault) was
    /// silently reset to `pending` on every launch and re-tried forever — a crash
    /// loop under auto-start / the daemon. After bumping, any episode that has now
    /// been reclaimed `>= maxAttempts` (3) times is marked `failed` with a
    /// diagnostic reason instead of `pending`, so it drops out of the queue and
    /// surfaces via the standard failed-episode notification scan.
    ///
    /// ## Live-owner guard (H7 — App + CLI parallel)
    /// A row that is genuinely in-flight in a *concurrent* process (the app while a
    /// `vocateca-cli queue run` drains, or vice-versa) must NOT be reclaimed —
    /// doing so double-transcribes the episode and races two writers onto the same
    /// `.part` file. Each such row is skipped when the `jobs` ownership ledger shows
    /// an open heartbeat row whose owning PID is a *different, still-alive* process
    /// with a *fresh* heartbeat (see `StateStore+Jobs.swift`). Only genuinely
    /// orphaned rows (no job row, dead PID, or stale heartbeat) are reclaimed. The
    /// current process's own leftover job rows never count as a live owner (they're
    /// from the prior, now-dead run), so a normal solo relaunch reclaims exactly as
    /// before.
    ///
    /// - Parameters:
    ///   - maxAttempts: poison-pill threshold (see above).
    ///   - selfPID: this process's PID (rows owned by it are treated as orphans, not
    ///     live siblings). Defaults to the running process.
    ///   - staleSeconds: heartbeat age beyond which an open job counts as orphaned.
    ///   - isAlive: liveness probe for an owner PID (injectable for tests).
    /// - Returns: the number of rows reset (to `pending` **or** `failed`). Rows left
    ///   alone because a live sibling owns them are NOT counted.
    @discardableResult
    public func reclaimOrphanedInFlight(
        maxAttempts: Int = Pipeline.maxAttempts,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        staleSeconds: TimeInterval = StateStore.defaultJobStaleSeconds,
        isAlive: @escaping (Int32) -> Bool = processIsAlive
    ) throws -> Int {
        let now = Date()
        return try dbQueue.write { db in
            // Snapshot the in-flight rows BEFORE mutating, so we can log per-guid
            // and split pending vs poison-pill on the post-bump attempt count.
            let rows = try Row.fetchAll(db, sql: """
                SELECT guid, COALESCE(attempts, 0) AS attempts
                FROM episodes
                WHERE status IN ('downloading', 'transcribing')
            """)
            guard !rows.isEmpty else { return 0 }

            var changed = 0
            for row in rows {
                let guid = row["guid"] as String
                // H7: skip a row a live sibling process is actively working on.
                if try isOwnedByLiveProcess(db, guid: guid, selfPID: selfPID,
                                            now: now, staleSeconds: staleSeconds,
                                            isAlive: isAlive) {
                    Log.info("Reclaim: skipped — episode owned by a live process",
                             component: "StateStore", context: [("guid", guid)])
                    continue
                }
                let newAttempts = (row["attempts"] as Int) + 1
                if newAttempts >= maxAttempts {
                    // Poison pill: reclaimed too many times → fail it (drop out of
                    // the queue) rather than crash-loop. Standard failure scan
                    // seeds the notification from the stored error_text.
                    let reason = "crashed while processing (reclaimed \(newAttempts) times)"
                    try db.execute(sql: """
                        UPDATE episodes
                        SET status = 'failed', attempts = ?, error_text = ?,
                            error_category = ?
                        WHERE guid = ?
                    """, arguments: [newAttempts, reason, ErrorCategory.crash, guid])
                    Log.warn("Reclaim: poison-pill episode marked failed",
                             component: "StateStore",
                             context: [("guid", guid), ("attempts", "\(newAttempts)")])
                } else {
                    try db.execute(sql: """
                        UPDATE episodes SET status = 'pending', attempts = ?
                        WHERE guid = ?
                    """, arguments: [newAttempts, guid])
                    Log.info("Reclaim: reset orphaned in-flight episode to pending",
                             component: "StateStore",
                             context: [("guid", guid), ("attempts", "\(newAttempts)")])
                }
                changed += 1
            }
            return changed
        }
    }

    // MARK: - Write: meta

    /// Sets `key` → `value` in `meta`, inserting or replacing.
    public func setMeta(key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    // MARK: - Write: events

    /// Appends a lifecycle event row to `events`.
    ///
    /// - Parameters:
    ///   - type: Event type string (e.g. `"episode.done"`).
    ///   - showSlug: Optional show slug for filtering.
    ///   - guid: Optional episode guid for filtering.
    ///   - payloadJSON: JSON-encoded payload string. Defaults to `"{}"`.
    public func appendEvent(
        type: String,
        showSlug: String? = nil,
        guid: String? = nil,
        payloadJSON: String = "{}"
    ) throws {
        // Use the same ISO-8601 UTC `+00:00` format as Event.nowISO() / Python
        // now_iso(), so every events.ts value is consistent regardless of whether
        // the row came through the EventBus or this direct path.
        let ts = Event.nowISO()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO events (ts, type, show_slug, guid, payload_json)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [ts, type, showSlug, guid, payloadJSON]
            )
        }
    }

    // MARK: - Write: Instagram enumeration cursor

    /// Upserts the per-profile enumeration cursor in `instagram_enumeration_cursor`.
    ///
    /// Called by `InstagramEnumerator.persistCursor(showSlug:shortcode:store:)` after
    /// each successful enumeration pass.
    ///
    /// - Parameters:
    ///   - showSlug: The show's slug (primary key).
    ///   - lastShortcodeSeen: The shortcode of the newest item processed in this pass.
    ///   - lastEnumerationAt: ISO-8601 UTC timestamp of the enumeration run.
    public func upsertInstagramCursor(
        showSlug: String,
        lastShortcodeSeen: String,
        lastEnumerationAt: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO instagram_enumeration_cursor
                        (show_slug, last_shortcode_seen, last_enumeration_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(show_slug) DO UPDATE SET
                        last_shortcode_seen = excluded.last_shortcode_seen,
                        last_enumeration_at = excluded.last_enumeration_at
                """,
                arguments: [showSlug, lastShortcodeSeen, lastEnumerationAt]
            )
        }
    }

    /// Reads the enumeration cursor for `showSlug`, returning `(lastShortcode, lastAt)`
    /// or `nil` when no cursor exists yet.
    public func instagramCursor(showSlug: String) throws -> (lastShortcode: String, lastAt: String)? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                SQLRequest(sql: """
                    SELECT last_shortcode_seen, last_enumeration_at
                    FROM instagram_enumeration_cursor
                    WHERE show_slug = ?
                """, arguments: [showSlug])
            )
            guard let r = row,
                  let sc: String = r["last_shortcode_seen"] else { return nil }
            let at: String = r["last_enumeration_at"] ?? ""
            return (sc, at)
        }
    }

    // MARK: - Write: slug reservations

    /// Reserves `slug` for `guid` in `slug_reservations`, idempotent.
    ///
    /// Matches the Python `StateStore.reserve_slug` semantics for the common
    /// case where the caller already knows the exact slug to reserve. The
    /// Swift equivalent of the hash-suffix collision-avoidance lives in the
    /// pipeline layer (Phase 2), not here.
    ///
    /// - Throws: A GRDB error if the slug is already claimed by a *different*
    ///   guid (i.e. a PRIMARY KEY or UNIQUE constraint violation).
    public func reserveSlug(_ slug: String, guid: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO slug_reservations (slug, guid) VALUES (?, ?)
                    ON CONFLICT(guid) DO NOTHING
                """,
                arguments: [slug, guid]
            )
        }
    }

    // MARK: - Write/Read: integration deliveries

    /// Records a delivery attempt of an episode's transcript to an external
    /// integration (e.g. Notion, a generic webhook). Append-only — used later
    /// for idempotency checks (`lastDelivery`) and status/history surfacing.
    public func recordDelivery(
        integration: String,
        episodeGuid: String?,
        target: String?,
        status: String,
        externalRef: String?,
        errorText: String?
    ) throws {
        let row = IntegrationDelivery(
            id: UUID().uuidString,
            integration: integration,
            episodeGuid: episodeGuid,
            target: target,
            status: status,
            externalRef: externalRef,
            deliveredAt: Date().iso8601,
            errorText: errorText
        )
        try dbQueue.write { db in try row.insert(db) }
    }

    /// The most recent delivery of `episodeGuid` to `integration`, or `nil` if
    /// none has been recorded yet.
    public func lastDelivery(integration: String, episodeGuid: String) throws -> IntegrationDelivery? {
        try dbQueue.read { db in
            try IntegrationDelivery
                .filter(Column("integration") == integration && Column("episode_guid") == episodeGuid)
                .order(Column("delivered_at").desc)
                .fetchOne(db)
        }
    }

    /// All recorded deliveries (any integration) for `episodeGuid`.
    public func deliveries(episodeGuid: String) throws -> [IntegrationDelivery] {
        try dbQueue.read { db in
            try IntegrationDelivery.filter(Column("episode_guid") == episodeGuid).fetchAll(db)
        }
    }
}
