import XCTest
import GRDB
@testable import VocatecaCore

/// Unit tests for the Library full-text search: the `transcripts_fts` FTS5 table,
/// the `searchTranscripts` query API, the write/delete hooks, and the MATCH
/// sanitiser. Runs against an in-memory `StateStore` (migrations +
/// `ensureAdditiveTables` create the virtual table), so no live DB is touched.
final class TranscriptFTSTests: XCTestCase {

    // Three fixture transcripts spanning distinct vocabulary + an umlaut term.
    private func seed(_ store: StateStore) throws {
        try store.indexTranscript(
            guid: "g1", showSlug: "finance-show", title: "Steuern sparen",
            content: "In dieser Folge sprechen wir über die Steuererklärung und Bären im Wald.")
        try store.indexTranscript(
            guid: "g2", showSlug: "psych-show", title: "Motivation",
            content: "Heute geht es um Gewohnheiten, Disziplin und langfristige Ziele.")
        try store.indexTranscript(
            guid: "g3", showSlug: "sport-show", title: "Marathon",
            content: "Ein Gespräch über Ausdauer, Training und den perfekten Laufschuh.")
    }

    func testExactHitAndMiss() throws {
        let store = try StateStore.inMemory()
        try seed(store)

        // Hit: a distinctive body term returns exactly the one episode.
        let hits = try store.searchTranscripts("Disziplin")
        XCTAssertEqual(hits.map(\.guid), ["g2"])
        XCTAssertEqual(hits.first?.showSlug, "psych-show")
        XCTAssertEqual(hits.first?.title, "Motivation")

        // Miss: a word in no transcript returns nothing.
        XCTAssertTrue(try store.searchTranscripts("Quantenphysik").isEmpty)
    }

    func testTitleIsSearchable() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        let hits = try store.searchTranscripts("Marathon")
        XCTAssertEqual(hits.map(\.guid), ["g3"])
    }

    func testUmlautDiacriticFolding() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        // `remove_diacritics 2` folds umlauts, so an ASCII-folded query still
        // matches the accented content term ("Bären").
        let accented = try store.searchTranscripts("Bären")
        XCTAssertEqual(accented.map(\.guid), ["g1"])
        let folded = try store.searchTranscripts("baren")
        XCTAssertEqual(folded.map(\.guid), ["g1"],
                       "diacritic-folded query should match the accented term")
    }

    func testPrefixMatchOnLastToken() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        // The last token gets an implicit `*`, so a partial word finds the full
        // one ("Steuer" → "Steuererklärung").
        let hits = try store.searchTranscripts("Steuer")
        XCTAssertEqual(hits.map(\.guid), ["g1"])
    }

    func testSnippetContainsMatchMarker() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        let hit = try XCTUnwrap(try store.searchTranscripts("Steuererklärung").first)
        XCTAssertTrue(hit.snippet.contains(StateStore.ftsSnippetOpenMarker),
                      "snippet should wrap the match in the open marker: \(hit.snippet)")
        XCTAssertTrue(hit.snippet.contains(StateStore.ftsSnippetCloseMarker),
                      "snippet should wrap the match in the close marker: \(hit.snippet)")
    }

    func testEmptyAndWhitespaceQueryReturnsNothing() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        XCTAssertTrue(try store.searchTranscripts("").isEmpty)
        XCTAssertTrue(try store.searchTranscripts("   \n ").isEmpty)
    }

    func testMultiTermIsImplicitAnd() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        // Both terms are in g3's content → hit; a term pair split across two
        // episodes → no single episode contains both → miss.
        XCTAssertEqual(try store.searchTranscripts("Ausdauer Training").map(\.guid), ["g3"])
        XCTAssertTrue(try store.searchTranscripts("Ausdauer Disziplin").isEmpty)
    }

    func testUpsertReplacesNoDuplicate() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        // Re-index the same guid with new content; the old content is gone and
        // there is still exactly one row for that guid.
        try store.indexTranscript(guid: "g1", showSlug: "finance-show",
                                  title: "Steuern sparen", content: "Vollständig neuer Inhalt hier.")
        XCTAssertTrue(try store.searchTranscripts("Steuererklärung").isEmpty,
                      "old content should no longer be searchable after re-index")
        XCTAssertEqual(try store.searchTranscripts("Vollständig").map(\.guid), ["g1"])
    }

    func testDeleteHooksRemoveRows() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        // Single-episode removal.
        try store.removeTranscriptFromIndex(guid: "g2")
        XCTAssertTrue(try store.searchTranscripts("Disziplin").isEmpty)
        // Whole-show removal.
        try store.removeTranscriptsFromIndex(showSlug: "sport-show")
        XCTAssertTrue(try store.searchTranscripts("Marathon").isEmpty)
        // The untouched episode still matches.
        XCTAssertEqual(try store.searchTranscripts("Bären").map(\.guid), ["g1"])
    }

    func testDeleteShowClearsFTSRows() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        try store.deleteShow(slug: "finance-show")
        XCTAssertTrue(try store.searchTranscripts("Bären").isEmpty,
                      "deleteShow should also drop the show's FTS rows")
    }

    // MARK: - MATCH sanitiser

    func testMatchExpressionQuotesAndPrefixesLastToken() {
        XCTAssertEqual(StateStore.makeFTSMatchExpression("hello world"), "\"hello\" \"world\"*")
        XCTAssertEqual(StateStore.makeFTSMatchExpression("solo"), "\"solo\"*")
    }

    func testMatchExpressionNilForEmpty() {
        XCTAssertNil(StateStore.makeFTSMatchExpression(""))
        XCTAssertNil(StateStore.makeFTSMatchExpression("   "))
        XCTAssertNil(StateStore.makeFTSMatchExpression("\"\""))
    }

    func testMatchExpressionNeutralisesOperators() throws {
        let store = try StateStore.inMemory()
        try seed(store)
        // A raw `OR` and an unbalanced quote must NOT throw or change semantics —
        // they become literal terms. This query matches nothing (no transcript
        // has all three literal terms) but must not error.
        XCTAssertNoThrow(try store.searchTranscripts("Disziplin OR \"Marathon"))
    }

    // MARK: - Schema lesson: FTS table present on a PRE-EXISTING DB

    /// The GRDB migrator is SKIPPED on a DB that already has `episodes` (the
    /// Python-owned production case). This proves `transcripts_fts` is still
    /// created there — via `ensureAdditiveTables` — exactly like the wave-1
    /// `integration_deliveries` fix. Without the `ensureAdditiveTables` entry the
    /// table would be missing on every real user's DB and search would silently
    /// return nothing.
    func testFTSTablePresentWhenMigratorSkippedOnExistingDB() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-preexisting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("state.sqlite")

        // 1) Pre-create a bare `episodes` table via a plain GRDB connection —
        //    this reproduces the production DB whose base schema exists but whose
        //    grdb_migrations is empty, so StateStore.init's "already initialised"
        //    branch fires and SKIPS the migrator. (Closed before reopening.)
        do {
            let seedQueue = try DatabaseQueue(path: dbURL.path)
            try seedQueue.write { db in
                try db.execute(sql: "CREATE TABLE episodes (guid TEXT PRIMARY KEY, show_slug TEXT, title TEXT);")
            }
        }

        // 2) Open via StateStore (runMigrations: true). Migrator is skipped
        //    (`episodes` exists); only ensureAdditiveTables runs.
        let store = try StateStore(databaseURL: dbURL)

        // 3) The FTS table must exist and be usable end-to-end.
        try store.indexTranscript(guid: "gp", showSlug: "s", title: "T",
                                  content: "Ein einzigartiges Suchwort Zebrastreifen.")
        XCTAssertEqual(try store.searchTranscripts("Zebrastreifen").map(\.guid), ["gp"],
                       "transcripts_fts must be created by ensureAdditiveTables when the migrator is skipped")
    }
}
