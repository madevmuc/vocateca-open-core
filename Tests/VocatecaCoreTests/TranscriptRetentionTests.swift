import XCTest
import GRDB
@testable import VocatecaCore

/// Tests for the transcript-retention pass (`Settings.transcriptRetentionDays`):
/// `StateStore.transcriptRetentionCandidates` in isolation, then an end-to-end
/// `MaintenanceRunner` run that deletes the `.md` + sibling sidecars on disk and
/// clears `transcript_path`. Mirrors `MaintenanceRunnerTests`'s mp3 coverage.
final class TranscriptRetentionTests: XCTestCase {

    private var dir: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRetention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Insert an episode row directly (bypasses the feed-upsert flow so we can set
    /// transcript_path / completed_at exactly).
    private func insertEpisode(
        guid: String, completedAt: String?, transcriptPath: String?
    ) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO episodes (show_slug, guid, title, pub_date, mp3_url, status, transcript_path, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: ["s", guid, "t", "2026-01-01", "http://x/\(guid).mp3", "done", transcriptPath, completedAt])
        }
    }

    private func makeFile(_ name: String, in subdir: URL? = nil) throws -> String {
        let base = subdir ?? dir!
        let url = base.appendingPathComponent(name)
        try Data("transcript".utf8).write(to: url)
        return url.path
    }

    // MARK: - transcriptRetentionCandidates in isolation

    func testCandidatesReturnsOnlyOldTranscript() throws {
        let now = "2026-07-01T12:00:00.000000+00:00"
        let oldMd = try makeFile("old.md")
        let recentMd = try makeFile("recent.md")

        // Old: completed 60 days before now.
        try insertEpisode(guid: "g-old", completedAt: "2026-05-02T12:00:00.000000+00:00", transcriptPath: oldMd)
        // Recent: completed 1 day before now.
        try insertEpisode(guid: "g-recent", completedAt: "2026-06-30T12:00:00.000000+00:00", transcriptPath: recentMd)
        // No transcript at all.
        try insertEpisode(guid: "g-none", completedAt: "2026-01-01T00:00:00.000000+00:00", transcriptPath: nil)

        let candidates = try store.transcriptRetentionCandidates(days: 30, nowISO: now)
        XCTAssertEqual(candidates.map(\.guid), ["g-old"])
        XCTAssertEqual(candidates.first?.transcriptPath, oldMd)
    }

    func testCandidatesDisabledWhenDaysIsZero() throws {
        let now = "2026-07-01T12:00:00.000000+00:00"
        let oldMd = try makeFile("old.md")
        try insertEpisode(guid: "g-old", completedAt: "2026-01-01T00:00:00.000000+00:00", transcriptPath: oldMd)

        let candidates = try store.transcriptRetentionCandidates(days: 0, nowISO: now)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - End-to-end via MaintenanceRunner

    func testMaintenanceRunnerDeletesOldTranscriptAndSidecarsAndClearsPath() throws {
        let now = "2026-07-01T12:00:00.000000+00:00"
        let mdPath = try makeFile("episode.md")
        let base = (mdPath as NSString).deletingPathExtension
        let srtPath = base + ".srt"
        try Data("subs".utf8).write(to: URL(fileURLWithPath: srtPath))

        try insertEpisode(guid: "g-old", completedAt: "2026-05-01T00:00:00.000000+00:00", transcriptPath: mdPath)

        var settings = Settings()
        settings.transcriptRetentionDays = 30
        settings.deleteMp3AfterTranscribe = false
        settings.mp3RetentionDays = 0
        settings.diskGuardEnabled = false

        let report = MaintenanceRunner(store: store, settings: settings, guardPath: dir.path).run(nowISO: now)

        XCTAssertEqual(report.transcriptsDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mdPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srtPath))

        let remainingPath = try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT transcript_path FROM episodes WHERE guid = ?", arguments: ["g-old"])
        }
        XCTAssertNil(remainingPath)
    }

    func testMaintenanceRunnerKeepsTranscriptWhenRetentionDisabled() throws {
        let now = "2026-07-01T12:00:00.000000+00:00"
        let mdPath = try makeFile("keep.md")
        try insertEpisode(guid: "g-old", completedAt: "2026-01-01T00:00:00.000000+00:00", transcriptPath: mdPath)

        var settings = Settings()
        settings.transcriptRetentionDays = 0   // disabled = keep forever
        settings.deleteMp3AfterTranscribe = false
        settings.mp3RetentionDays = 0
        settings.diskGuardEnabled = false

        let report = MaintenanceRunner(store: store, settings: settings, guardPath: dir.path).run(nowISO: now)

        XCTAssertEqual(report.transcriptsDeleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath))
    }
}
