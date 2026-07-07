import XCTest
import Foundation
@testable import VocatecaCore

/// Spike A — Phase 0: prove that GRDB reads the real production `state.sqlite`
/// identically to what the `sqlite3` CLI sees.
///
/// The test always operates on a **snapshot copy** in a temp directory so the
/// live file is never touched. If the production database does not exist (e.g.
/// CI without the Vocateca data directory), every test in this class is
/// skipped cleanly via `XCTSkip`.
final class StateReaderSpikeTests: XCTestCase {

    // MARK: - Snapshot helper

    /// Copies `state.sqlite` (plus `-wal` / `-shm` sidecars if present) into a
    /// fresh temporary directory and returns the URL of the snapshot copy.
    ///
    /// - Throws: `XCTSkip` when the production database does not exist.
    private static func snapshotProductionDB() throws -> URL {
        let source = Paths.stateDatabaseURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Production state.sqlite not found — skipping StateReaderSpikeTests")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateReaderSpike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let dest = tmp.appendingPathComponent("state.sqlite")
        try FileManager.default.copyItem(at: source, to: dest)

        // Copy the WAL sidecars too, so the snapshot reflects committed-but-not-
        // yet-checkpointed writes. (Best-effort: a live writer can leave the trio
        // momentarily inconsistent, but it can never corrupt the read-only source.)
        for sidecar in ["-wal", "-shm"] {
            let src = source.deletingLastPathComponent()
                .appendingPathComponent("state.sqlite\(sidecar)")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(
                    at: src,
                    to: tmp.appendingPathComponent("state.sqlite\(sidecar)")
                )
            }
        }

        return dest
    }

    // MARK: - Tests

    func testEpisodeCountAboveFloor() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        let reader = try StateReader(databaseURL: snap)
        let count = try reader.episodeCount()
        XCTAssertGreaterThan(count, 3000, "Expected > 3 000 episodes, got \(count)")
    }

    func testStatusSumMatchesTotal() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        let reader = try StateReader(databaseURL: snap)
        let total = try reader.episodeCount()
        let byStatus = try reader.episodeCountByStatus()
        let statusSum = byStatus.values.reduce(0, +)
        XCTAssertEqual(statusSum, total,
            "Sum of status counts (\(statusSum)) must equal episodeCount (\(total))")
    }

    func testDistinctShowCountAtLeast20() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        let reader = try StateReader(databaseURL: snap)
        let count = try reader.distinctShowCount()
        XCTAssertGreaterThanOrEqual(count, 20, "Expected >= 20 distinct shows, got \(count)")
    }

    func testMetaCountAboveFloor() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        let reader = try StateReader(databaseURL: snap)
        let count = try reader.metaCount()
        XCTAssertGreaterThan(count, 100, "Expected > 100 meta rows, got \(count)")
    }

    func testFetchEpisodesReturnsPopulatedRows() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        let reader = try StateReader(databaseURL: snap)

        // Find the most-populated show slug via a raw status count.
        let byStatus = try reader.episodeCountByStatus()
        XCTAssertFalse(byStatus.isEmpty, "episodeCountByStatus should not be empty")

        // Use the known most-common slug from the real DB; fall back to
        // whatever GRDB finds by querying directly if it ever changes.
        let rows = try reader.fetchEpisodes(showSlug: mostCommonSlug(snap), limit: 10)
        XCTAssertFalse(rows.isEmpty, "fetchEpisodes should return at least one row")
        for row in rows {
            XCTAssertFalse(row.guid.isEmpty, "guid must not be empty")
            XCTAssertFalse(row.title.isEmpty, "title must not be empty")
        }
    }

    /// Shell-oracle cross-check: `/usr/bin/sqlite3` must agree with GRDB.
    func testSqlite3OracleMatchesGRDB() throws {
        let snap = try Self.snapshotProductionDB()
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }

        let reader = try StateReader(databaseURL: snap)
        let grdbCount = try reader.episodeCount()

        let sqlite3Path = "/usr/bin/sqlite3"
        guard FileManager.default.fileExists(atPath: sqlite3Path) else {
            print("⚠️  /usr/bin/sqlite3 not found — skipping oracle cross-check")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite3Path)
        process.arguments = [snap.path, "SELECT COUNT(*) FROM episodes;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Drain stderr before waiting; avoids pipe-buffer deadlock on large output.
        (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let oracleCount = Int(output) ?? -1

        XCTAssertEqual(
            oracleCount, grdbCount,
            "sqlite3 oracle says \(oracleCount) episodes; GRDB says \(grdbCount) — they must match"
        )
        print("✅ Oracle cross-check passed: sqlite3=\(oracleCount) GRDB=\(grdbCount)")
    }

    // MARK: - Private helpers

    /// Queries the snapshot to find the show_slug with the most episodes.
    private func mostCommonSlug(_ dbURL: URL) throws -> String {
        let reader = try StateReader(databaseURL: dbURL)
        guard let slug = try reader.mostPopularShowSlug() else {
            throw XCTFailure("No show_slug found in episodes table")
        }
        return slug
    }
}

/// Wraps a test failure as a throwable so it can be used inside non-XCTestCase
/// closures (e.g. inside a `DatabaseQueue.read { … }` block).
private struct XCTFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
