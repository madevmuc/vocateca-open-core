import GRDB

/// Database schema definitions and migrations for **Swift-owned** Vocateca
/// databases (fresh SQLite files or snapshot copies).
///
/// ## Safety contract
/// `Schema.migrator` MUST NEVER run against the live production database at
/// `~/Library/Application Support/Vocateca/state.sqlite`. That file is
/// opened read-only via `StateReader`. Only `StateStore` (which owns its own
/// database file) calls `Schema.migrator.migrate(_:)`.
///
/// ## Migration history
/// - `v1_base` — exact replica of the v1 (Python-managed) schema, including
///   all tables, indexes, and column defaults. Lets the Swift test suite spin
///   up a realistic fresh database without touching the production file.
/// - `v2_additive` — adds nullable v2 columns to `episodes` plus three new
///   Instagram-pipeline tables. All additions are backwards-compatible: old
///   Python readers see NULL for the new columns and ignore the new tables.
public enum Schema {

    // MARK: - Public migrator

    /// A `DatabaseMigrator` with both registered migrations.
    ///
    /// Call `Schema.migrator.migrate(dbQueue)` once during `StateStore.init`
    /// to bring a Swift-owned database up to the latest schema.
    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        // ── v1_base ────────────────────────────────────────────────────────
        // Exact replica of the Python-managed schema (state.py `_SCHEMA` +
        // `init_schema` ALTER TABLE additions). Preserves all column defaults,
        // NOT NULL constraints, and the three indexes used by the worker.
        m.registerMigration("v1_base") { db in
            try db.execute(sql: """
                CREATE TABLE episodes (
                    guid             TEXT PRIMARY KEY,
                    show_slug        TEXT NOT NULL,
                    title            TEXT NOT NULL,
                    pub_date         TEXT NOT NULL,
                    mp3_url          TEXT NOT NULL,
                    status           TEXT NOT NULL DEFAULT 'pending',
                    mp3_path         TEXT,
                    transcript_path  TEXT,
                    attempted_at     TEXT,
                    completed_at     TEXT,
                    error_text       TEXT,
                    duration_sec     INTEGER,
                    word_count       INTEGER,
                    priority         INTEGER NOT NULL DEFAULT 0,
                    detected_language TEXT,
                    mean_confidence  REAL,
                    error_category   TEXT,
                    attempts         INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_episodes_show ON episodes(show_slug);
                CREATE INDEX idx_episodes_status ON episodes(status);
                CREATE INDEX idx_episodes_claim ON episodes(status, priority DESC, pub_date);

                CREATE TABLE jobs (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind        TEXT NOT NULL,
                    show_slug   TEXT,
                    guid        TEXT,
                    pid         INTEGER,
                    started_at  TEXT NOT NULL,
                    ended_at    TEXT,
                    error_text  TEXT
                );

                CREATE TABLE meta (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE slug_reservations (
                    slug TEXT PRIMARY KEY,
                    guid TEXT NOT NULL UNIQUE
                );

                CREATE TABLE events (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts           TEXT NOT NULL,
                    type         TEXT NOT NULL,
                    show_slug    TEXT,
                    guid         TEXT,
                    payload_json TEXT NOT NULL DEFAULT '{}'
                );
                CREATE INDEX idx_events_type ON events(type);
                CREATE INDEX idx_events_guid ON events(guid);
            """)
        }

        // ── v2_additive ────────────────────────────────────────────────────
        // Adds nullable v2 columns to `episodes` (safe with the Python app:
        // Python ignores unknown columns; existing rows get NULL by default).
        // Also creates three new Instagram-pipeline tables (skeleton columns;
        // finalised in Phase 3).
        m.registerMigration("v2_additive") { db in
            // New nullable columns on episodes.
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN description  TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN ig_shortcode TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN ig_profile   TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN ig_kind      TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN media_type   TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN ocr_text     TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN image_tags   TEXT")
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN transcript_origin TEXT")

            // Instagram account pool — Phase 3 will add further columns.
            try db.execute(sql: """
                CREATE TABLE instagram_account_pool (
                    account_id          TEXT PRIMARY KEY,
                    pool_position       INTEGER NOT NULL,
                    is_new              INTEGER NOT NULL DEFAULT 1,
                    warmup_stage        INTEGER NOT NULL DEFAULT 0,
                    is_active           INTEGER NOT NULL DEFAULT 1,
                    health_status       TEXT    NOT NULL DEFAULT 'ok',
                    last_health_check_at TEXT,
                    failed_attempts     INTEGER NOT NULL DEFAULT 0,
                    followed_profiles   TEXT
                );
            """)

            // Per-show enumeration cursor for the Instagram feed scanner.
            try db.execute(sql: """
                CREATE TABLE instagram_enumeration_cursor (
                    show_slug            TEXT PRIMARY KEY,
                    last_shortcode_seen  TEXT,
                    last_enumeration_at  TEXT
                );
            """)

            // Deduplication table for story impressions.
            try db.execute(sql: """
                CREATE TABLE instagram_story_seen (
                    show_slug        TEXT NOT NULL,
                    story_shortcode  TEXT NOT NULL,
                    seen_at          TEXT NOT NULL,
                    PRIMARY KEY (show_slug, story_shortcode)
                );
            """)
        }

        // ── v3_watchlist_hits ──────────────────────────────────────────────
        // Watchlist keyword-match hits (feature B). Additive: Python ignores the
        // unknown table, same as the v2 Instagram tables.
        m.registerMigration("v3_watchlist_hits") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watchlist_hits (
                    id            TEXT PRIMARY KEY,
                    term_id       TEXT NOT NULL,
                    show_slug     TEXT,
                    episode_guid  TEXT,
                    snippet       TEXT NOT NULL DEFAULT '',
                    matched_at    TEXT NOT NULL,
                    read          INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_watchlist_hits_term    ON watchlist_hits(term_id);
                CREATE INDEX IF NOT EXISTS idx_watchlist_hits_matched ON watchlist_hits(matched_at);
            """)
        }

        // ── v4_integration_deliveries ──────────────────────────────────────
        // Marker table for the Integrations feature (Notion/webhook push):
        // idempotency (don't push the same transcript twice) + status/error
        // tracking per (integration, episode). Additive: unknown to the v1
        // Python app, same pattern as `watchlist_hits`.
        m.registerMigration("v4_integration_deliveries") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS integration_deliveries (
                    id            TEXT PRIMARY KEY,
                    integration   TEXT NOT NULL,
                    episode_guid  TEXT,
                    target        TEXT,
                    status        TEXT NOT NULL,
                    external_ref  TEXT,
                    delivered_at  TEXT NOT NULL,
                    error_text    TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_int_deliveries_episode
                    ON integration_deliveries(integration, episode_guid);
            """)
        }

        // ── v5_transcripts_fts ─────────────────────────────────────────────
        // FTS5 virtual table backing the Library full-text search. Indexes each
        // finished transcript's title + plain-text content; `guid`/`show_slug`
        // are UNINDEXED metadata carried through so a match row can be routed
        // back to the episode without a JOIN. `remove_diacritics 2` folds
        // umlauts so „Bär" matches „bar"/„Baer" queries. Additive: unknown to
        // the v1 Python app, same pattern as `watchlist_hits`. See
        // `ensureAdditiveTables` for the production-DB safety net (the base
        // migrator is skipped there, so this migration alone is not enough).
        m.registerMigration("v5_transcripts_fts") { db in
            try db.execute(sql: Self.transcriptsFTSCreateSQL)
        }

        // ── v6_trash ───────────────────────────────────────────────────────
        // „Zuletzt gelöscht" (recently-deleted) trash: deleted transcripts + shows
        // are parked here for 30 days instead of being erased immediately. Additive:
        // unknown to the v1 Python app, same pattern as `watchlist_hits`. See
        // `ensureAdditiveTables` for the production-DB safety net (the base migrator
        // is skipped there, so this migration alone is not enough).
        m.registerMigration("v6_trash") { db in
            try db.execute(sql: Self.trashItemsCreateSQL)
            try db.execute(sql: Self.trashPendingMediaCreateSQL)
        }

        return m
    }

    // MARK: - Trash table DDL (shared by migration + additive safety net)

    /// `CREATE TABLE IF NOT EXISTS` for the „Zuletzt gelöscht" trash items.
    /// One constant so the migration and `ensureAdditiveTables` create the exact
    /// same schema. `payload_json` snapshots the DB state needed to restore
    /// (episode rows / watchlist entry); `files_json` maps each moved transcript
    /// file to its stored copy under `<userDataDir>/trash/<id>/`.
    static let trashItemsCreateSQL = """
        CREATE TABLE IF NOT EXISTS trash_items (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            guid         TEXT NOT NULL DEFAULT '',
            show_slug    TEXT NOT NULL DEFAULT '',
            title        TEXT NOT NULL DEFAULT '',
            payload_json TEXT NOT NULL DEFAULT '{}',
            files_json   TEXT NOT NULL DEFAULT '[]',
            deleted_at   TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_trash_items_deleted ON trash_items(deleted_at);
        """

    /// `CREATE TABLE IF NOT EXISTS` for the deferred media (mp3) final-delete.
    /// Media is NOT trashed (trash keeps only text); when a transcript is trashed
    /// its media file is scheduled here and erased once the undo window elapses
    /// (`ready_at <= now`) — either by the toast on expiry or the next-launch
    /// finalize sweep in `MaintenanceRunner`. Undo removes the row so the media
    /// is never touched.
    static let trashPendingMediaCreateSQL = """
        CREATE TABLE IF NOT EXISTS trash_pending_media (
            guid       TEXT PRIMARY KEY,
            media_path TEXT NOT NULL,
            ready_at   TEXT NOT NULL
        );
        """

    // MARK: - FTS table DDL (shared by migration + additive safety net)

    /// `CREATE VIRTUAL TABLE IF NOT EXISTS` for the transcript FTS5 index.
    /// Kept as one constant so the migration and `ensureAdditiveTables` create
    /// the exact same schema (drift here would make the two paths disagree).
    static let transcriptsFTSCreateSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
            guid UNINDEXED,
            show_slug UNINDEXED,
            title,
            content,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """

    // MARK: - Additive-table safety net (production DB)

    /// Creates the additive v2/v3 tables + columns **idempotently**, independent of
    /// the `grdb_migrations` state.
    ///
    /// Why this exists: the production DB is created/owned by the v1 Python app, so
    /// its `episodes`/`events`/… tables already exist with an empty
    /// `grdb_migrations`. When `DatabaseMigrator` runs, the very first migration
    /// (`v1_base`, a bare `CREATE TABLE episodes`) throws "table already exists",
    /// which aborts the WHOLE migration — so `v2_additive` + `v3_watchlist_hits`
    /// never run and `watchlist_hits` (+ the Instagram tables) are missing. That
    /// silently broke the Watchlist (hit inserts failed). These statements are all
    /// `IF NOT EXISTS` / column-guarded, so they're safe on both fresh and
    /// production databases and safe alongside the Python app (it ignores unknown
    /// tables/columns).
    public static func ensureAdditiveTables(_ db: Database) throws {
        // Additive nullable columns on `episodes` (skip any that already exist).
        let existing = Set(try db.columns(in: "episodes").map(\.name))
        let additiveColumns: [(name: String, type: String)] = [
            ("description", "TEXT"), ("ig_shortcode", "TEXT"), ("ig_profile", "TEXT"),
            ("ig_kind", "TEXT"), ("media_type", "TEXT"), ("ocr_text", "TEXT"),
            ("image_tags", "TEXT"), ("transcript_origin", "TEXT"),
        ]
        for col in additiveColumns where !existing.contains(col.name) {
            try db.execute(sql: "ALTER TABLE episodes ADD COLUMN \(col.name) \(col.type)")
        }

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS instagram_account_pool (
                account_id          TEXT PRIMARY KEY,
                pool_position       INTEGER NOT NULL,
                is_new              INTEGER NOT NULL DEFAULT 1,
                warmup_stage        INTEGER NOT NULL DEFAULT 0,
                is_active           INTEGER NOT NULL DEFAULT 1,
                health_status       TEXT    NOT NULL DEFAULT 'ok',
                last_health_check_at TEXT,
                failed_attempts     INTEGER NOT NULL DEFAULT 0,
                followed_profiles   TEXT
            );
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS instagram_enumeration_cursor (
                show_slug            TEXT PRIMARY KEY,
                last_shortcode_seen  TEXT,
                last_enumeration_at  TEXT
            );
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS instagram_story_seen (
                show_slug        TEXT NOT NULL,
                story_shortcode  TEXT NOT NULL,
                seen_at          TEXT NOT NULL,
                PRIMARY KEY (show_slug, story_shortcode)
            );
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS watchlist_hits (
                id            TEXT PRIMARY KEY,
                term_id       TEXT NOT NULL,
                show_slug     TEXT,
                episode_guid  TEXT,
                snippet       TEXT NOT NULL DEFAULT '',
                matched_at    TEXT NOT NULL,
                read          INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_watchlist_hits_term    ON watchlist_hits(term_id);
            CREATE INDEX IF NOT EXISTS idx_watchlist_hits_matched ON watchlist_hits(matched_at);
        """)
        // v4 `integration_deliveries` — MUST be here too, not only in the
        // `v4_integration_deliveries` migration. On a pre-v4 production DB the base
        // migrator is SKIPPED entirely (`episodes` already exists), so the v4
        // migration never runs and this table would be missing — every Notion/
        // webhook delivery insert + dedupe check then throws "no such table",
        // silently swallowed, so auto-push stops deduping (duplicate pages) and
        // delivery history is empty. `IF NOT EXISTS` keeps it safe on fresh DBs
        // where the migration already created it.
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS integration_deliveries (
                id            TEXT PRIMARY KEY,
                integration   TEXT NOT NULL,
                episode_guid  TEXT,
                target        TEXT,
                status        TEXT NOT NULL,
                external_ref  TEXT,
                delivered_at  TEXT NOT NULL,
                error_text    TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_int_deliveries_episode
                ON integration_deliveries(integration, episode_guid);
        """)
        // v5 `transcripts_fts` — MUST be here too, not only in the
        // `v5_transcripts_fts` migration. On a pre-v5 production DB the base
        // migrator is SKIPPED entirely (`episodes` already exists), so the v5
        // migration never runs and this virtual table would be missing — every
        // Library full-text search + the write-hook upsert then throws "no such
        // table: transcripts_fts", silently swallowed, so search returns nothing
        // and no new transcript is ever indexed. `IF NOT EXISTS` keeps it safe on
        // fresh DBs where the migration already created it. (Same lesson as the
        // `integration_deliveries` gap above.)
        try db.execute(sql: Self.transcriptsFTSCreateSQL)
        // v6 `trash_items` + `trash_pending_media` — MUST be here too, not only in
        // the `v6_trash` migration. On a pre-v6 production DB the base migrator is
        // SKIPPED entirely (`episodes` already exists), so the v6 migration never
        // runs and these tables would be missing — every put/restore/purge then
        // throws "no such table", silently swallowed, so a deleted transcript would
        // vanish with no trash entry (data loss). `IF NOT EXISTS` keeps it safe on
        // fresh DBs where the migration already created them. (Same lesson as the
        // `integration_deliveries` / `transcripts_fts` gaps above.)
        try db.execute(sql: Self.trashItemsCreateSQL)
        try db.execute(sql: Self.trashPendingMediaCreateSQL)
    }
}
