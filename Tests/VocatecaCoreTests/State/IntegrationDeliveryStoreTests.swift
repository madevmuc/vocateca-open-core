import XCTest
import Foundation
@testable import VocatecaCore

/// Integrations — Task 2: `integration_deliveries` marker table + `StateStore`
/// accessors (`recordDelivery`, `lastDelivery`, `deliveries`).
final class IntegrationDeliveryStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh `StateStore` backed by a temp SQLite file with v2
    /// migrations applied. Returns both the store and the temp directory URL
    /// (the caller must `removeItem(at:)` the directory when done).
    private static func makeTempStore() throws -> (store: StateStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationDeliveryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir)
    }

    func testRecordAndQueryDelivery() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.recordDelivery(integration: "notion", episodeGuid: "g1",
                                 target: "db123", status: "ok",
                                 externalRef: "page_abc", errorText: nil)
        let last = try store.lastDelivery(integration: "notion", episodeGuid: "g1")
        XCTAssertEqual(last?.status, "ok")
        XCTAssertEqual(last?.externalRef, "page_abc")
        XCTAssertEqual(try store.deliveries(episodeGuid: "g1").count, 1)
    }

    func testLastDeliveryNilWhenNone() throws {
        let (store, dir) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(try store.lastDelivery(integration: "notion", episodeGuid: "none"))
    }
}
