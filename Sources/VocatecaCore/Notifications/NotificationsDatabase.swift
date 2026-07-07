import Foundation
import GRDB

// MARK: - Persisted notification record

/// A notification record as stored in `notifications.sqlite`.
///
/// Kept in `VocatecaCore` so the UI layer can map to/from its own
/// `NotifItem` / `NotifKind` types at the boundary.
public struct NotificationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {

    // MARK: - Table

    public static let databaseTableName = "notification"

    // MARK: - Columns

    /// Stable string id; primary key. For failure notifications this is derived
    /// from the episode guid so re-seeding is idempotent.
    public var id: String

    /// One of: "accountSuspended", "accountReauth", "keywordHit",
    /// "runFinished", "backfillDone", "failure", "newEpisode", "dailySummary".
    public var kind: String

    public var title: String
    public var detail: String

    /// Human-readable relative timestamp shown in the UI (e.g. "14:20").
    public var timestamp: String

    /// `true` = user has not read this notification yet.
    public var isUnread: Bool

    /// Optional label for the primary action button (e.g. "Retry").
    public var actionLabel: String?

    /// Unix epoch seconds — used for ORDER BY newest-first. Separate from
    /// `timestamp` which is a display string.
    public var createdAt: Double

    // MARK: - New-episode metadata (v2, nullable — existing rows stay nil)

    /// GUID of the episode this notification refers to (newEpisode kind only).
    public var episodeGuid: String?

    /// Show slug of the episode this notification refers to (newEpisode kind only).
    public var showSlug: String?

    // MARK: - Triage state (v3, non-null with default 0 — existing rows are unresolved)

    /// `true` = the user has acted on / resolved this notification (Retry,
    /// Transcribe now, Ignore, Transcribe anyway). Resolved items drop out of the
    /// active triage buckets and surface under **Done**. Distinct from `isUnread`,
    /// which flips merely by viewing a row.
    public var isResolved: Bool

    // MARK: - Init

    public init(
        id: String,
        kind: String,
        title: String,
        detail: String,
        timestamp: String,
        isUnread: Bool = true,
        actionLabel: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        episodeGuid: String? = nil,
        showSlug: String? = nil,
        isResolved: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.isUnread = isUnread
        self.actionLabel = actionLabel
        self.createdAt = createdAt
        self.episodeGuid = episodeGuid
        self.showSlug = showSlug
        self.isResolved = isResolved
    }
}

// MARK: - NotificationsDatabase

/// Swift-owned SQLite database at `notifications.sqlite` for persistent
/// in-app notification storage.
///
/// ## Isolation guarantee
/// This is a **separate** database file from `state.sqlite`. The production
/// `state.sqlite` is co-owned by the Python v1 app and must never be touched
/// (opened read-only via `StateReader` only). This class only ever opens the
/// Swift-owned notifications file.
///
/// ## Thread safety
/// `DatabaseQueue` serialises all access. `NotificationsDatabase` is `Sendable`
/// and may be called from any actor or thread.
public struct NotificationsDatabase: Sendable {

    // MARK: - Storage

    internal let dbQueue: DatabaseQueue

    // MARK: - Schema / migration

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_notifications") { db in
            try db.execute(sql: """
                CREATE TABLE notification (
                    id          TEXT    PRIMARY KEY,
                    kind        TEXT    NOT NULL,
                    title       TEXT    NOT NULL,
                    detail      TEXT    NOT NULL,
                    timestamp   TEXT    NOT NULL,
                    isUnread    INTEGER NOT NULL DEFAULT 1,
                    actionLabel TEXT,
                    createdAt   REAL    NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_notification_createdAt ON notification(createdAt DESC);

                -- Tombstone table: records IDs the user explicitly dismissed.
                -- upsertIfNew checks here in addition to the main table so that
                -- re-seeding never resurrects a notification the user deleted.
                CREATE TABLE notification_dismissed (
                    id         TEXT PRIMARY KEY,
                    dismissedAt REAL NOT NULL DEFAULT 0
                );
            """)
        }
        // v2: add nullable episode_guid + show_slug columns for newEpisode notifications.
        // Existing rows default to NULL — backward-compatible.
        m.registerMigration("v2_new_episode_columns") { db in
            try db.execute(sql: """
                ALTER TABLE notification ADD COLUMN episodeGuid TEXT;
                ALTER TABLE notification ADD COLUMN showSlug    TEXT;
            """)
        }
        // v3: triage inbox — add a persisted resolved flag. NOT NULL with a
        // DEFAULT so existing rows migrate as "unresolved" (0). Non-destructive.
        m.registerMigration("v3_triage_resolved_flag") { db in
            try db.execute(sql: """
                ALTER TABLE notification ADD COLUMN isResolved INTEGER NOT NULL DEFAULT 0;
            """)
        }
        return m
    }

    // MARK: - Initialisation

    /// Opens (or creates) the notifications database at `url` and runs
    /// migrations.
    ///
    /// - Parameter url: File URL for the SQLite database. Created if absent.
    public init(url: URL) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// Opens an **in-memory** database (useful for tests and snapshot previews).
    public static func inMemory() throws -> NotificationsDatabase {
        let queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
        return NotificationsDatabase(queue: queue)
    }

    /// Internal initialiser that wraps an already-configured `DatabaseQueue`.
    /// Used by `inMemory()` and tests that supply their own queue.
    internal init(queue: DatabaseQueue) {
        self.dbQueue = queue
    }

    // MARK: - Repository API

    /// All notifications, sorted newest first (by `createdAt`).
    ///
    /// `id` is a deterministic secondary sort key: batches seeded in the same
    /// call (e.g. `seedFromFailures`) share an identical `createdAt`, so a bare
    /// `ORDER BY createdAt DESC` leaves same-second items in SQLite's arbitrary
    /// (rowid) order — which reads as "random" intra-bucket ordering in the UI.
    /// Adding `id DESC` makes the tiebreak stable and reproducible.
    public func fetchAll() throws -> [NotificationRecord] {
        try dbQueue.read { db in
            try NotificationRecord
                .order(Column("createdAt").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    /// Inserts `record` only if no row with the same `id` already exists and no
    /// tombstone for that id has been written.
    ///
    /// This preserves the user's read/deleted state across re-seeds:
    /// - If the user read the notification, the existing row retains its read state.
    /// - If the user deleted the notification, a tombstone prevents re-insertion.
    ///
    /// - Returns: `true` if the record was genuinely new and inserted;
    ///            `false` if it already existed or was tombstoned (no write occurred).
    @discardableResult
    public func upsertIfNew(_ record: NotificationRecord) throws -> Bool {
        try dbQueue.write { db in
            // Block if a live row already exists.
            let liveExists = try NotificationRecord.fetchOne(db, key: record.id) != nil
            if liveExists { return false }

            // Block if the user has previously dismissed this id.
            let dismissed = try Row.fetchOne(
                db,
                SQLRequest(sql: "SELECT 1 FROM notification_dismissed WHERE id = ?",
                           arguments: [record.id])
            )
            if dismissed != nil { return false }

            try record.insert(db)
            return true
        }
    }

    /// Sets `isUnread` to `false` when `read` is `true`, `true` when `read` is `false`.
    public func setRead(id: String, read: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notification SET isUnread = ? WHERE id = ?",
                arguments: [read ? 0 : 1, id]
            )
        }
    }

    /// Marks the notification with `id` as resolved (the user acted on it), moving
    /// it out of the active triage buckets and into **Done**. Idempotent.
    public func markResolved(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notification SET isResolved = 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Marks every notification as read.
    public func markAllRead() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE notification SET isUnread = 0")
        }
    }

    /// Deletes the notification with `id` and writes a tombstone so that
    /// future `upsertIfNew` calls for the same id are silently ignored.
    public func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM notification WHERE id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: """
                    INSERT INTO notification_dismissed (id, dismissedAt)
                    VALUES (?, ?)
                    ON CONFLICT(id) DO NOTHING
                """,
                arguments: [id, Date().timeIntervalSince1970]
            )
        }
    }

    /// Re-inserts a previously-deleted notification and clears its tombstone, so an
    /// undo („Rückgängig" on a single dismiss) brings the row back exactly. Uses
    /// INSERT OR REPLACE so it is idempotent even if a re-seed already recreated
    /// the id in the meantime.
    public func restore(_ record: NotificationRecord) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notification_dismissed WHERE id = ?", arguments: [record.id])
            try record.upsert(db)
        }
    }

    /// Deletes a notification row **without** writing a tombstone.
    ///
    /// Use this only for updateable notifications (e.g. daily summary) that may be
    /// re-inserted later. Unlike ``delete(id:)`` the id is NOT added to
    /// `notification_dismissed`, so `upsertIfNew` will accept the next insertion.
    public func deleteWithoutTombstone(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM notification WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Deletes every notification and writes tombstones for all their ids so
    /// re-seeding does not immediately re-populate the list.
    public func deleteAll() throws {
        try dbQueue.write { db in
            // Write tombstones for all existing ids before deleting.
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO notification_dismissed (id, dismissedAt)
                    SELECT id, ? FROM notification
                """,
                arguments: [now]
            )
            try db.execute(sql: "DELETE FROM notification")
        }
    }

    // MARK: - Fallback

    /// Returns a fully operational in-memory database, silently swallowing any
    /// errors. Used as a last-resort fallback inside `NotificationStore.init()`
    /// so the UI never crashes when the file system is unavailable.
    public static func _empty() -> NotificationsDatabase {
        // If even the in-memory path throws (extremely unlikely), return a bare
        // wrapper around a fresh anonymous queue so the app at least doesn't crash.
        return (try? inMemory()) ?? NotificationsDatabase(queue: (try! DatabaseQueue()))
    }
}
