import XCTest
import Foundation
@testable import VocatecaCore

/// Phase 1, Work Package B — `Episode` + `StateStore` tests.
///
/// ## Test coverage
/// 1. **Round-trip (fresh v2 DB)**: creates a `StateStore` on a temp file,
///    runs migrations, upserts `Episode` values including v2 fields, reads
///    them back, and asserts `Equatable`-equal. Also exercises `setMeta` /
///    `metaValue`, `appendEvent`, `reserveSlug`, and verifies the three IG
///    tables exist via `sqlite_master`.
///
/// 2. **Real-DB full-read oracle (snapshot, auto-skip if absent)**: snapshots
///    the production DB (copy .sqlite + -wal + -shm to temp), opens it
///    **read-only via `StateReader`** (NOT `StateStore` — no migration on the
///    v1 production DB!), reads ALL episodes, and cross-checks every v1 column
///    value against the `/usr/bin/sqlite3` CLI oracle.
///
/// 3. **v1 DB → v2 fields nil**: confirms that reading a v1 database through
///    `Episode.init(row:)` leaves all v2 fields `nil` without crashing.
final class StateStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh `StateStore` backed by a temp SQLite file with v2
    /// migrations applied. Returns both the store and the temp directory URL
    /// (the caller must `removeItem(at:)` the directory when done).
    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir)
    }

    private static func dbURL(in dir: URL) -> URL {
        dir.appendingPathComponent("test.sqlite")
    }

    /// Copies the production `state.sqlite` (plus WAL sidecars) to a temp
    /// directory and returns the URL of the snapshot file.
    ///
    /// Throws `XCTSkip` if the production DB does not exist.
    private static func snapshotProductionDB() throws -> URL {
        let source = Paths.stateDatabaseURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Production state.sqlite not found — skipping real-DB oracle test")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateStoreOracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let dest = tmp.appendingPathComponent("state.sqlite")
        try FileManager.default.copyItem(at: source, to: dest)

        for sidecar in ["-wal", "-shm"] {
            let src = source.deletingLastPathComponent()
                .appendingPathComponent("state.sqlite\(sidecar)")
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(
                    at: src,
                    to: tmp.appendingPathComponent("state.sqlite\(sidecar)")
                )
            }
        }

        return dest
    }

    /// Runs an external process and returns its stdout as a `String`.
    private func shellOut(_ executable: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        try process.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Drain stderr before waiting; avoids pipe-buffer deadlock on large output.
        errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return out
    }

    // MARK: - 1. Round-trip tests (fresh v2 DB)

    func testRoundTripUpsertAndRead() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a rich episode that exercises every v1 + v2 field.
        let ep1 = Episode(
            guid: "test-guid-001",
            showSlug: "my-show",
            title: "Pilot Episode",
            pubDate: "2024-01-15",
            mp3Url: "https://example.com/ep1.mp3",
            status: "pending",
            mp3Path: nil,
            transcriptPath: nil,
            attemptedAt: nil,
            completedAt: nil,
            errorText: nil,
            durationSec: 3600,
            wordCount: 8500,
            priority: 5,
            detectedLanguage: "de",
            meanConfidence: 0.93,
            errorCategory: nil,
            attempts: 0,
            description: "Pilot episode with some description.",
            igShortcode: "ABCxyz123",
            igProfile: "someprofile",
            igKind: "reel",
            mediaType: "video",
            ocrText: "OCR text from image",
            imageTags: "[\"cats\",\"dogs\"]"
        )

        // A minimal episode with all v2 fields nil (simulating a podcast episode).
        let ep2 = Episode(
            guid: "test-guid-002",
            showSlug: "another-show",
            title: "Plain Podcast Episode",
            pubDate: "2024-02-20",
            mp3Url: "https://example.com/ep2.mp3",
            status: "done",
            durationSec: 1800,
            priority: 0,
            attempts: 0
        )

        try store.upsert(ep1)
        try store.upsert(ep2)

        // Read back individual episode.
        let readBack1 = try XCTUnwrap(store.episode(guid: "test-guid-001"))
        XCTAssertEqual(readBack1, ep1,
            "Round-tripped Episode must be Equatable-equal to original")

        let readBack2 = try XCTUnwrap(store.episode(guid: "test-guid-002"))
        XCTAssertEqual(readBack2, ep2)

        // allEpisodes must return both.
        let all = try store.allEpisodes()
        XCTAssertEqual(all.count, 2)

        // episodes(showSlug:) must filter correctly.
        let myShowEps = try store.episodes(showSlug: "my-show")
        XCTAssertEqual(myShowEps.count, 1)
        XCTAssertEqual(myShowEps.first?.guid, ep1.guid)

        // episodeCount consistency.
        XCTAssertEqual(try store.episodeCount(), 2)

        // v2 fields survive the round-trip.
        XCTAssertEqual(readBack1.description, "Pilot episode with some description.")
        XCTAssertEqual(readBack1.igShortcode, "ABCxyz123")
        XCTAssertEqual(readBack1.igProfile, "someprofile")
        XCTAssertEqual(readBack1.igKind, "reel")
        XCTAssertEqual(readBack1.mediaType, "video")
        XCTAssertEqual(readBack1.ocrText, "OCR text from image")
        XCTAssertEqual(readBack1.imageTags, "[\"cats\",\"dogs\"]")

        // ep2 v2 fields must be nil.
        XCTAssertNil(readBack2.description)
        XCTAssertNil(readBack2.igShortcode)
        XCTAssertNil(readBack2.igKind)
    }

    func testUpsertIsIdempotentAndUpdates() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var ep = Episode(
            guid: "idempotent-guid",
            showSlug: "s",
            title: "Original",
            pubDate: "2024-01-01",
            mp3Url: "https://example.com/a.mp3",
            status: "pending",
            priority: 0,
            attempts: 0
        )
        try store.upsert(ep)

        // Modify and upsert again — should replace.
        ep.title = "Updated Title"
        ep.status = "done"
        ep.igKind = "post"
        try store.upsert(ep)

        let result = try XCTUnwrap(store.episode(guid: "idempotent-guid"))
        XCTAssertEqual(result.title, "Updated Title")
        XCTAssertEqual(result.status, "done")
        XCTAssertEqual(result.igKind, "post")
        XCTAssertEqual(try store.episodeCount(), 1,
            "Upsert must not duplicate rows")
    }

    func testSetAndGetMeta() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(try store.metaValue("nonexistent_key"))

        try store.setMeta(key: "schema_version", value: "2")
        XCTAssertEqual(try store.metaValue("schema_version"), "2")

        // Overwrite.
        try store.setMeta(key: "schema_version", value: "3")
        XCTAssertEqual(try store.metaValue("schema_version"), "3")

        try store.setMeta(key: "another_key", value: "hello")
        XCTAssertEqual(try store.metaValue("another_key"), "hello")
    }

    func testAppendEvent() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.appendEvent(
            type: "episode.done",
            showSlug: "my-show",
            guid: "some-guid",
            payloadJSON: "{\"title\":\"Test\"}"
        )

        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.fileExists(atPath: sqlite3Path) else {
            print("⚠️  /usr/bin/sqlite3 not found — skipping event row count check")
            return
        }

        let output = try shellOut(sqlite3Path,
                                  args: [Self.dbURL(in: dir).path,
                                         "SELECT COUNT(*) FROM events;"])
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1",
                       "Expected 1 event row after appendEvent")
    }

    func testReserveSlug() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.reserveSlug("my-show-2024-01-01-pilot", guid: "guid-001")

        // Idempotent: same guid reserved again must not error or duplicate.
        try store.reserveSlug("my-show-2024-01-01-pilot", guid: "guid-001")

        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.fileExists(atPath: sqlite3Path) else { return }
        let out = try shellOut(sqlite3Path,
                               args: [Self.dbURL(in: dir).path,
                                      "SELECT COUNT(*) FROM slug_reservations;"])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "1",
                       "Idempotent reserveSlug must result in exactly 1 row")
    }

    func testInstagramTablesExist() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.fileExists(atPath: sqlite3Path) else {
            print("⚠️  /usr/bin/sqlite3 not found — skipping IG table existence check")
            return
        }

        let dbPath = Self.dbURL(in: dir).path
        for table in ["instagram_account_pool",
                      "instagram_enumeration_cursor",
                      "instagram_story_seen"] {
            let out = try shellOut(sqlite3Path, args: [
                dbPath,
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(table)';"
            ])
            XCTAssertEqual(
                out.trimmingCharacters(in: .whitespacesAndNewlines), "1",
                "Expected table '\(table)' to exist in v2 schema"
            )
        }
        _ = store  // used for schema side-effect only
    }

    // MARK: - 2. Real-DB full-read oracle (snapshot, auto-skip if absent)

    /// Reads ALL episodes from the production DB via `StateReader` (read-only,
    /// NO migration), then cross-checks every v1 column value against the
    /// `sqlite3` CLI oracle for a deterministic sample.
    func testRealDBFullReadOracle() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        // Open read-only via StateReader — NEVER via StateStore (no migration!).
        let reader = try StateReader(databaseURL: snap)
        let grdbEpisodes = try reader.allEpisodes()
        let grdbCount = grdbEpisodes.count

        XCTAssertGreaterThan(grdbCount, 3000,
            "Expected > 3 000 episodes in the real DB, got \(grdbCount)")

        // ── sqlite3 row-count oracle ───────────────────────────────────────
        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.fileExists(atPath: sqlite3Path) else {
            print("⚠️  /usr/bin/sqlite3 not found — skipping oracle cross-check")
            return
        }

        let countOutput = try shellOut(
            sqlite3Path,
            args: [snap.path, "SELECT COUNT(*) FROM episodes;"]
        )
        let oracleCount = Int(countOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        XCTAssertEqual(oracleCount, grdbCount,
            "sqlite3 oracle says \(oracleCount) episodes; GRDB says \(grdbCount) — must match")

        print("✅ Row count oracle: sqlite3=\(oracleCount) GRDB=\(grdbCount)")

        // ── Per-column value oracle for a deterministic sample ────────────
        // Sort by guid for a stable order; take first 50 + up to 10 rows
        // that have non-null duration_sec or mean_confidence (de-duplicated).
        let allSorted = grdbEpisodes.sorted { $0.guid < $1.guid }
        var sample = Array(allSorted.prefix(50))
        let extras = allSorted.filter { $0.durationSec != nil }.prefix(10)
            + allSorted.filter { $0.meanConfidence != nil }.prefix(10)
        for ep in extras where !sample.contains(where: { $0.guid == ep.guid }) {
            sample.append(ep)
        }

        print("Verifying \(sample.count) episodes column-by-column against sqlite3 oracle …")

        // Dump the sample rows as JSON via sqlite3.
        let guids = sample
            .map { "'\($0.guid.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        let jsonSQL = "SELECT * FROM episodes WHERE guid IN (\(guids)) ORDER BY guid;"
        let jsonOutput = try shellOut(sqlite3Path, args: ["-json", snap.path, jsonSQL])

        let oracleRows: [[String: OracleValue]]
        do {
            oracleRows = try JSONDecoder().decode(
                [[String: OracleValue]].self,
                from: Data(jsonOutput.utf8)
            )
        } catch {
            XCTFail("Failed to parse sqlite3 JSON output: \(error)\nRaw:\n\(jsonOutput.prefix(2000))")
            return
        }

        var oracleByGuid: [String: [String: OracleValue]] = [:]
        for row in oracleRows {
            if case let .string(g) = row["guid"] { oracleByGuid[g] = row }
        }

        var mismatchCount = 0

        for ep in sample {
            guard let oracle = oracleByGuid[ep.guid] else {
                XCTFail("guid '\(ep.guid)' found by GRDB but absent from sqlite3 oracle output")
                mismatchCount += 1
                continue
            }

            func checkStr(_ col: String, grdb: String?, oracleKey: String) {
                let ov = oracle[oracleKey]
                switch (grdb, ov) {
                case (.none, .none), (.none, .some(.null)):
                    break  // both nil — OK
                case let (.some(g), .some(.string(o))):
                    if g != o {
                        XCTFail("[guid=\(ep.guid)] '\(col)': GRDB='\(g)' oracle='\(o)'")
                        mismatchCount += 1
                    }
                case (.some, .none), (.some, .some(.null)):
                    XCTFail("[guid=\(ep.guid)] '\(col)': GRDB='\(grdb!)' oracle=NULL")
                    mismatchCount += 1
                default: break
                }
            }

            func checkInt(_ col: String, grdb: Int?, oracleKey: String) {
                let ov = oracle[oracleKey]
                switch (grdb, ov) {
                case (.none, .none), (.none, .some(.null)):
                    break
                case let (.some(g), .some(.int(o))):
                    if g != o {
                        XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(g) oracle=\(o)")
                        mismatchCount += 1
                    }
                // sqlite3 JSON may render integer columns as JSON strings in some builds.
                case let (.some(g), .some(.string(o))):
                    if Int(o) != g {
                        XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(g) oracle(str)='\(o)'")
                        mismatchCount += 1
                    }
                case (.some, .none), (.some, .some(.null)):
                    XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(grdb!) oracle=NULL")
                    mismatchCount += 1
                default: break
                }
            }

            func checkDouble(_ col: String, grdb: Double?, oracleKey: String) {
                let ov = oracle[oracleKey]
                switch (grdb, ov) {
                case (.none, .none), (.none, .some(.null)):
                    break
                case let (.some(g), .some(.double(o))):
                    if abs(g - o) > 1e-9 {
                        XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(g) oracle=\(o)")
                        mismatchCount += 1
                    }
                case let (.some(g), .some(.int(o))):
                    if abs(g - Double(o)) > 1e-9 {
                        XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(g) oracle(int)=\(o)")
                        mismatchCount += 1
                    }
                case let (.some(g), .some(.string(o))):
                    if let od = Double(o), abs(g - od) > 1e-9 {
                        XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(g) oracle(str)='\(o)'")
                        mismatchCount += 1
                    }
                case (.some, .none), (.some, .some(.null)):
                    XCTFail("[guid=\(ep.guid)] '\(col)': GRDB=\(grdb!) oracle=NULL")
                    mismatchCount += 1
                default: break
                }
            }

            checkStr("guid",              grdb: ep.guid,             oracleKey: "guid")
            checkStr("show_slug",         grdb: ep.showSlug,         oracleKey: "show_slug")
            checkStr("title",             grdb: ep.title,            oracleKey: "title")
            checkStr("pub_date",          grdb: ep.pubDate,          oracleKey: "pub_date")
            checkStr("mp3_url",           grdb: ep.mp3Url,           oracleKey: "mp3_url")
            checkStr("status",            grdb: ep.status,           oracleKey: "status")
            checkStr("mp3_path",          grdb: ep.mp3Path,          oracleKey: "mp3_path")
            checkStr("transcript_path",   grdb: ep.transcriptPath,   oracleKey: "transcript_path")
            checkStr("attempted_at",      grdb: ep.attemptedAt,      oracleKey: "attempted_at")
            checkStr("completed_at",      grdb: ep.completedAt,      oracleKey: "completed_at")
            checkStr("error_text",        grdb: ep.errorText,        oracleKey: "error_text")
            checkInt("duration_sec",      grdb: ep.durationSec,      oracleKey: "duration_sec")
            checkInt("word_count",        grdb: ep.wordCount,        oracleKey: "word_count")
            checkInt("priority",          grdb: ep.priority,         oracleKey: "priority")
            checkStr("detected_language", grdb: ep.detectedLanguage, oracleKey: "detected_language")
            checkDouble("mean_confidence",grdb: ep.meanConfidence,   oracleKey: "mean_confidence")
            checkStr("error_category",    grdb: ep.errorCategory,    oracleKey: "error_category")
            checkInt("attempts",          grdb: ep.attempts,         oracleKey: "attempts")
        }

        XCTAssertEqual(mismatchCount, 0,
            "\(mismatchCount) column-level mismatches found — see failures above")

        if mismatchCount == 0 {
            print("✅ Column-level oracle: \(sample.count) sampled episodes, 0 mismatches")
        }
    }

    // MARK: - 3a. deleteShow(slug:) — only that show's rows are removed

    /// Inserts episodes for two shows, deletes one slug, asserts only that
    /// show's rows are gone and the other show is untouched.
    func testDeleteShowRemovesOnlyTargetSlugRows() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Insert two episodes for "show-alpha" and one for "show-beta".
        let epA1 = Episode(
            guid: "alpha-001",
            showSlug: "show-alpha",
            title: "Alpha Episode 1",
            pubDate: "2024-03-01",
            mp3Url: "https://example.com/a1.mp3",
            status: "done",
            priority: 0,
            attempts: 0
        )
        let epA2 = Episode(
            guid: "alpha-002",
            showSlug: "show-alpha",
            title: "Alpha Episode 2",
            pubDate: "2024-03-08",
            mp3Url: "https://example.com/a2.mp3",
            status: "pending",
            priority: 0,
            attempts: 0
        )
        let epB1 = Episode(
            guid: "beta-001",
            showSlug: "show-beta",
            title: "Beta Episode 1",
            pubDate: "2024-04-01",
            mp3Url: "https://example.com/b1.mp3",
            status: "pending",
            priority: 0,
            attempts: 0
        )

        try store.upsert(epA1)
        try store.upsert(epA2)
        try store.upsert(epB1)
        XCTAssertEqual(try store.episodeCount(), 3, "Pre-delete: expected 3 rows")

        // Delete only show-alpha.
        try store.deleteShow(slug: "show-alpha")

        // show-alpha rows are gone.
        let alphaRows = try store.episodes(showSlug: "show-alpha")
        XCTAssertTrue(alphaRows.isEmpty,
            "After deleteShow(slug: 'show-alpha') no episodes should remain for that slug")

        // show-beta row is untouched.
        let betaRows = try store.episodes(showSlug: "show-beta")
        XCTAssertEqual(betaRows.count, 1,
            "show-beta must be unaffected by deleteShow('show-alpha')")
        XCTAssertEqual(betaRows.first?.guid, "beta-001")

        // Total count.
        XCTAssertEqual(try store.episodeCount(), 1,
            "Post-delete total count must equal show-beta's single row")

        // Deleting a slug that no longer exists is a no-op (no error).
        XCTAssertNoThrow(try store.deleteShow(slug: "show-alpha"),
            "deleteShow on an already-empty slug must not throw")
        XCTAssertNoThrow(try store.deleteShow(slug: "nonexistent-slug"),
            "deleteShow on a nonexistent slug must not throw")
    }

    // MARK: - 3. v1 DB → v2 fields are nil (no crash on missing columns)

    /// Reads all episodes from the v1 production DB via `StateReader` and
    /// asserts that every v2 field is `nil` for every row (no crash on absent
    /// columns).
    func testV1DBV2FieldsAreNil() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        // Open read-only via StateReader (v1 schema, NO migration).
        let reader = try StateReader(databaseURL: snap)
        let episodes = try reader.allEpisodes()

        XCTAssertFalse(episodes.isEmpty,
            "Expected at least one episode from v1 DB")

        for ep in episodes {
            XCTAssertNil(ep.description,  "description must be nil on v1 DB rows")
            XCTAssertNil(ep.igShortcode,  "igShortcode must be nil on v1 DB rows")
            XCTAssertNil(ep.igProfile,    "igProfile must be nil on v1 DB rows")
            XCTAssertNil(ep.igKind,       "igKind must be nil on v1 DB rows")
            XCTAssertNil(ep.mediaType,    "mediaType must be nil on v1 DB rows")
            XCTAssertNil(ep.ocrText,      "ocrText must be nil on v1 DB rows")
            XCTAssertNil(ep.imageTags,    "imageTags must be nil on v1 DB rows")
        }

        print("✅ \(episodes.count) v1 DB episodes decoded; all v2 fields are nil")
    }

    // MARK: - 4. M6 — fresh-DB migration failure must throw

    /// Forces a genuine migrator failure on a FRESH database (the `episodes`
    /// table does not exist yet, so `alreadyInitialised == false`) by making
    /// the containing directory read-only before opening the store. SQLite
    /// can create the (empty) database file itself via `DatabaseQueue.init`,
    /// but the migrator's `CREATE TABLE` statements then fail against the
    /// read-only directory — exercising the exact fresh-DB migrator-throws
    /// branch in `StateStore.init` without needing a test-only seam into
    /// `Schema.migrator`.
    ///
    /// Regression coverage for M6: previously this branch caught the error,
    /// logged a WARN, and let `StateStore.init` return successfully — the app
    /// would then run against a tableless DB with every write silently
    /// swallowed by a `try?` at the call site.
    func testFreshDBMigrationFailureThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateStoreTests-freshdb-migration-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            // Restore write permission before cleanup so removeItem can succeed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let dbURL = dir.appendingPathComponent("fresh.sqlite")

        // Pre-create an EMPTY database file (no tables) so DatabaseQueue.init
        // succeeds (it can open an existing empty file) but the directory is
        // read-only, so SQLite cannot create the `-wal`/`-shm` sidecars or grow
        // the file for the migrator's CREATE TABLE statements.
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        XCTAssertThrowsError(try StateStore(databaseURL: dbURL),
            "StateStore.init must THROW when the migrator fails on a fresh (tableless) DB — a fresh DB must never silently proceed with a half-built schema")
    }

    /// Sanity companion to the above: the EXISTING-DB skip path (schema already
    /// present) must be completely unaffected by the M6 fix — opening a real,
    /// already-migrated database a second time must still succeed with no throw.
    func testExistingDBReopenStillSucceeds() throws {
        let (_, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Re-opening the SAME already-migrated DB must not throw (this is the
        // `alreadyInitialised == true` branch — untouched by M6).
        XCTAssertNoThrow(try StateStore(databaseURL: Self.dbURL(in: dir)),
            "Re-opening an already-migrated DB must still succeed after the M6 fix")
    }
}

// MARK: - Oracle JSON value decoder

/// Decodes a JSON value from `sqlite3 -json` output. SQLite types map to JSON
/// as: TEXT → string, INTEGER → number, REAL → number, NULL → null.
private enum OracleValue: Decodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        // Try int before double to avoid precision loss for integer columns.
        if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else {
            self = .string(try c.decode(String.self))
        }
    }
}
