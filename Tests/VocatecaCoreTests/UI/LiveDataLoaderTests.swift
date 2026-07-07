import XCTest
import Foundation
@testable import VocatecaCore

// MARK: - Live-data wiring tests (Phase 6)

/// Verifies the data pipeline that ``LiveDataLoader`` (in VocatecaUI) calls:
/// ``StateReader.openProductionForReading()``, ``Watchlist.load``, and
/// ``SettingsStore.load``.  Since ``VocatecaCoreTests`` does not depend on
/// VocatecaUI (and Package.swift must not be changed), these tests exercise
/// the *exact same read paths* the loader uses — proving real data is accessible
/// and that the pipeline degrades gracefully when data is absent.
///
/// All DB access uses the safe ``openProductionForReading()`` snapshot.
///
/// Skips cleanly on machines without the production data directory (e.g. CI).
final class LiveDataLoaderTests: XCTestCase {

    // MARK: - Helpers

    private static var productionDBExists: Bool {
        FileManager.default.fileExists(atPath: Paths.stateDatabaseURL.path)
    }

    private static var watchlistExists: Bool {
        FileManager.default.fileExists(atPath: Paths.watchlistURL.path)
    }

    // MARK: - Test 1: Live pipeline loads > 0 shows from watchlist + counts from DB

    func testLivePipelineLoadsShowsAndEpisodeCounts() throws {
        guard Self.productionDBExists else {
            throw XCTSkip("Production state.sqlite not found — skipping live data test")
        }
        guard Self.watchlistExists else {
            throw XCTSkip("watchlist.yaml not found — skipping live data test")
        }

        // 1. Snapshot the DB — exactly what LiveDataLoader does.
        let reader = try XCTUnwrap(
            StateReader.openProductionForReading(),
            "openProductionForReading() must return a reader when state.sqlite exists"
        )

        // 2. Load watchlist.
        let watchlist = try Watchlist.load(from: Paths.watchlistURL)
        let showCount = watchlist.shows.count
        XCTAssertGreaterThan(showCount, 0, "Watchlist must have > 0 shows; got \(showCount)")
        print("✅ Live shows from watchlist: \(showCount)")

        // 3. Build per-show episode counts — the loop inside LiveDataLoader.load().
        var totalBySlug: [String: Int] = [:]
        for show in watchlist.shows {
            let statusMap = try reader.episodeCountsByStatus(forShowSlug: show.slug)
            let total = statusMap.values.reduce(0, +)
            totalBySlug[show.slug] = total
        }

        // At least one show must have > 0 episodes.
        let showsWithEpisodes = totalBySlug.values.filter { $0 > 0 }.count
        XCTAssertGreaterThan(
            showsWithEpisodes, 0,
            "At least one show must have > 0 episodes in the DB; all counts were zero"
        )
        print("✅ Shows with episodes in DB: \(showsWithEpisodes) / \(showCount)")

        // 4. Find the most-populated show and fetch its episodes.
        let mostPopulated = totalBySlug.max(by: { $0.value < $1.value })
        let slug = try XCTUnwrap(mostPopulated?.key, "Must have at least one show with episodes")
        let episodeCount = mostPopulated!.value

        let episodes = try reader.fetchEpisodesBySlug(showSlug: slug, statusFilter: nil, limit: 500)
        XCTAssertGreaterThan(
            episodes.count, 0,
            "fetchEpisodesBySlug must return > 0 episodes for '\(slug)'; got \(episodes.count)"
        )
        // The fetch result should be bounded by totalCount (may be less if limit < total).
        XCTAssertLessThanOrEqual(episodes.count, episodeCount + 1)  // +1: allow floating WAL

        print("""
        ✅ Live episode fetch for most-populated show '\(slug)':
           episodeCountByStatus=\(episodeCount), fetchEpisodesBySlug returned \(episodes.count)
        """)

        // 5. Spot-check returned episodes belong to the correct show.
        for ep in episodes.prefix(5) {
            XCTAssertEqual(ep.showSlug, slug, "Episode '\(ep.title)' has wrong showSlug '\(ep.showSlug)'")
            XCTAssertFalse(ep.guid.isEmpty, "Episode guid must not be empty")
            XCTAssertFalse(ep.title.isEmpty, "Episode title must not be empty")
        }
    }

    // MARK: - Test 2: Fetch failed episodes via the same reader path LiveDataLoader uses

    func testLiveFetchFailedEpisodesWellFormed() throws {
        guard Self.productionDBExists else {
            throw XCTSkip("Production state.sqlite not found — skipping live failed-items test")
        }

        let reader = try XCTUnwrap(StateReader.openProductionForReading())

        // LiveDataLoader calls fetchFailed(showSlug: nil, limit: 200).
        let failed = try reader.fetchFailed(showSlug: nil, limit: 200)
        print("ℹ️  Live failed episodes: \(failed.count)")

        // Each item returned must have non-empty fields.
        for ep in failed {
            XCTAssertFalse(ep.guid.isEmpty,      "FailedEpisode guid must not be empty")
            XCTAssertFalse(ep.showSlug.isEmpty,  "FailedEpisode showSlug must not be empty")
            XCTAssertFalse(ep.title.isEmpty,     "FailedEpisode title must not be empty")
            XCTAssertEqual(ep.status, "failed",  "fetchFailed must only return status='failed' rows")
        }
    }

    // MARK: - Test 3: Graceful degradation — nil reader (missing DB)

    func testGracefulDegradationNilReader() throws {
        // Simulate a fresh install: no DB.
        // StateReader.openProductionForReading() returns nil when state.sqlite is absent.
        // We model the degradation by checking what happens with empty fallback.

        // Watchlist.load on a non-existent URL → empty watchlist (no throw).
        let fakeURL = URL(fileURLWithPath: "/tmp/vocateca_test_\(UUID().uuidString)/watchlist.yaml")
        let wl = try Watchlist.load(from: fakeURL)
        XCTAssertEqual(wl.shows.count, 0, "Missing watchlist.yaml must load as empty, not throw")

        // SettingsStore.load on a non-existent URL → defaults (persistDefaultOnMissing: false).
        let fakeSettings = URL(fileURLWithPath: "/tmp/vocateca_test_\(UUID().uuidString)/settings.yaml")
        let s = try SettingsStore.load(from: fakeSettings, persistDefaultOnMissing: false)
        XCTAssertTrue(
            VocatecaCore.Settings.isValidHHMM(s.dailyCheckTime),
            "Default Settings must have a valid dailyCheckTime; got '\(s.dailyCheckTime)'"
        )
        XCTAssertFalse(s.whisperModel.isEmpty, "Default Settings must have a non-empty whisperModel")

        print("✅ Graceful degradation (missing files) — all assertions passed, no crash")
    }

    // MARK: - Test 4: Real settings are well-formed

    func testLiveSettingsWellFormed() throws {
        guard Self.productionDBExists else {
            throw XCTSkip("Production state.sqlite not found — skipping settings test")
        }

        let s = try SettingsStore.load(from: Paths.settingsURL, persistDefaultOnMissing: false)

        XCTAssertTrue(
            VocatecaCore.Settings.isValidHHMM(s.dailyCheckTime),
            "dailyCheckTime '\(s.dailyCheckTime)' must be valid HH:MM"
        )
        XCTAssertFalse(s.whisperModel.isEmpty, "whisperModel must not be empty")

        print("✅ Live settings: whisperModel=\(s.whisperModel), dailyCheckTime=\(s.dailyCheckTime)")
    }
}
