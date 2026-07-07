import XCTest
@testable import VocatecaCore

final class ReclaimOrphanedInFlightTests: XCTestCase {

    private func makeStore() throws -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateStore(databaseURL: dir.appendingPathComponent("t.sqlite")), dir)
    }

    private func ep(_ guid: String, _ status: String) -> Episode {
        Episode(guid: guid, showSlug: "s", title: guid, pubDate: "2026-01-01",
                mp3Url: "https://e/\(guid).mp3", status: status)
    }

    func testResetsOnlyInFlightStatuses() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("dl",   "downloading"))
        try store.upsert(ep("tr",   "transcribing"))
        try store.upsert(ep("pend", "pending"))
        try store.upsert(ep("done", "done"))
        try store.upsert(ep("dled", "downloaded"))   // valid checkpoint — must stay

        let reset = try store.reclaimOrphanedInFlight()
        XCTAssertEqual(reset, 2, "only downloading + transcribing should be reset")

        XCTAssertEqual(try store.episode(guid: "dl")?.status,   "pending")
        XCTAssertEqual(try store.episode(guid: "tr")?.status,   "pending")
        XCTAssertEqual(try store.episode(guid: "pend")?.status, "pending")
        XCTAssertEqual(try store.episode(guid: "done")?.status, "done")
        XCTAssertEqual(try store.episode(guid: "dled")?.status, "downloaded")
    }

    func testNoInFlightReturnsZero() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(ep("a", "pending"))
        try store.upsert(ep("b", "done"))
        XCTAssertEqual(try store.reclaimOrphanedInFlight(), 0)
    }

    // MARK: - Poison-pill guard (H2)

    /// Each reclaim must bump `attempts`, so a crash-inducing episode can't
    /// crash-loop forever. With max=3: reclaim #1 → attempts 1, #2 → attempts 2
    /// (both back to pending), #3 → attempts 3 → `failed` (drops out of the queue).
    func testReclaimBumpsAttemptsAndFailsPoisonPill() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.upsert(ep("poison", "transcribing"))   // attempts start at 0

        // Reclaim #1 → pending, attempts 1.
        XCTAssertEqual(try store.reclaimOrphanedInFlight(), 1)
        var row = try XCTUnwrap(store.episode(guid: "poison"))
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.attempts, 1)

        // Re-arm the crash (a fresh session finds it in-flight again).
        try store.setStatus(guid: "poison", .transcribing)

        // Reclaim #2 → pending, attempts 2.
        XCTAssertEqual(try store.reclaimOrphanedInFlight(), 1)
        row = try XCTUnwrap(store.episode(guid: "poison"))
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.attempts, 2)

        try store.setStatus(guid: "poison", .transcribing)

        // Reclaim #3 → attempts 3 ≥ max → FAILED with a diagnostic reason.
        XCTAssertEqual(try store.reclaimOrphanedInFlight(), 1)
        row = try XCTUnwrap(store.episode(guid: "poison"))
        XCTAssertEqual(row.status, "failed", "third reclaim must fail the poison pill")
        XCTAssertEqual(row.attempts, 3)
        XCTAssertEqual(row.errorCategory, ErrorCategory.crash)
        XCTAssertTrue(row.errorText?.contains("crashed while processing") ?? false,
                      "failed poison pill must carry a diagnostic reason, got \(row.errorText ?? "nil")")
    }

    /// A normal single reclaim of a healthy in-flight row bumps attempts by 1 and
    /// returns it to pending (the common case — an app that was quit mid-run).
    func testSingleReclaimBumpsAttemptsByOne() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.upsert(ep("dl", "downloading"))
        XCTAssertEqual(try store.reclaimOrphanedInFlight(), 1)
        let row = try XCTUnwrap(store.episode(guid: "dl"))
        XCTAssertEqual(row.status, "pending")
        XCTAssertEqual(row.attempts, 1)
    }
}
