import XCTest
@testable import VocatecaCore

final class PerShowRetentionCandidatesTests: XCTestCase {
    private func store() throws -> StateStore { try StateStore.inMemory() }

    /// Seeds a transcribed episode with an mp3 and a completion timestamp N days ago.
    private func seedDone(_ s: StateStore, guid: String, slug: String, completedDaysAgo: Int) throws {
        _ = try s.upsertEpisodeFromFeed(showSlug: slug, guid: guid, title: guid,
                                        pubDate: "2020-01-01", mp3URL: "https://x/\(guid).mp3", durationSec: nil)
        try s.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodes SET status = 'done', mp3_path = ?, completed_at = ? WHERE guid = ?",
                arguments: ["/tmp/\(guid).mp3", Self.iso(daysAgo: completedDaysAgo), guid])
        }
    }
    private static func iso(daysAgo: Int) -> String {
        let d = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
    private static var now: String { iso(daysAgo: 0) }

    func testKeepForeverShowExcluded() throws {
        let s = try store()
        try seedDone(s, guid: "e1", slug: "keep", completedDaysAgo: 999)
        let c = try s.mp3RetentionCandidates(
            overrideBySlug: ["keep": 0], globalDays: 30,
            globalDeleteAfterTranscribe: false, nowISO: Self.now)
        XCTAssertTrue(c.isEmpty, "keep-forever (override 0) show must be excluded")
    }

    func testPerShowShortOverrideReclaims() throws {
        let s = try store()
        try seedDone(s, guid: "e1", slug: "fast", completedDaysAgo: 5)
        let c = try s.mp3RetentionCandidates(
            overrideBySlug: ["fast": 3], globalDays: 30,
            globalDeleteAfterTranscribe: false, nowISO: Self.now)
        XCTAssertEqual(c.map(\.guid), ["e1"], "5 days old, 3-day override → reclaim")
    }

    func testFollowGlobalNotYetDue() throws {
        let s = try store()
        try seedDone(s, guid: "e1", slug: "g", completedDaysAgo: 5)
        let c = try s.mp3RetentionCandidates(
            overrideBySlug: [:], globalDays: 30,   // no override → follow global 30d
            globalDeleteAfterTranscribe: false, nowISO: Self.now)
        XCTAssertTrue(c.isEmpty, "5 days old, 30-day global → not yet due")
    }
}
