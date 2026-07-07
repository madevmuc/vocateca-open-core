import XCTest
import GRDB
@testable import VocatecaCore

// MARK: - SecurityAuditRegressionTests

/// Regression tests for the 2026-07-02 security-audit fixes:
///
/// 1. yt-dlp argument-injection guard (`URLSafety.safeURL` rejects bare `-…`
///    tokens and non-http(s) schemes; call sites add a `--` terminator).
/// 2. `StateStore` no longer silently falls back to a throwaway `/tmp` DB;
///    `StateStore.inMemory()` provides an explicit, disk-free alternative.
/// 3. `StateStore` enables WAL and warns (does not silently downgrade) when
///    the journal mode isn't WAL on a real file-backed database.
/// 4. `ImportExportService.encodeSettings` redacts webhook signing secrets.
/// 5. `TextNormalization.slugify` neutralises path-traversal sequences.
final class SecurityAuditRegressionTests: XCTestCase {

    // MARK: - URLSafety rejects argument-injection tokens

    func testURLSafety_rejectsArgumentInjectionFlag() {
        XCTAssertThrowsError(try URLSafety.safeURL("--exec=touch /tmp/x"))
    }

    func testURLSafety_rejectsBareDashToken() {
        XCTAssertThrowsError(try URLSafety.safeURL("-rf"))
    }

    func testURLSafety_acceptsWellFormedHTTPSURL() {
        XCTAssertNoThrow(try URLSafety.safeURL("https://example.com/feed.xml"))
    }

    // MARK: - StateStore WAL invariant

    func testStateStore_enablesWALOnDisk() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateStoreWALTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("state.sqlite")
        _ = try StateStore(databaseURL: dbURL, runMigrations: false)

        // Verify the on-disk journal mode directly via a fresh read-only queue,
        // independent of any StateStore internals.
        let checkQueue = try DatabaseQueue(path: dbURL.path)
        let mode = try checkQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
    }

    // MARK: - StateStore.inMemory works and writes nothing to disk

    func testStateStore_inMemoryWorksAndIsEmpty() throws {
        let s = try StateStore.inMemory()
        XCTAssertEqual(try s.episodeCount(), 0)
    }

    // MARK: - Export redacts webhook secrets

    func testImportExport_redactsWebhookSecrets() throws {
        let webhook = WebhookEntry(
            events: ["episode.done"],
            kind: "post",
            target: "https://example.com/hook",
            enabled: true,
            id: "wh-1",
            secret: "supersecret"
        )
        let settings = Settings(webhooks: [webhook])

        let data = try ImportExportService.encodeSettings(settings, exportedAt: "2026-07-02T00:00:00Z")

        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("supersecret"),
                        "exported settings must never contain the raw webhook secret")

        let decoded = try ImportExportService.decodeSettings(from: data)
        XCTAssertEqual(decoded.webhooks.first?.secret, "",
                        "decoded export must carry an empty (redacted) secret")
    }

    // MARK: - slugify neutralizes traversal

    func testSlugify_neutralizesPathTraversal() {
        let slug = TextNormalization.slugify("../../etc/passwd")
        XCTAssertFalse(slug.contains("/"))
        XCTAssertFalse(slug.contains(".."))
    }
}
