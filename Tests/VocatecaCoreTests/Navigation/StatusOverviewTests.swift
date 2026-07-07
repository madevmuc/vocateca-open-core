import XCTest
@testable import VocatecaCore

/// Unit tests for `StatusOverview` — the pure ok/warn/error threshold logic
/// behind the three "Ampel" cards on the Status screen. No SwiftUI/DB, so the
/// thresholds the UI paints are locked down here.
final class StatusOverviewTests: XCTestCase {

    // MARK: - Sources (Quellen)

    func testSourcesOkWhenAllHealthy() {
        XCTAssertEqual(StatusOverview.sourcesLevel(totalSources: 12, unhealthySources: 0), .ok)
    }

    func testSourcesOkWhenNoSources() {
        // Zero subscribed shows is a clean state, not an error.
        XCTAssertEqual(StatusOverview.sourcesLevel(totalSources: 0, unhealthySources: 0), .ok)
    }

    func testSourcesErrorWhenAnyUnhealthy() {
        XCTAssertEqual(StatusOverview.sourcesLevel(totalSources: 12, unhealthySources: 1), .error)
        XCTAssertEqual(StatusOverview.sourcesLevel(totalSources: 3, unhealthySources: 3), .error)
    }

    func testHealthySourcesCount() {
        XCTAssertEqual(StatusOverview.healthySources(totalSources: 12, unhealthySources: 2), 10)
        XCTAssertEqual(StatusOverview.healthySources(totalSources: 0, unhealthySources: 0), 0)
        // Never negative even if the caller passes inconsistent figures.
        XCTAssertEqual(StatusOverview.healthySources(totalSources: 2, unhealthySources: 5), 0)
    }

    // MARK: - Tools (Werkzeuge)

    func testToolsOkWhenNoneMissing() {
        XCTAssertEqual(StatusOverview.toolsLevel(missingRequiredTools: 0), .ok)
    }

    func testToolsErrorWhenAnyMissing() {
        XCTAssertEqual(StatusOverview.toolsLevel(missingRequiredTools: 1), .error)
        XCTAssertEqual(StatusOverview.toolsLevel(missingRequiredTools: 2), .error)
    }

    // MARK: - Storage (Speicher)

    func testStorageOkWhenCapDisabled() {
        // Cap off ⇒ unbounded ⇒ never warns, even at huge usage.
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 999_000_000_000, capBytes: 10_000_000_000,
                                        capEnabled: false),
            .ok)
    }

    func testStorageOkWellBelowCap() {
        // 5 GB of a 10 GB cap = 50%.
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 5_000_000_000, capBytes: 10_000_000_000,
                                        capEnabled: true),
            .ok)
    }

    func testStorageWarnsAtNinetyPercent() {
        // Exactly 90% of a 10 GB cap → warn (>= threshold).
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 9_000_000_000, capBytes: 10_000_000_000,
                                        capEnabled: true),
            .warn)
        // Just under 90% stays ok.
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 8_999_999_999, capBytes: 10_000_000_000,
                                        capEnabled: true),
            .ok)
    }

    func testStorageErrorAtOrOverCap() {
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 10_000_000_000, capBytes: 10_000_000_000,
                                        capEnabled: true),
            .error)
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 11_000_000_000, capBytes: 10_000_000_000,
                                        capEnabled: true),
            .error)
    }

    func testStorageOkWhenCapZero() {
        // Guard against divide-by-zero / nonsensical cap.
        XCTAssertEqual(
            StatusOverview.storageLevel(usedBytes: 5_000_000_000, capBytes: 0, capEnabled: true),
            .ok)
    }

    // MARK: - Level ordering (worst-wins)

    func testLevelComparableWorstWins() {
        XCTAssertEqual([StatusOverview.Level.ok, .warn, .error].max(), .error)
        XCTAssertEqual([StatusOverview.Level.ok, .warn].max(), .warn)
        XCTAssertTrue(StatusOverview.Level.ok < StatusOverview.Level.error)
    }
}
