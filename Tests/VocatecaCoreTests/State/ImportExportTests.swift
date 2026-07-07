import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - ImportExportTests

/// Tests for ``ImportExportService``.
///
/// Covers:
/// (a) Encode → decode round-trips for settings and subscriptions.
/// (b) Settings diff detects changed fields.
/// (c) Subscriptions diff classifies added / changed / unchanged / removed.
/// (d) Merge vs overwrite result sets.
/// (e) Validation rejects bad app / kind / version.
final class ImportExportTests: XCTestCase {

    // MARK: - Helpers

    private let fixedTimestamp = "2026-06-28T12:00:00Z"

    /// A minimal ``Settings`` instance with non-default values in a few fields.
    private func makeSettings(outputRoot: String = "~/Desktop/test",
                              whisperModel: String = "large-v3-turbo",
                              notifyOnSuccess: Bool = true) -> Settings {
        // Settings init requires parameters in declaration order.
        // We build a default then set the fields we care about.
        var s = Settings()
        s.outputRoot      = outputRoot
        s.whisperModel    = whisperModel
        s.notifyOnSuccess = notifyOnSuccess
        return s
    }

    /// A ``Show`` with the three required fields.
    private func makeShow(slug: String, title: String, rss: String = "https://example.com/\(UUID().uuidString)") -> Show {
        Show(slug: slug, title: title, rss: rss)
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (a) Round-trip: settings
    // MARK: ─────────────────────────────────────────

    func testSettingsRoundTrip() throws {
        let original = makeSettings(outputRoot: "~/Roundtrip", whisperModel: "medium", notifyOnSuccess: false)
        let data = try ImportExportService.encodeSettings(original, exportedAt: fixedTimestamp)
        let decoded = try ImportExportService.decodeSettings(from: data)
        XCTAssertEqual(decoded, original, "Settings round-trip must be lossless")
    }

    func testSettingsEnvelopeHeaderFields() throws {
        let settings = makeSettings()
        let data = try ImportExportService.encodeSettings(settings, exportedAt: fixedTimestamp)
        let envelope = try ImportExportService.decodeEnvelope(from: data)
        XCTAssertEqual(envelope.app,         "vocateca")
        XCTAssertEqual(envelope.kind,        .settings)
        XCTAssertEqual(envelope.version,     1)
        XCTAssertEqual(envelope.exportedAt,  fixedTimestamp)
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (a) Round-trip: subscriptions
    // MARK: ─────────────────────────────────────────

    func testSubscriptionsRoundTrip() throws {
        let shows: [Show] = [
            makeShow(slug: "alpha-podcast", title: "Alpha Podcast", rss: "https://alpha.example.com/feed"),
            makeShow(slug: "beta-yt",       title: "Beta YouTube",  rss: "https://youtube.com/@beta"),
        ]
        let original = Watchlist(shows: shows)
        let data = try ImportExportService.encodeSubscriptions(original, exportedAt: fixedTimestamp)
        let decoded = try ImportExportService.decodeSubscriptions(from: data)
        XCTAssertEqual(decoded, original, "Subscriptions round-trip must be lossless")
    }

    func testSubscriptionsEnvelopeHeaderFields() throws {
        let wl = Watchlist(shows: [makeShow(slug: "s", title: "S")])
        let data = try ImportExportService.encodeSubscriptions(wl, exportedAt: fixedTimestamp)
        let envelope = try ImportExportService.decodeEnvelope(from: data)
        XCTAssertEqual(envelope.app,    "vocateca")
        XCTAssertEqual(envelope.kind,   .subscriptions)
        XCTAssertEqual(envelope.version, 1)
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (b) Settings diff
    // MARK: ─────────────────────────────────────────

    func testSettingsDiffNoDifferences() {
        let s = makeSettings()
        let diffs = ImportExportService.diffSettings(imported: s, current: s)
        XCTAssertTrue(diffs.isEmpty, "Identical settings must produce zero diffs")
    }

    func testSettingsDiffDetectsOutputRoot() {
        let current  = makeSettings(outputRoot: "~/Desktop/old")
        let imported = makeSettings(outputRoot: "~/Desktop/new")
        let diffs = ImportExportService.diffSettings(imported: imported, current: current)
        let match = diffs.first { $0.id == "outputRoot" }
        XCTAssertNotNil(match, "Should detect outputRoot diff")
        XCTAssertEqual(match?.oldValue, "~/Desktop/old")
        XCTAssertEqual(match?.newValue, "~/Desktop/new")
    }

    func testSettingsDiffDetectsWhisperModel() {
        var current  = Settings()
        var imported = Settings()
        current.whisperModel  = "small"
        imported.whisperModel = "large-v3"
        let diffs = ImportExportService.diffSettings(imported: imported, current: current)
        XCTAssertTrue(diffs.contains { $0.id == "whisperModel" },
                      "Should detect whisperModel diff")
    }

    func testSettingsDiffDetectsMultipleChanges() {
        var current  = Settings()
        var imported = Settings()
        current.outputRoot    = "~/old"
        imported.outputRoot   = "~/new"
        current.saveSrt       = false
        imported.saveSrt      = true
        current.whisperModel  = "tiny"
        imported.whisperModel = "base"
        let diffs = ImportExportService.diffSettings(imported: imported, current: current)
        // At minimum those three fields must appear.
        XCTAssertTrue(diffs.contains { $0.id == "outputRoot" })
        XCTAssertTrue(diffs.contains { $0.id == "saveSrt" })
        XCTAssertTrue(diffs.contains { $0.id == "whisperModel" })
    }

    func testSettingsDiffIdsAreUnique() {
        var current  = Settings()
        var imported = Settings()
        // Change many fields to stress the deduplication
        current.outputRoot   = "~/a"; imported.outputRoot   = "~/b"
        current.saveSrt      = false;  imported.saveSrt      = true
        current.whisperModel = "tiny"; imported.whisperModel = "base"
        current.dailySummary = false;  imported.dailySummary = true
        let diffs = ImportExportService.diffSettings(imported: imported, current: current)
        let ids = diffs.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "All diff IDs must be unique")
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (c) Subscriptions diff
    // MARK: ─────────────────────────────────────────

    func testSubsDiffAllUnchanged() {
        let shows = [makeShow(slug: "a", title: "A"), makeShow(slug: "b", title: "B")]
        let wl    = Watchlist(shows: shows)
        let diffs = ImportExportService.diffSubscriptions(imported: wl, current: wl)
        XCTAssertTrue(diffs.allSatisfy { $0.status == .unchanged },
                      "Identical watchlists must be all unchanged")
    }

    func testSubsDiffDetectsAdded() {
        let current  = Watchlist(shows: [makeShow(slug: "existing", title: "Existing")])
        let imported = Watchlist(shows: [
            makeShow(slug: "existing", title: "Existing"),
            makeShow(slug: "brand-new", title: "Brand New"),
        ])
        let diffs = ImportExportService.diffSubscriptions(imported: imported, current: current)
        let added = diffs.filter { $0.status == .added }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.slug, "brand-new")
    }

    func testSubsDiffDetectsRemoved() {
        let current  = Watchlist(shows: [
            makeShow(slug: "keep",   title: "Keep"),
            makeShow(slug: "gone",   title: "Gone"),
        ])
        let imported = Watchlist(shows: [makeShow(slug: "keep", title: "Keep")])
        let diffs = ImportExportService.diffSubscriptions(imported: imported, current: current)
        let removed = diffs.filter { $0.status == .removed }
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.slug, "gone")
    }

    func testSubsDiffDetectsChanged() {
        let slug = "my-show"
        let rss  = "https://example.com/feed.xml"
        let currentShow  = Show(slug: slug, title: "Old Title", rss: rss)
        let importedShow = Show(slug: slug, title: "New Title", rss: rss)
        let current  = Watchlist(shows: [currentShow])
        let imported = Watchlist(shows: [importedShow])
        let diffs = ImportExportService.diffSubscriptions(imported: imported, current: current)
        let changed = diffs.filter { $0.status == .changed }
        XCTAssertEqual(changed.count, 1, "Title change must be detected as .changed")
    }

    func testSubsDiffSortOrder() {
        // added → changed → unchanged → removed
        let rss1 = "https://a.example.com/feed"
        let rss2 = "https://b.example.com/feed"
        let rss3 = "https://c.example.com/feed"
        let rss4 = "https://d.example.com/feed"
        let rss5 = "https://e.example.com/feed"

        let showUnchanged = Show(slug: "unchanged", title: "Unchanged", rss: rss1)
        let showChanged   = Show(slug: "changed",   title: "Old Title", rss: rss2)
        let showChangedV2 = Show(slug: "changed",   title: "New Title", rss: rss2)
        let showRemoved   = Show(slug: "removed",   title: "Removed",   rss: rss3)
        let showAdded     = Show(slug: "added",     title: "Added",     rss: rss4)
        let showCurrent2  = Show(slug: "current2",  title: "Current2",  rss: rss5)

        let current  = Watchlist(shows: [showUnchanged, showChanged, showRemoved, showCurrent2])
        let imported = Watchlist(shows: [showUnchanged, showChangedV2, showAdded])

        let diffs = ImportExportService.diffSubscriptions(imported: imported, current: current)
        let statuses = diffs.map { $0.status }

        // added must come before changed, changed before unchanged, unchanged before removed
        if let addedIdx = statuses.firstIndex(of: .added),
           let changedIdx = statuses.firstIndex(of: .changed),
           let unchangedIdx = statuses.firstIndex(of: .unchanged),
           let removedIdx = statuses.firstIndex(where: { $0 == .removed }) {
            XCTAssertLessThan(addedIdx, changedIdx)
            XCTAssertLessThan(changedIdx, unchangedIdx)
            XCTAssertLessThan(unchangedIdx, removedIdx)
        } else {
            XCTFail("Expected all four statuses to appear in the diff")
        }
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (d) Merge vs overwrite
    // MARK: ─────────────────────────────────────────

    func testMergeKeepsCurrentShowsNotInImport() {
        let showA  = makeShow(slug: "a", title: "A", rss: "https://a.example.com/feed")
        let showB  = makeShow(slug: "b", title: "B", rss: "https://b.example.com/feed")
        let showC  = makeShow(slug: "c", title: "C", rss: "https://c.example.com/feed")

        let current  = Watchlist(shows: [showA, showB])   // has A and B
        let imported = Watchlist(shows: [showB, showC])   // has B and C

        let merged = ImportExportService.mergeSubscriptions(imported: imported, current: current)
        let slugs = Set(merged.shows.map { $0.slug })

        XCTAssertTrue(slugs.contains("a"), "Merge must keep A (only in current)")
        XCTAssertTrue(slugs.contains("b"), "Merge must keep B (in both)")
        XCTAssertTrue(slugs.contains("c"), "Merge must add C (only in import)")
        XCTAssertEqual(merged.shows.count, 3)
    }

    func testMergeImportedWinsOnConflict() {
        let rss = "https://example.com/feed.xml"
        let currentShow  = Show(slug: "shared", title: "Current Title",  rss: rss)
        let importedShow = Show(slug: "shared", title: "Imported Title", rss: rss)

        let current  = Watchlist(shows: [currentShow])
        let imported = Watchlist(shows: [importedShow])

        let merged = ImportExportService.mergeSubscriptions(imported: imported, current: current)
        XCTAssertEqual(merged.shows.count, 1)
        XCTAssertEqual(merged.shows[0].title, "Imported Title",
                       "Imported value must win on slug collision in merge")
    }

    func testOverwriteReplacesEntirely() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("watchlist.yaml")
        let showA = makeShow(slug: "a", title: "A", rss: "https://a.example.com/feed")
        let showB = makeShow(slug: "b", title: "B", rss: "https://b.example.com/feed")

        let current  = Watchlist(shows: [showA])
        let imported = Watchlist(shows: [showB])

        try ImportExportService.applySubscriptions(imported, mode: .overwrite,
                                                   current: current, to: url)
        let result = try Watchlist.load(from: url)
        XCTAssertEqual(result.shows.count, 1)
        XCTAssertEqual(result.shows[0].slug, "b", "Overwrite must contain only imported shows")
    }

    func testMergeWritesPersistsCorrectly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("watchlist.yaml")
        let showA = makeShow(slug: "a", title: "A", rss: "https://a.example.com/feed")
        let showB = makeShow(slug: "b", title: "B", rss: "https://b.example.com/feed")

        let current  = Watchlist(shows: [showA])
        let imported = Watchlist(shows: [showB])

        try ImportExportService.applySubscriptions(imported, mode: .merge,
                                                   current: current, to: url)
        let result = try Watchlist.load(from: url)
        let slugs = Set(result.shows.map { $0.slug })
        XCTAssertEqual(slugs, ["a", "b"], "Merge must write both A and B to disk")
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (e) Validation: bad inputs
    // MARK: ─────────────────────────────────────────

    func testDecodeRejectsWrongApp() throws {
        // Build a JSON envelope claiming to be from "paragraphos"
        let json = """
        {
          "app": "paragraphos",
          "kind": "settings",
          "version": 1,
          "exportedAt": "2026-06-28T12:00:00Z",
          "payload": { "type": "settings", "settings": {} }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try ImportExportService.decodeEnvelope(from: json)) { error in
            guard case ImportExportError.wrongApp = error else {
                XCTFail("Expected wrongApp error, got \(error)")
                return
            }
        }
    }

    func testDecodeRejectsUnsupportedVersion() throws {
        let settings = Settings()
        var data = try ImportExportService.encodeSettings(settings, exportedAt: fixedTimestamp)
        // Patch the JSON to set version=99
        var jsonObj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        jsonObj["version"] = 99
        data = try JSONSerialization.data(withJSONObject: jsonObj)
        XCTAssertThrowsError(try ImportExportService.decodeEnvelope(from: data)) { error in
            guard case ImportExportError.unsupportedVersion(99) = error else {
                XCTFail("Expected unsupportedVersion(99), got \(error)")
                return
            }
        }
    }

    func testDecodeSettingsRejectsSubscriptionsFile() throws {
        let wl   = Watchlist(shows: [makeShow(slug: "s", title: "S")])
        let data = try ImportExportService.encodeSubscriptions(wl, exportedAt: fixedTimestamp)
        XCTAssertThrowsError(try ImportExportService.decodeSettings(from: data)) { error in
            guard case ImportExportError.wrongKind(expected: .settings, got: .subscriptions) = error else {
                XCTFail("Expected wrongKind error, got \(error)")
                return
            }
        }
    }

    func testDecodeSubscriptionsRejectsSettingsFile() throws {
        let s    = makeSettings()
        let data = try ImportExportService.encodeSettings(s, exportedAt: fixedTimestamp)
        XCTAssertThrowsError(try ImportExportService.decodeSubscriptions(from: data)) { error in
            guard case ImportExportError.wrongKind(expected: .subscriptions, got: .settings) = error else {
                XCTFail("Expected wrongKind error, got \(error)")
                return
            }
        }
    }

    func testDecodeRejectsGarbage() {
        let garbage = Data("not json at all".utf8)
        XCTAssertThrowsError(try ImportExportService.decodeEnvelope(from: garbage)) { error in
            guard case ImportExportError.decodingFailed = error else {
                XCTFail("Expected decodingFailed error, got \(error)")
                return
            }
        }
    }

    // MARK: ─────────────────────────────────────────
    // MARK: (f) applySettings writes atomically
    // MARK: ─────────────────────────────────────────

    func testApplySettingsWritesFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("settings.yaml")
        var s = Settings()
        s.outputRoot = "~/ImportApplyTest"

        try ImportExportService.applySettings(s, to: url)

        let loaded = try SettingsStore.load(from: url, persistDefaultOnMissing: false)
        XCTAssertEqual(loaded.outputRoot, "~/ImportApplyTest")
    }
}
