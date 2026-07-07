import XCTest
import Foundation
@testable import VocatecaCore

/// Tables Task 2 — `StateReader.latestPubDates()`.
///
/// Seeds episodes across shows via a real `StateStore` (temp file), then opens a
/// read-only `StateReader` over the same DB and asserts the MAX(pub_date) per slug.
final class StateReaderLatestPubDatesTests: XCTestCase {

    private static func makeTempStore() throws -> (store: StateStore, dir: URL, dbURL: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatestPubDates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("test.sqlite")
        let store = try StateStore(databaseURL: dbURL)
        return (store, dir, dbURL)
    }

    private static func ep(_ guid: String, _ slug: String, _ pub: String) -> Episode {
        Episode(
            guid: guid, showSlug: slug, title: guid, pubDate: pub,
            mp3Url: "https://example.com/\(guid).mp3", status: "done",
            priority: 0, attempts: 0
        )
    }

    func testLatestPubDatesReturnsMaxPerShow() throws {
        let (store, dir, dbURL) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // show-a: three episodes, latest = 2024-05-10 (out of order to prove MAX, not last-inserted).
        try store.upsert(Self.ep("a1", "show-a", "2024-01-01"))
        try store.upsert(Self.ep("a2", "show-a", "2024-05-10"))
        try store.upsert(Self.ep("a3", "show-a", "2024-03-15"))
        // show-b: two episodes, latest = 2023-12-31.
        try store.upsert(Self.ep("b1", "show-b", "2023-11-01"))
        try store.upsert(Self.ep("b2", "show-b", "2023-12-31"))

        let reader = try StateReader(databaseURL: dbURL)
        let latest = try reader.latestPubDates()

        XCTAssertEqual(latest["show-a"], "2024-05-10")
        XCTAssertEqual(latest["show-b"], "2023-12-31")
        XCTAssertEqual(latest.count, 2)
    }

    func testLatestPubDatesEmptyWhenNoEpisodes() throws {
        let (_, dir, dbURL) = try Self.makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reader = try StateReader(databaseURL: dbURL)
        XCTAssertTrue(try reader.latestPubDates().isEmpty)
    }
}
