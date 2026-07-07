import XCTest
@testable import VocatecaCore

final class AutomationStatusReporterTests: XCTestCase {
    func testWriteThenReadRoundTrips() throws {
        let store = try StateStore.inMemory()
        let reporter = AutomationStatusReporter(store: store)
        let s = AutomationStatus(lastRunAt: "2026-07-03T03:00:00Z", nextRunAt: nil,
                                 processed: 5, done: 4, failed: 1, lastSkipReason: .onBattery)
        try reporter.write(s)
        XCTAssertEqual(try reporter.read(), s)
    }

    func testReadWhenAbsentReturnsDefault() throws {
        let store = try StateStore.inMemory()
        XCTAssertEqual(try AutomationStatusReporter(store: store).read(), AutomationStatus())
    }
}
