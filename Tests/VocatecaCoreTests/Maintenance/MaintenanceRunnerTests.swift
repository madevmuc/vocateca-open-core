import XCTest
import GRDB
@testable import VocatecaCore

/// Integration tests for `MaintenanceRunner` against a real temp `StateStore` +
/// real temp files on disk.
final class MaintenanceRunnerTests: XCTestCase {

    private var dir: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StateStore(databaseURL: dir.appendingPathComponent("test.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Insert an episode row directly (bypasses the feed-upsert flow so we can set
    /// mp3_path / completed_at exactly).
    private func insertEpisode(
        guid: String, status: String, completedAt: String?, mp3Path: String?
    ) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO episodes (show_slug, guid, title, pub_date, mp3_url, status, mp3_path, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: ["s", guid, "t", "2026-01-01", "http://x/\(guid).mp3", status, mp3Path, completedAt])
        }
    }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url.path
    }

    func testDeletesDoneMp3AndPrunesEventsButKeepsPending() throws {
        let now = "2026-07-01T12:00:00.000000+00:00"
        let doneFile = try makeFile("done.mp3")
        let pendingFile = try makeFile("pending.mp3")

        try insertEpisode(guid: "g-done", status: "done", completedAt: now, mp3Path: doneFile)
        try insertEpisode(guid: "g-pending", status: "pending", completedAt: nil, mp3Path: pendingFile)

        // Two events: one old (should prune), one recent (should stay).
        try store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO events (ts, type) VALUES (?, ?)",
                           arguments: ["2026-05-01T00:00:00.000000+00:00", "old.event"])
            try db.execute(sql: "INSERT INTO events (ts, type) VALUES (?, ?)",
                           arguments: ["2026-06-30T00:00:00.000000+00:00", "recent.event"])
        }

        var settings = Settings()
        settings.deleteMp3AfterTranscribe = true
        settings.eventRetentionDays = 30
        settings.diskGuardEnabled = false

        let runner = MaintenanceRunner(store: store, settings: settings, guardPath: dir.path)
        let report = runner.run(nowISO: now)

        // done mp3 gone + path cleared; pending untouched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: doneFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFile))
        XCTAssertEqual(report.mp3sDeleted, 1)

        // `mp3RetentionCandidates` now returns only rows that are actually past
        // their (per-show) retention cutoff — not every mp3-bearing row. So after
        // the run: g-done's path is cleared (excluded), and g-pending is a
        // `pending` episode, which is never reclaimable (only `done` media ages
        // out), so it is correctly NOT a candidate.
        let candidates = try store.mp3RetentionCandidates(
            overrideBySlug: [:],
            globalDays: settings.mp3RetentionDays,
            globalDeleteAfterTranscribe: settings.deleteMp3AfterTranscribe,
            nowISO: Event.nowISO()
        ).map(\.guid)
        XCTAssertFalse(candidates.contains("g-done"))
        XCTAssertFalse(candidates.contains("g-pending"))

        // old event pruned, recent kept.
        XCTAssertEqual(report.eventsPruned, 1)
        let remaining = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? -1
        }
        XCTAssertEqual(remaining, 1)
    }

    func testKeepsMp3WhenDeleteAfterOffAndYoung() throws {
        let now = "2026-07-01T12:00:00.000000+00:00"
        let file = try makeFile("young.mp3")
        try insertEpisode(guid: "g", status: "done", completedAt: "2026-06-30T12:00:00.000000+00:00", mp3Path: file)

        var settings = Settings()
        settings.deleteMp3AfterTranscribe = false
        settings.mp3RetentionDays = 7      // 1 day old < 7 → keep
        settings.diskGuardEnabled = false

        let report = MaintenanceRunner(store: store, settings: settings, guardPath: dir.path).run(nowISO: now)
        XCTAssertEqual(report.mp3sDeleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }
}
